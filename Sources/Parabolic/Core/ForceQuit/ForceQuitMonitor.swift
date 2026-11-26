import AppKit
import ApplicationServices
import Darwin
import Foundation
import Observation

/// Reads every process the user owns: footprint and CPU time in one `proc_pid_rusage` call.
enum ForceQuitSampler {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Call off the main actor; a full scan takes a few milliseconds.
    static func sample(ownerUID: uid_t = getuid()) -> [ForceQuitProcessSample] {
        MemoryProcessReader.allPIDs().compactMap { pid in
            guard pid > 1, MemoryProcessReader.owner(of: pid) == ownerUID else { return nil }
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
                }
            }
            guard ok else { return nil }
            let ticks = info.ri_user_time &+ info.ri_system_time
            return ForceQuitProcessSample(pid: pid, path: MemoryProcessReader.path(of: pid), footprint: info.ri_phys_footprint,
                                          responsiblePID: MemoryProcessReader.responsiblePID(of: pid),
                                          cpuNanoseconds: ForceQuitCPU.nanoseconds(machTicks: ticks, numer: timebase.numer,
                                                                                   denom: timebase.denom))
        }
    }
}

/// "Not responding", from two signals:
/// 1. WindowServer's hang flag (`CGSEventIsAppUnresponsive`, private, resolved at runtime): set when an app
///    leaves the events WindowServer sends it unread (the spinning beach ball).
/// 2. With Accessibility allowed, a 0.25 s accessibility ping: a hung main thread can't answer it. This also
///    catches hangs WindowServer hasn't flagged yet (no input sent to the app).
enum AppResponsiveness {
    static let pingTimeout: Float = 0.25
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias IsUnresponsive = @convention(c) (Int32, UnsafePointer<ProcessSerialNumber>) -> Bool
    private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let functions: (MainConnection, IsUnresponsive, ProcessForPID)? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let connection = dlsym(handle, "CGSMainConnectionID"),
              let unresponsive = dlsym(handle, "CGSEventIsAppUnresponsive"),
              let psn = dlsym(handle, "GetProcessForPID") else { return nil }
        return (unsafeBitCast(connection, to: MainConnection.self),
                unsafeBitCast(unresponsive, to: IsUnresponsive.self),
                unsafeBitCast(psn, to: ProcessForPID.self))
    }()

    static var isAvailable: Bool { functions != nil }

    /// True / false, or nil when macOS won't say. May block up to `pingTimeout`: call off the main actor.
    static func isResponding(pid: pid_t) -> Bool? {
        let flagged = windowServerResponding(pid: pid)
        if flagged == false { return false }
        guard AXIsProcessTrusted() else { return flagged }
        return accessibilityPing(pid: pid) ?? flagged
    }

    static func windowServerResponding(pid: pid_t) -> Bool? {
        guard let (connection, unresponsive, processForPID) = functions else { return nil }
        var psn = ProcessSerialNumber()
        guard processForPID(pid, &psn) == noErr else { return nil }
        return !unresponsive(connection(), &psn)
    }

    /// kAXErrorCannotComplete after the timeout = the app's main thread is stuck.
    static func accessibilityPing(pid: pid_t) -> Bool? {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, pingTimeout)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) {
        case .success: return true
        case .cannotComplete: return false
        default: return nil
        }
    }

    /// Checks many apps at once, so one hung app costs one timeout, not one per app.
    static func check(_ pids: [pid_t]) -> [pid_t: Bool] {
        var answers = [Bool?](repeating: nil, count: pids.count)
        answers.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: pids.count) { index in
                base[index] = isResponding(pid: pids[index])
            }
        }
        var result: [pid_t: Bool] = [:]
        for (pid, answer) in zip(pids, answers) { if let answer { result[pid] = answer } }
        return result
    }
}

/// Live state of Force Quit (the Mac Care page and the ⌃⌥⌘⎋ panel). Samples only while a view awaits `run()`.
@MainActor
@Observable
final class ForceQuitMonitor {
    static let shared = ForceQuitMonitor()
    static let interval: Duration = .seconds(2)

    private(set) var apps: [ForceQuitApp] = []
    private(set) var hasSampled = false
    /// Apps being ended right now (spinner on their row).
    private(set) var ending: Set<pid_t> = []
    /// Short result line, e.g. "Force quit Slack."
    private(set) var notice: String?

