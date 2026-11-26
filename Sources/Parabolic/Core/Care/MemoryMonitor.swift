import AppKit
import Foundation
import Observation

/// What we know about the GUI app behind a process group. Re-resolved every scan; never cached across launches.
struct MemoryAppInfo: Equatable, Sendable {
    let pid: pid_t
    let bundleID: String?
    let isActive: Bool
    let isHidden: Bool
    let isSelf: Bool
    let canQuit: Bool
    /// A terminal or editor (see `MemoryHostApps`); never suggested for quitting.
    var isHost: Bool = false
}

enum MemoryPurgeState: Equatable, Sendable {
    case idle
    case running
    case done(MemoryPurgeResult)
    case cancelled
    case failed(String)
}

/// Live memory sampler for the Memory screen. Samples only while `run()` is being awaited (the view's `.task`),
/// so nothing ticks when the screen is hidden. History survives navigating away, with a gap.
@MainActor
@Observable
final class MemoryMonitor {
    static let shared = MemoryMonitor()

    struct HistoryPoint: Identifiable, Sendable, Equatable {
        let date: Date
        let pressurePercent: Double?
        let level: MemoryPressureLevel?
        let swapUsed: UInt64?
        let used: UInt64
        var id: Date { date }
    }

    /// Five minutes at one sample a second.
    static let historyWindow: TimeInterval = 300
    private static let processInterval = 2

    private(set) var snapshot: MemorySnapshot?
    private(set) var readError: String?
    private(set) var history: [HistoryPoint] = []
    private(set) var groups: [MemoryGroup] = []
    private(set) var unreadableProcesses = 0
    private(set) var hasScannedProcesses = false
    private(set) var apps: [String: MemoryAppInfo] = [:]
    /// Bytes per second moved to and from swap, from the last two samples.
    private(set) var swapInRate: Double?
    private(set) var swapOutRate: Double?
    private(set) var purge: MemoryPurgeState = .idle
    /// A short note after Quit / Force Quit, e.g. "Asked Safari to quit."
    private(set) var notice: String?

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private let ownPID = ProcessInfo.processInfo.processIdentifier
    @ObservationIgnored private let ownBundleID = Bundle.main.bundleIdentifier
    @ObservationIgnored private let ownBundlePath = MemoryBundlePath.outermostApp(of: Bundle.main.bundlePath)
        ?? MemoryBundlePath.outermostApp(of: Bundle.main.executablePath)

    // MARK: Sampling loop

