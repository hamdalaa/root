import Darwin
import Foundation

// Pure model for the Force Quit panel: which apps run, how much memory and CPU each uses (helpers included),
// which ones "Force Quit All Except" would end, and the SIGKILL fallback. No AppKit here, so it is unit-tested.

/// A regular (Dock) app as NSWorkspace reports it.
struct ForceQuitRunningApp: Sendable, Equatable {
    let pid: pid_t
    let bundleID: String?
    let name: String
    let bundlePath: String?
    let isSelf: Bool
}

/// One process sample: memory footprint and cumulative CPU time.
struct ForceQuitProcessSample: Sendable, Equatable {
    let pid: pid_t
    let path: String?
    let footprint: UInt64?
    let responsiblePID: pid_t?
    /// User + system CPU time since the process started, in nanoseconds.
    let cpuNanoseconds: UInt64
}

/// One row of the panel.
struct ForceQuitApp: Sendable, Equatable, Identifiable {
    let pid: pid_t
    let bundleID: String?
    let name: String
    let bundlePath: String?
    let isSelf: Bool
    /// Footprint of the app and every helper process it owns ("Memory" in Activity Monitor).
    var memory: UInt64 = 0
    var processCount = 0
    /// Percent of one core (can pass 100 on several cores). Nil until two samples exist.
    var cpuPercent: Double?
    /// Total CPU time of the app's processes, for the next CPU figure.
    var cpuNanoseconds: UInt64 = 0
    /// False when macOS reports the app as not responding (the spinning beach ball). Nil when unknown.
    var isResponding: Bool?

    var id: pid_t { pid }

    init(app: ForceQuitRunningApp) {
        pid = app.pid
        bundleID = app.bundleID
        name = app.name
        bundlePath = app.bundlePath
        isSelf = app.isSelf
    }
}

enum ForceQuitCPU {
    /// CPU use between two cumulative readings, as a percent of one core.
    static func percent(previous: UInt64, current: UInt64, elapsed: TimeInterval) -> Double? {
        guard elapsed > 0, current >= previous else { return nil }
        return Double(current - previous) / (elapsed * 1_000_000_000) * 100
    }

    /// `proc_pid_rusage` CPU times are Mach ticks on Apple silicon; this converts them with the timebase.
    static func nanoseconds(machTicks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
        guard denom > 0, numer != denom else { return machTicks }
        return UInt64((Double(machTicks) * Double(numer) / Double(denom)).rounded())
    }
}

enum ForceQuitAggregator {
    /// Rolls processes up into their app: helpers inside the `.app`, then processes macOS holds the app
    /// responsible for (Safari's WebKit processes). Sorted by memory, largest first.
    static func rows(apps: [ForceQuitRunningApp], processes: [ForceQuitProcessSample],
                     previousCPU: [pid_t: UInt64] = [:], elapsed: TimeInterval = 0) -> [ForceQuitApp] {
        var rows = apps.map(ForceQuitApp.init(app:))
        var indexByPath: [String: Int] = [:]
        var indexByPID: [pid_t: Int] = [:]
        for (index, row) in rows.enumerated() {
            if let path = row.bundlePath { indexByPath[path] = indexByPath[path] ?? index }
            indexByPID[row.pid] = index
        }
        for process in processes {
            let owner = MemoryBundlePath.outermostApp(of: process.path).flatMap { indexByPath[$0] }
                ?? indexByPID[process.pid]
                ?? process.responsiblePID.flatMap { indexByPID[$0] }
            guard let owner else { continue }
            rows[owner].memory += process.footprint ?? 0
            rows[owner].processCount += 1
            rows[owner].cpuNanoseconds += process.cpuNanoseconds
        }
        for index in rows.indices {
            guard let before = previousCPU[rows[index].pid] else { continue }
            rows[index].cpuPercent = ForceQuitCPU.percent(previous: before, current: rows[index].cpuNanoseconds,
                                                          elapsed: elapsed)
        }
        return rows.sorted { ($0.memory, $1.name) > ($1.memory, $0.name) }
    }

    /// pid → CPU time, carried to the next sample.
    static func cpuTotals(_ rows: [ForceQuitApp]) -> [pid_t: UInt64] {
        Dictionary(rows.map { ($0.pid, $0.cpuNanoseconds) }, uniquingKeysWith: { first, _ in first })
    }
}

enum ForceQuitPolicy {
    /// Parts of macOS that "Force Quit All" leaves alone. Finder can still be force quit on its own row:
    /// macOS relaunches it straight away.
    static let sparedByQuitAll: Set<String> = [
        "com.apple.finder", "com.apple.loginwindow", "com.apple.dock", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.WindowManager",
    ]

    static func canQuit(_ app: ForceQuitApp) -> Bool {
        !app.isSelf && app.pid > 1
    }

    /// Apps that "Force Quit All Except…" ends: every quittable app except the kept ones and the spared ones.
    static func targetsForQuitAll(_ apps: [ForceQuitApp], keeping kept: Set<pid_t>) -> [ForceQuitApp] {
        apps.filter { app in
            canQuit(app) && !kept.contains(app.pid) && !sparedByQuitAll.contains(app.bundleID ?? "")
        }
    }

    /// The page's search: app name or bundle ID, any case. Blank shows every app.
    static func filter(_ apps: [ForceQuitApp], query: String) -> [ForceQuitApp] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(query) }
    }

    /// The app using the most CPU right now; nil until a CPU figure exists.
    static func busiest(_ apps: [ForceQuitApp]) -> ForceQuitApp? {
        apps.filter { $0.cpuPercent != nil }.max { ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0) }
    }

    /// "Force quit 3 apps? Safari, Slack and Xcode will close at once, without saving."
    static func confirmMessage(for targets: [ForceQuitApp]) -> String {
        let names = targets.map(\.name)
        let shown = names.prefix(6)
        var list = ListFormatter.localizedString(byJoining: Array(shown))
        if names.count > shown.count { list += " and \(names.count - shown.count) more" }
        let count = targets.count == 1 ? "1 app" : "\(targets.count) apps"
        return "This force quits \(count): \(list). Unsaved changes in them are lost."
    }
}

enum ForceQuitOutcome: Equatable, Sendable {
    case terminated
    case killed
    case failed(String)
}

enum ForceQuitEscalation {
    /// Grace period after `forceTerminate()` before SIGKILL.
    static let grace: Duration = .milliseconds(1500)
    private static let step: Duration = .milliseconds(100)

    /// `NSRunningApplication.forceTerminate()`, then SIGKILL if the app is still alive after the grace period.
    static func run(pid: pid_t, name: String,
                    forceTerminate: () -> Bool,
                    isAlive: () -> Bool,
                    sendSignal: (pid_t, Int32) -> Int32,
                    wait: (Duration) async -> Void) async -> ForceQuitOutcome {
        if forceTerminate() {
            var waited: Duration = .zero
            while isAlive(), waited < grace {
                await wait(step)
                waited += step
            }
            if !isAlive() { return .terminated }
        }
        guard sendSignal(pid, SIGKILL) == 0 else {
            return .failed("macOS refused to end \(name): \(String(cString: strerror(errno))).")
        }
        for _ in 0..<10 where isAlive() { await wait(step) }
        return isAlive() ? .failed("\(name) is still running.") : .killed
    }
}
