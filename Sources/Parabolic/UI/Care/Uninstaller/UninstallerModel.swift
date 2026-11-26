import AppKit
import Foundation
import Observation

/// State for the Uninstaller screen: the app list, progressive sizes, the selected app's files, leftovers and the remove flow.
@MainActor
@Observable
final class UninstallerModel {
    enum Segment: String, CaseIterable, Identifiable {
        case apps = "Apps", leftovers = "Leftovers"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case size = "Size", name = "Name", lastUsed = "Last Opened"
        var id: String { rawValue }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case unused, large, external
        var id: String { rawValue }
        var title: String {
            switch self {
            case .unused: "Unused"
            case .large: "Large"
            case .external: "External"
            }
        }
        var symbol: String {
            switch self {
            case .unused: "moon.zzz"
            case .large: "scalemass"
            case .external: "externaldrive"
            }
        }
    }

    enum Phase: Equatable {
        case idle, scanning, ready
    }

    enum RelatedState: Equatable {
        case loading
        case loaded([UninstallRelatedFile])
    }

    enum LeftoverPhase: Equatable {
        case idle, scanning, ready
    }

    /// The sheet currently shown.
    enum Flow: Identifiable, Equatable {
        case confirmApp(UninstallerPlan)
        case confirmLeftovers([UninstallTrashItem])
        case working(String)
        case result(title: String, UninstallTrashOutcome)

        /// One identity for every step, so confirm → working → result updates a single sheet in place.
        var id: String { "flow" }
    }

    static let largeThreshold: Int64 = 1_000_000_000
    static let unusedInterval: TimeInterval = 90 * 24 * 3600

    /// Sizes survive leaving and re-entering the screen during one run of the app.
    private static var sizeCache: [String: Int64] = [:]

    var segment: Segment = .apps
    var sort: Sort = .size
    var filters: Set<Filter> = []
    var phase: Phase = .idle
    var apps: [UninstallApp] = []
    var sizes: [String: Int64] = [:]
    var unmeasurable: Set<String> = []
    var runningPaths: Set<String> = []
    var selectedID: String?

    var related: [String: RelatedState] = [:]
    var fileSizes: [String: UninstallSizer.Measurement] = [:]
    var unchecked: Set<String> = []

    var leftoverPhase: LeftoverPhase = .idle
    var leftoverGroups: [UninstallLeftoverGroup] = []
    var leftoverChecked: Set<String> = []
    var expandedGroups: Set<String> = []

    var flow: Flow?

    let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")

    @ObservationIgnored private var sizingTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var relatedTask: Task<Void, Never>?
    @ObservationIgnored private var leftoverTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceTask: Task<Void, Never>?

    // MARK: Lifecycle

    func start() {
        guard phase == .idle else { return }
        refreshRunning()
        observeWorkspace()
        rescan()
    }

    func stop() {
        [sizingTask, scanTask, relatedTask, leftoverTask, workspaceTask].forEach { $0?.cancel() }
        if phase == .scanning { phase = .idle }
        if leftoverPhase == .scanning { leftoverPhase = .idle }
    }

    func rescan() {
        scanTask?.cancel()
        sizingTask?.cancel()
        phase = .scanning
        scanTask = Task { [weak self] in
            let found = await UninstallerBackground.run { UninstallAppScanner.scan() }
            guard let self, !Task.isCancelled else { return }
            self.apps = found
            self.sizes = Self.sizeCache.filter { key, _ in found.contains { $0.id == key } }
            self.unmeasurable = []
            if let selectedID = self.selectedID, !found.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
            if self.selectedID == nil { self.selectedID = self.visibleApps(query: "").first?.id }
            self.phase = .ready
            self.measureSizes()
            if let id = self.selectedID { self.loadRelated(for: id) }
        }
    }