    /// Samples every second until the calling task is cancelled.
    /// If the screen reappears before the previous loop has noticed its cancellation, the newest loop takes over.
    func run() async {
        generation += 1
        let mine = generation
        var tick = 0
        while !Task.isCancelled, generation == mine {
            await sampleStats()
            if tick % Self.processInterval == 0 { await scanProcesses() }
            tick += 1
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Takes the first reading on the spot (a few Mach calls, well under a millisecond) so the screen
    /// appears with real numbers instead of fading into a "Reading memory…" placeholder.
    func primeIfNeeded() {
        guard snapshot == nil, readError == nil, let first = try? MemorySampler.read() else { return }
        snapshot = first
        history = [HistoryPoint(date: first.date, pressurePercent: first.pressurePercent, level: first.pressure,
                                swapUsed: first.swap?.used, used: first.breakdown.used)]
    }

    func retry() {
        Task { await sampleStats(); await scanProcesses() }
    }

    private func sampleStats() async {
        let result = await Task.detached(priority: .utility) { () -> Result<MemorySnapshot, Error> in
            Result { try MemorySampler.read() }
        }.value
        switch result {
        case .success(let next):
            if let previous = snapshot {
                let seconds = max(0.25, next.date.timeIntervalSince(previous.date))
                let page = Double(next.counts.pageSize)
                swapInRate = Self.rate(previous.counts.swapins, next.counts.swapins, page: page, seconds: seconds)
                swapOutRate = Self.rate(previous.counts.swapouts, next.counts.swapouts, page: page, seconds: seconds)
            }
            snapshot = next
            if readError != nil { readError = nil }
            let point = HistoryPoint(date: next.date, pressurePercent: next.pressurePercent, level: next.pressure,
                                     swapUsed: next.swap?.used, used: next.breakdown.used)
            let cutoff = next.date.addingTimeInterval(-Self.historyWindow)
            history = Array((history + [point]).drop { $0.date < cutoff })
        case .failure(let error):
            let message = error.localizedDescription
            if readError != message { readError = message }
        }
    }

    private static func rate(_ old: UInt64, _ new: UInt64, page: Double, seconds: Double) -> Double? {
        guard new >= old else { return nil }
        return Double(new - old) * page / seconds
    }

    private func scanProcesses() async {
        let ownPath = ownBundlePath
        let (scan, grouped) = await Task.detached(priority: .utility) { () -> (MemoryProcessScan, [MemoryGroup]) in
            let scan = MemoryProcessReader.scan()
            return (scan, MemoryGrouping.group(scan.processes, ownAppPath: ownPath))
        }.value
        let resolved = resolveApps(for: grouped)
        if groups != grouped { groups = grouped }
        if apps != resolved { apps = resolved }
        if unreadableProcesses != scan.unreadable { unreadableProcesses = scan.unreadable }
        if !hasScannedProcesses { hasScannedProcesses = true }
    }

    /// Matches each group to the running GUI app among its processes.
    private func resolveApps(for groups: [MemoryGroup]) -> [String: MemoryAppInfo] {
        let running = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
                                 uniquingKeysWith: { first, _ in first })
        var result: [String: MemoryAppInfo] = [:]
        for group in groups {
            guard let bundlePath = group.bundlePath else { continue }
            let candidates = group.processes.compactMap { running[$0.pid] }
            guard let app = candidates.first(where: { $0.activationPolicy == .regular })
                ?? candidates.first(where: { $0.activationPolicy == .accessory }) else { continue }
            let isSelf = app.processIdentifier == ownPID || bundlePath == ownBundlePath
            let canQuit = !isSelf && MemoryQuitPolicy.canQuit(bundleID: app.bundleIdentifier, bundlePath: bundlePath,
                                                              ownBundleID: ownBundleID, ownBundlePath: ownBundlePath)
            result[bundlePath] = MemoryAppInfo(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                                               isActive: app.isActive, isHidden: app.isHidden,
                                               isSelf: isSelf, canQuit: canQuit,
                                               isHost: MemoryHostApps.isHost(bundleID: app.bundleIdentifier))
        }
        return result
    }

    // MARK: Derived

    /// Quittable background apps worth quitting. Never terminals or editors.
    var suggestions: [MemoryGroup] { MemorySuggestions.pick(groups, apps: apps) }

    var verdict: MemoryVerdict? {
        guard let snapshot else { return nil }
        let top = suggestions.first.map { MemoryCandidate(name: $0.name, footprint: $0.footprint) }
        return MemoryVerdict.make(pressure: snapshot.pressure, breakdown: snapshot.breakdown,
                                  swap: snapshot.swap, candidate: top)
    }

    // MARK: Actions

    func quit(_ group: MemoryGroup) {
        guard let app = runningApp(for: group) else { return }
        let asked = app.terminate()
        show(asked ? "Asked \(group.name) to quit. If it has unsaved work, it will ask you first."
                   : "\(group.name) didn’t accept the request to quit.")
    }

    func forceQuit(_ group: MemoryGroup) {
        guard let app = runningApp(for: group) else { return }
        let done = app.forceTerminate()
        show(done ? "Force quit \(group.name)." : "macOS couldn’t force quit \(group.name).")
    }

    /// SIGTERM (`force == false`) or SIGKILL one of the user's own processes. Re-verifies owner and executable
    /// right before signalling, so a recycled pid is never hit.
    func signal(_ process: MemoryProcess, force: Bool) {
        let current = MemoryProcess(pid: process.pid, name: process.name, path: MemoryProcessReader.path(of: process.pid),
                                    footprint: process.footprint, responsiblePID: process.responsiblePID,
                                    uid: MemoryProcessReader.owner(of: process.pid))
        guard process.path != nil, current.path == process.path else {
            show("\(process.name) already exited.")
            return
        }
        guard canSignal(current) else {
            show("\(process.name) can’t be quit from here.")
            return
        }
        if kill(process.pid, force ? SIGKILL : SIGTERM) == 0 {
            show(force ? "Force quit \(process.name) (PID \(process.pid))." : "Asked \(process.name) (PID \(process.pid)) to quit.")
        } else {
            show("Couldn’t quit \(process.name): \(String(cString: strerror(errno))).")
        }
    }

    func canSignal(_ process: MemoryProcess) -> Bool {
        MemoryKillPolicy.canSignal(process, ownUID: getuid(), ownPID: ownPID)
    }

    func reveal(_ path: String) {
        FinderReveal.reveal([URL(fileURLWithPath: path)])
    }

    /// Re-checks the policy at the moment of the action, so a stale row can't quit something protected.
    private func runningApp(for group: MemoryGroup) -> NSRunningApplication? {
        guard let path = group.bundlePath, let info = apps[path], info.canQuit,
              let app = NSRunningApplication(processIdentifier: info.pid), !app.isTerminated,
              app.processIdentifier != ownPID,
              MemoryQuitPolicy.canQuit(bundleID: app.bundleIdentifier, bundlePath: path,
                                       ownBundleID: ownBundleID, ownBundlePath: ownBundlePath) else {
            show("\(group.name) can’t be quit from here.")
            return nil
        }
        return app
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Purge

    /// Runs `/usr/sbin/purge` as administrator (macOS shows its own password prompt) and measures the effect.
    func freeUpMemory() async {
        guard purge != .running else { return }
        purge = .running
        let before = try? await Task.detached { try MemorySampler.read() }.value
        let script = "do shell script \"/usr/sbin/purge\" with administrator privileges"
        do {
            let output = try await ProcessRunner.capture(executable: "/usr/bin/osascript", arguments: ["-e", script])
            guard output.status == 0 else {
                // -128 is "User canceled." from the authorization prompt.
                purge = output.stderr.contains("-128") ? .cancelled : .failed(Self.cleanError(output.stderr))
                return
            }
            try? await Task.sleep(for: .seconds(1.5))
            let after = try? await Task.detached { try MemorySampler.read() }.value
            guard let before, let after else {
                purge = .failed("Purge ran, but Root couldn’t read memory afterwards to measure the change.")
                return
            }
            purge = .done(MemoryPurgeResult(freeBefore: before.breakdown.free, freeAfter: after.breakdown.free,
                                            cachedBefore: before.breakdown.cached, cachedAfter: after.breakdown.cached))
        } catch {
            purge = .failed(error.localizedDescription)
        }
    }

    func dismissPurgeResult() {
        if purge != .idle { purge = .idle }
    }

    private static func cleanError(_ stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "purge exited with an error." : trimmed
    }
}
