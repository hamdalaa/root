import AppKit
import Foundation
import Observation

/// State for the Login Items screen. Reads happen automatically; every change needs a click and a confirmation.
@MainActor
@Observable
final class LoginItemsModel {
    enum Phase: Equatable { case idle, loading, ready }

    enum AppsState: Equatable {
        case checking
        case needsPermission
        case denied
        case reading
        case loaded([LoginItemLoginApp])
        case failed(String)
    }

    /// A change waiting for the user to confirm it.
    enum Pending: Identifiable, Equatable {
        case disable(LoginItemEntry)
        case remove([LoginItemEntry])

        var id: String {
            switch self {
            case .disable(let entry): "disable-" + entry.id
            case .remove(let entries): "remove-" + entries.map(\.id).joined(separator: ",")
            }
        }
    }

    struct Notice: Equatable {
        var text: String
        var isError: Bool
    }

    var phase: Phase = .idle
    var entries: [LoginItemEntry] = []
    var appsState: AppsState = .checking
    var pending: Pending?
    var busyIDs: Set<String> = []
    var isLoadingStatus = false
    var notice: Notice?

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    func start() {
        guard phase == .idle else { return }
        reload()
        checkAppsAccess()
    }

    func stop() {
        loadTask?.cancel()
        if phase == .loading { phase = .idle }
        isLoadingStatus = false
    }