    @ObservationIgnored private var previousCPU: [pid_t: UInt64] = [:]
    @ObservationIgnored private var lastSample: ContinuousClock.Instant?
    /// Views awaiting `run()` right now; the page and the panel can both be open.
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Samples every 2 seconds until the calling view's task is cancelled. One shared loop runs while any view
    /// is watching, so closing the panel doesn't stop the page's numbers (or the other way round).
    func run() async {
        watchers += 1
        if loop == nil {
            loop = Task { [weak self] in
                while !Task.isCancelled, let self, self.watchers > 0 {
                    await self.refresh()
                    try? await Task.sleep(for: Self.interval)
                }
            }
        }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        watchers -= 1
        if watchers == 0 {
            loop?.cancel()
            loop = nil
        }
    }

    func refresh() async {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map { app in
                ForceQuitRunningApp(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                                    name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App",
                                    bundlePath: app.bundleURL?.path, isSelf: app.processIdentifier == ownPID)
            }
        let pids = running.map(\.pid)
        let (samples, responding) = await Task.detached(priority: .userInitiated) {
            (ForceQuitSampler.sample(), AppResponsiveness.check(pids))
        }.value
        let now = ContinuousClock.now
        let elapsed = lastSample.map { now - $0 }.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 } ?? 0
        var rows = ForceQuitAggregator.rows(apps: running, processes: samples, previousCPU: previousCPU, elapsed: elapsed)
        for index in rows.indices { rows[index].isResponding = responding[rows[index].pid] }
        previousCPU = ForceQuitAggregator.cpuTotals(rows)
        lastSample = now
        if apps != rows { apps = rows }
        if !hasSampled { hasSampled = true }
    }

    var notRespondingCount: Int { apps.filter { $0.isResponding == false }.count }

    // MARK: Actions

    /// Asks the app to quit (it may ask to save first).
    func quit(_ app: ForceQuitApp) {
        guard let running = verified(app) else { return }
        show(running.terminate() ? "Asked \(app.name) to quit." : "\(app.name) didn’t accept the request to quit.")
        refreshSoon()
    }

    /// Ends the app at once: `forceTerminate()`, then SIGKILL if it is still alive.
    func forceQuit(_ app: ForceQuitApp) async {
        guard let running = verified(app) else { return }
        ending.insert(app.pid)
        let outcome = await Self.end(running, name: app.name)
        ending.remove(app.pid)
        switch outcome {
        case .terminated: show("Force quit \(app.name).")
        case .killed: show("\(app.name) was stuck, so Root ended it with SIGKILL.")
        case .failed(let reason): show(reason)
        }
        await refresh()
    }

    /// Force quits every app except `kept`, Root and the parts of macOS listed in `ForceQuitPolicy`.
    func forceQuitAll(except kept: Set<pid_t>) async {
        let targets = ForceQuitPolicy.targetsForQuitAll(apps, keeping: kept).compactMap { app in
            verified(app, quiet: true).map { (app, $0) }
        }
        ending.formUnion(targets.map(\.0.pid))
        var ended = 0
        await withTaskGroup(of: ForceQuitOutcome.self) { group in
            for (app, running) in targets {
                group.addTask { @MainActor in await Self.end(running, name: app.name) }
            }
            for await outcome in group {
                if case .failed = outcome { continue }
                ended += 1
            }
        }
        ending.subtract(targets.map(\.0.pid))
        let failed = targets.count - ended
        show(failed == 0 ? "Force quit \(ended) app\(ended == 1 ? "" : "s")."
                         : "Force quit \(ended) of \(targets.count) apps. \(failed) refused.")
        await refresh()
    }

    private static func end(_ running: NSRunningApplication, name: String) async -> ForceQuitOutcome {
        let pid = running.processIdentifier
        return await ForceQuitEscalation.run(
            pid: pid, name: name,
            forceTerminate: { running.forceTerminate() },
            isAlive: { kill(pid, 0) == 0 },
            sendSignal: { kill($0, $1) },
            wait: { try? await Task.sleep(for: $0) })
    }

    /// Re-reads the app right before acting, so a stale row (or a reused pid) can't end something else.
    private func verified(_ app: ForceQuitApp, quiet: Bool = false) -> NSRunningApplication? {
        guard ForceQuitPolicy.canQuit(app), app.pid != ownPID,
              let running = NSRunningApplication(processIdentifier: app.pid), !running.isTerminated,
              running.bundleIdentifier == app.bundleID else {
            if !quiet { show("\(app.name) already quit.") }
            return nil
        }
        return running
    }

    private func refreshSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            await self?.refresh()
        }
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
}