    /// Measures bundles three at a time, largest-looking first isn't knowable, so in list order.
    private func measureSizes() {
        let pending = apps.filter { sizes[$0.id] == nil }.map(\.url)
        guard !pending.isEmpty else { return }
        sizingTask = Task { [weak self] in
            await withTaskGroup(of: (String, Int64?).self) { group in
                var iterator = pending.makeIterator()
                func next() -> Bool {
                    guard let url = iterator.next() else { return false }
                    group.addTask { (url.path, await UninstallerBackground.run { UninstallSizer.measure(url).bytes }) }
                    return true
                }
                for _ in 0..<3 where next() {}
                for await (id, bytes) in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    if let bytes {
                        self?.sizes[id] = bytes
                        Self.sizeCache[id] = bytes
                    } else {
                        self?.unmeasurable.insert(id)
                    }
                    _ = next()
                }
            }
        }
    }

    // MARK: Running apps

    func refreshRunning() {
        let paths = NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path }
        let next = Set(paths)
        if next != runningPaths { runningPaths = next }
    }

    private func observeWorkspace() {
        workspaceTask?.cancel()
        workspaceTask = Task { [weak self] in
            let center = NSWorkspace.shared.notificationCenter
            await withTaskGroup(of: Void.self) { group in
                for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                    group.addTask { @MainActor in
                        for await _ in center.notifications(named: name) {
                            if Task.isCancelled { return }
                            self?.refreshRunning()
                        }
                    }
                }
            }
        }
    }

    func isRunning(_ app: UninstallApp) -> Bool { runningPaths.contains(app.url.path) }

    // MARK: Derived list

    var measuredCount: Int { apps.filter { sizes[$0.id] != nil || unmeasurable.contains($0.id) }.count }
    var isMeasuring: Bool { phase == .ready && measuredCount < apps.count }
    var totalMeasured: Int64 { apps.compactMap { sizes[$0.id] }.reduce(0, +) }

    func matches(_ app: UninstallApp, filter: Filter, now: Date = .now) -> Bool {
        switch filter {
        case .unused: app.lastUsed.map { now.timeIntervalSince($0) >= Self.unusedInterval } ?? false
        case .large: (sizes[app.id] ?? 0) >= Self.largeThreshold
        case .external: app.volume.isExternal
        }
    }

    func count(for filter: Filter) -> Int { apps.filter { matches($0, filter: filter) }.count }

    func visibleApps(query: String) -> [UninstallApp] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = apps.filter { app in
            (query.isEmpty || app.name.localizedCaseInsensitiveContains(query)
                || (app.bundleID?.localizedCaseInsensitiveContains(query) ?? false))
                && filters.allSatisfy { matches(app, filter: $0) }
        }
        switch sort {
        case .name:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            return filtered.sorted {
                let a = sizes[$0.id] ?? -1, b = sizes[$1.id] ?? -1
                return a != b ? a > b : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .lastUsed:
            // Least recently opened first; unknown dates last.
            return filtered.sorted {
                switch ($0.lastUsed, $1.lastUsed) {
                case let (a?, b?): a < b
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
        }
    }

    func toggle(_ filter: Filter) {
        if filters.contains(filter) { filters.remove(filter) } else { filters.insert(filter) }
    }

    var selectedApp: UninstallApp? { apps.first { $0.id == selectedID } }

    func select(_ id: String?) {
        guard id != selectedID else { return }
        selectedID = id
        if let id { loadRelated(for: id) }
    }

    // MARK: Related files

    func loadRelated(for id: String, force: Bool = false) {
        guard let app = apps.first(where: { $0.id == id }) else { return }
        if !force, related[id] != nil { return }
        related[id] = .loading
        relatedTask?.cancel()
        let library = library
        let context = UninstallRelatedFinder.Context(apps: apps, excluding: app)
        relatedTask = Task { [weak self] in
            let files = await UninstallerBackground.run {
                let team = LoginItemSigner.teamIdentifier(atPath: app.url.path)
                return UninstallRelatedFinder.find(for: app, library: library, context: context, teamID: team)
            }
            guard let self, !Task.isCancelled else { return }
            self.related[id] = .loaded(files)
            for file in files where !Self.isDefaultSelected(file) { self.unchecked.insert(file.id) }
            await self.measure(files.compactMap { file in file.measureURL.map { (file.id, $0) } })
        }
    }

    nonisolated static func isDefaultSelected(_ file: UninstallRelatedFile) -> Bool {
        file.sharedWith == nil && file.match != .developerTeam
    }

    /// Measures (id, url-to-measure) pairs off the main actor; the id is the item's own path, the url may be a link target.
    private func measure(_ targets: [(String, URL)]) async {
        let pending = targets.filter { fileSizes[$0.0] == nil }
        await withTaskGroup(of: (String, UninstallSizer.Measurement).self) { group in
            for (id, url) in pending {
                group.addTask { (id, await UninstallerBackground.run { UninstallSizer.measure(url) }) }
            }
            for await (id, measurement) in group {
                if Task.isCancelled { group.cancelAll(); return }
                fileSizes[id] = measurement
            }
        }
    }

    func files(for app: UninstallApp) -> [UninstallRelatedFile]? {
        if case .loaded(let files) = related[app.id] { return files }
        return nil
    }

    func isChecked(_ file: UninstallRelatedFile) -> Bool { !unchecked.contains(file.id) }

    func setChecked(_ file: UninstallRelatedFile, _ value: Bool) {
        guard isChecked(file) != value else { return }
        if value { unchecked.remove(file.id) } else { unchecked.insert(file.id) }
    }

    func setAll(_ files: [UninstallRelatedFile], checked: Bool) {
        let ids = Set(files.map(\.id))
        let next = checked ? unchecked.subtracting(ids) : unchecked.union(ids)
        if next != unchecked { unchecked = next }
    }

    /// Bytes of the app plus checked files that are measured so far; nil while the app itself is unmeasured.
    func plannedBytes(for app: UninstallApp) -> Int64? {
        guard let appBytes = sizes[app.id] else { return nil }
        let files = (files(for: app) ?? []).filter(isChecked)
        return appBytes + files.compactMap { fileSizes[$0.id]?.bytes }.reduce(0, +)
    }

    // MARK: Uninstall flow

    func requestUninstall(_ app: UninstallApp) {
        guard let files = files(for: app) else { return }
        let checked = files.filter(isChecked)
        let plan = UninstallerPlan(app: app, appBytes: sizes[app.id], files: checked,
                                   fileSizes: checked.reduce(into: [:]) { $0[$1.id] = fileSizes[$1.id]?.bytes },
                                   isRunning: isRunning(app),
                                   pendingSizes: checked.contains { fileSizes[$0.id] == nil && $0.measureURL != nil }
                                       || sizes[app.id] == nil)
        flow = .confirmApp(plan)
    }

    func performUninstall(_ plan: UninstallerPlan) {
        let app = plan.app
        Task {
            if plan.isRunning || !UninstallTrasher.runningInstances(of: app).isEmpty {
                flow = .working("Quitting \(app.name)…")
                if let problem = await UninstallTrasher.quit(app) {
                    var outcome = UninstallTrashOutcome()
                    outcome.stopReason = problem
                    flow = .result(title: "\(app.name) is still open", outcome)
                    return
                }
            }
            flow = .working("Moving \(app.name) to the Trash…")
            let outcome = await UninstallTrasher.trash(plan.trashItems, library: library)
            let removedApp = outcome.removed.contains { $0.url == app.url }
            flow = .result(title: removedApp ? "\(app.name) was moved to the Trash" : "\(app.name) wasn’t removed", outcome)
            for item in outcome.removed { fileSizes[item.id] = nil }
            if removedApp {
                apps.removeAll { $0.id == app.id }
                sizes[app.id] = nil
                Self.sizeCache[app.id] = nil
                related[app.id] = nil
                selectedID = visibleApps(query: "").first?.id
                if let id = selectedID { loadRelated(for: id) }
                leftoverPhase = .idle // what counts as a leftover changed
            } else {
                loadRelated(for: app.id, force: true)
            }
            refreshRunning()
        }
    }

    // MARK: Leftovers

    func scanLeftovers() {
        leftoverTask?.cancel()
        leftoverPhase = .scanning
        let library = library
        let known = apps
        leftoverTask = Task { [weak self] in
            let groups = await UninstallerBackground.run { () -> [UninstallLeftoverGroup] in
                // Everything installed anywhere counts, including Apple's apps and ones outside Applications folders.
                let everything = UninstallAppScanner.discoverBundles(
                    roots: UninstallAppScanner.defaultRoots() + [URL(fileURLWithPath: "/System/Applications"),
                                                                URL(fileURLWithPath: "/Applications/Utilities")])
                var ids = known.compactMap(\.bundleID)
                var names = known.flatMap(\.nameCandidates)
                for bundle in everything {
                    if let info = NSDictionary(contentsOf: bundle.url.appendingPathComponent("Contents/Info.plist")),
                       let id = info["CFBundleIdentifier"] as? String { ids.append(id) }
                    names.append(bundle.url.deletingPathExtension().lastPathComponent)
                }
                ids += NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
                // Background items still installed (user and system) keep their vendor's files "in use".
                ids += LoginItemScanner.readAll().map(\.label)
                let index = UninstallLeftovers.Index(bundleIDs: ids, names: names)
                var candidates = UninstallLeftovers.candidates(library: library, index: index, isKnownApp: { id in
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
                })
                for position in candidates.indices {
                    guard let target = candidates[position].item.measureURL else { continue }
                    let measurement = UninstallSizer.measure(target)
                    candidates[position].item.bytes = measurement.bytes
                    candidates[position].item.newest = measurement.newest
                }
                return UninstallLeftovers.group(candidates)
            }
            guard let self, !Task.isCancelled else { return }
            self.leftoverGroups = groups
            self.leftoverChecked = Set(groups.flatMap { $0.items.map(\.id) })
            self.leftoverPhase = .ready
        }
    }

    var leftoverTotal: Int64 { leftoverGroups.reduce(0) { $0 + $1.bytes } }

    var checkedLeftovers: [UninstallLeftoverItem] {
        leftoverGroups.flatMap(\.items).filter { leftoverChecked.contains($0.id) }
    }

    func setLeftover(_ item: UninstallLeftoverItem, checked: Bool) {
        guard leftoverChecked.contains(item.id) != checked else { return }
        if checked { leftoverChecked.insert(item.id) } else { leftoverChecked.remove(item.id) }
    }

    func setGroup(_ group: UninstallLeftoverGroup, checked: Bool) {
        let ids = Set(group.items.map(\.id))
        let next = checked ? leftoverChecked.union(ids) : leftoverChecked.subtracting(ids)
        if next != leftoverChecked { leftoverChecked = next }
    }

    func setAllLeftovers(checked: Bool) {
        let next = checked ? Set(leftoverGroups.flatMap { $0.items.map(\.id) }) : []
        if next != leftoverChecked { leftoverChecked = next }
    }

    func requestLeftoverRemoval() {
        let items = checkedLeftovers.map {
            UninstallTrashItem(url: $0.url, title: $0.url.lastPathComponent, kind: .supportItem, bytes: $0.bytes,
                               linkedTarget: $0.link.target)
        }
        guard !items.isEmpty else { return }
        flow = .confirmLeftovers(items)
    }

    func performLeftoverRemoval(_ items: [UninstallTrashItem]) {
        Task {
            flow = .working("Moving \(items.count) item\(items.count == 1 ? "" : "s") to the Trash…")
            let outcome = await UninstallTrasher.trash(items, library: library)
            let removed = Set(outcome.removed.map(\.id))
            leftoverGroups = leftoverGroups.compactMap { group in
                var copy = group
                copy.items = group.items.filter { !removed.contains($0.id) }
                return copy.items.isEmpty ? nil : copy
            }
            leftoverChecked.subtract(removed)
            flow = .result(title: outcome.failed.isEmpty ? "Leftovers moved to the Trash" : "Some leftovers weren’t removed", outcome)
        }
    }
}

/// Everything the confirmation sheet needs to state exactly what will happen.
struct UninstallerPlan: Equatable {
    let app: UninstallApp
    let appBytes: Int64?
    let files: [UninstallRelatedFile]
    let fileSizes: [String: Int64]
    let isRunning: Bool
    let pendingSizes: Bool

    var fileBytes: Int64 { fileSizes.values.reduce(0, +) }
    var totalBytes: Int64 { (appBytes ?? 0) + fileBytes }
    var agentCount: Int { files.filter { $0.kind == .launchAgent }.count }

    var trashItems: [UninstallTrashItem] {
        var items = [UninstallTrashItem(url: app.url, title: app.url.lastPathComponent,
                                        kind: .appBundle(bundleID: app.bundleID), bytes: appBytes)]
        items += files.map {
            UninstallTrashItem(url: $0.url, title: $0.url.lastPathComponent, kind: .supportItem, bytes: fileSizes[$0.id],
                               unloadsAgent: $0.kind == .launchAgent, linkedTarget: $0.link.target)
        }
        items += app.aliases.map { UninstallTrashItem(url: $0, title: $0.lastPathComponent, kind: .alias, bytes: nil) }
        return items
    }
}

/// Runs blocking file-system work on a GCD queue, so it never occupies the main actor or Swift's cooperative pool.
enum UninstallerBackground {
    private static let queue = DispatchQueue(label: "scoop.uninstaller.io", qos: .userInitiated, attributes: .concurrent)

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