    /// Rows appear as soon as the plists are parsed; launchd status then fills in row by row, 8 queries at a time.
    func reload() {
        loadTask?.cancel()
        phase = .loading
        loadTask = Task { [weak self] in
            let read = await LoginItemScanner.readAllOffMain()
            guard let self, !Task.isCancelled else { return }
            let previous = Dictionary(self.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            self.entries = read.map { entry in
                var copy = entry
                if let old = previous[entry.id] {
                    copy.status = old.status
                    copy.lastExitCode = old.lastExitCode
                }
                return copy
            }
            self.phase = .ready
            self.isLoadingStatus = true
            await self.fillStatuses(for: read)
            if !Task.isCancelled { self.isLoadingStatus = false }
        }
    }

    private static let statusConcurrency = 8

    private func fillStatuses(for targets: [LoginItemEntry]) async {
        let disabled = await LoginItemScanner.disabledMaps()
        await withTaskGroup(of: (String, LoginItemStatus, String?).self) { group in
            var queue = targets.makeIterator()
            func next() -> Bool {
                guard let entry = queue.next() else { return false }
                group.addTask {
                    let (status, exit) = await LoginItemScanner.status(of: entry, disabled: disabled)
                    return (entry.id, status, exit)
                }
                return true
            }
            for _ in 0..<Self.statusConcurrency where next() {}
            for await (id, status, exit) in group {
                if Task.isCancelled { group.cancelAll(); return }
                if let index = entries.firstIndex(where: { $0.id == id }),
                   entries[index].status != status || entries[index].lastExitCode != exit {
                    entries[index].status = status
                    entries[index].lastExitCode = exit
                }
                _ = next()
            }
        }
    }

    /// True while this entry's launchd status hasn't arrived yet.
    func isStatusPending(_ entry: LoginItemEntry) -> Bool { isLoadingStatus && entry.status == .unknown }

    // MARK: Derived

    func entries(in scope: LoginItemScope) -> [LoginItemEntry] { entries.filter { $0.scope == scope } }

    var broken: [LoginItemEntry] { entries.filter { $0.health.isBroken && $0.scope.isManageable } }
    var brokenElsewhere: Int { entries.filter { $0.health.isBroken && !$0.scope.isManageable }.count }
    var automaticCount: Int {
        entries.filter(\.countsAsAutomatic).count + (loginApps?.count ?? 0)
    }
    var runningCount: Int { entries.filter { if case .running = $0.status { true } else { false } }.count }
    var offCount: Int { entries.filter(\.isOff).count }

    var loginApps: [LoginItemLoginApp]? {
        if case .loaded(let apps) = appsState { return apps }
        return nil
    }

    // MARK: Apps that open at login

    func checkAppsAccess() {
        Task {
            let access = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: LoginItemSystemEvents.currentAccess())
                }
            }
            apply(access)
        }
    }

    private func apply(_ access: LoginItemSystemEvents.Access) {
        switch access {
        case .granted: readLoginApps()
        case .denied: appsState = .denied
        case .notDetermined, .unknown:
            // Once access worked, read again without making the user click each visit.
            if LoginItemSystemEvents.wasGranted { readLoginApps() } else { appsState = .needsPermission }
        }
    }

    /// May show the macOS Automation prompt; only called automatically once access has been granted before.
    func readLoginApps() {
        appsState = .reading
        Task {
            switch await LoginItemSystemEvents.read() {
            case .success(let apps):
                appsState = .loaded(apps)
            case .failure(.denied):
                appsState = .denied
            case .failure(.other(let message)):
                appsState = .failed(message)
            }
        }
    }

    // MARK: Actions (explicit user clicks only)

    /// The switch was flipped. Turning off asks first; turning on happens right away.
    func requestToggle(_ entry: LoginItemEntry, on: Bool) {
        guard entry.scope.isManageable, !busyIDs.contains(entry.id) else { return }
        guard on != !entry.isOff else { return }
        if on { enable(entry) } else { pending = .disable(entry) }
    }

    func confirmDisable(_ entry: LoginItemEntry) {
        pending = nil
        run(entry) {
            if let error = await LoginItemLaunchctl.disable(label: entry.label, plistPath: entry.plistURL.path) {
                return Notice(text: "Couldn’t turn off \(entry.owner.name): \(error)", isError: true)
            }
            return Notice(text: "\(entry.owner.name) is off. It won’t start at login until you turn it back on.", isError: false)
        }
    }

    private func enable(_ entry: LoginItemEntry) {
        run(entry) {
            if let error = await LoginItemLaunchctl.enable(label: entry.label, plistPath: entry.plistURL.path) {
                return Notice(text: "Couldn’t turn on \(entry.owner.name): \(error)", isError: true)
            }
            return Notice(text: "\(entry.owner.name) is on again.", isError: false)
        }
    }

    func requestRemove(_ entries: [LoginItemEntry]) {
        let removable = entries.filter { $0.scope.isManageable && $0.health.isBroken }
        guard !removable.isEmpty else { return }
        pending = .remove(removable)
    }

    func confirmRemove(_ targets: [LoginItemEntry]) {
        pending = nil
        let ids = Set(targets.map(\.id))
        busyIDs.formUnion(ids)
        Task {
            var failures: [String] = []
            let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
            for entry in targets {
                guard Self.isSafeToRemove(entry, library: library) else {
                    failures.append("\(entry.plistURL.lastPathComponent): not in your LaunchAgents folder")
                    continue
                }
                await LoginItemLaunchctl.unload(plistPath: entry.plistURL.path)
                let url = entry.plistURL
                let error: String? = await Task.detached {
                    do { try FileManager.default.trashItem(at: url, resultingItemURL: nil); return nil }
                    catch { return UninstallTrasher.reason(for: error) }
                }.value
                if let error { failures.append("\(entry.plistURL.lastPathComponent): \(error)") }
            }
            busyIDs.subtract(ids)
            let removed = targets.count - failures.count
            notice = failures.isEmpty
                ? Notice(text: "Moved \(removed) broken item\(removed == 1 ? "" : "s") to the Trash.", isError: false)
                : Notice(text: "Couldn’t remove " + failures.joined(separator: "; "), isError: true)
            reload()
        }
    }

    /// Only plists directly inside ~/Library/LaunchAgents, never anything else.
    nonisolated static func isSafeToRemove(_ entry: LoginItemEntry, library: URL) -> Bool {
        guard entry.scope == .user, entry.plistURL.pathExtension == "plist" else { return false }
        let parent = entry.plistURL.deletingLastPathComponent().standardizedFileURL.path
        return parent == library.appendingPathComponent("LaunchAgents").standardizedFileURL.path
    }

    private func run(_ entry: LoginItemEntry, _ work: @escaping @MainActor () async -> Notice) {
        busyIDs.insert(entry.id)
        Task {
            notice = await work()
            busyIDs.remove(entry.id)
            reload()
        }
    }

    // MARK: Finder / Settings

    func revealPlist(_ entry: LoginItemEntry) { FinderReveal.reveal([entry.plistURL]) }

    func revealProgram(_ entry: LoginItemEntry) {
        let path = entry.owner.appPath ?? entry.subjectPath
        guard let path, FileManager.default.fileExists(atPath: path) else { return }
        FinderReveal.reveal([URL(fileURLWithPath: path)])
    }

    func programExists(_ entry: LoginItemEntry) -> Bool {
        guard let path = entry.owner.appPath ?? entry.subjectPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    func openLoginItemsSettings() { NSWorkspace.shared.open(LoginItemSystemEvents.settingsURL) }
    func openAutomationSettings() { NSWorkspace.shared.open(LoginItemSystemEvents.automationSettingsURL) }
}
