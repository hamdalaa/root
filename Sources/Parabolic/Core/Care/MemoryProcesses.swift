import Darwin
import Foundation

// MARK: - Process samples

/// One running process as read from libproc.
struct MemoryProcess: Sendable, Identifiable, Equatable {
    let pid: pid_t
    let name: String
    /// Executable path; nil when macOS won't say.
    let path: String?
    /// `ri_phys_footprint`, what Activity Monitor calls "Memory". Nil when the process belongs to another user.
    let footprint: UInt64?
    /// The process macOS holds responsible for this one (e.g. Safari for its WebKit content processes).
    let responsiblePID: pid_t?
    /// Owning user; nil when unreadable.
    var uid: uid_t? = nil

    var id: pid_t { pid }
}

/// Every pid on the system, with the ones we couldn't measure counted rather than hidden.
struct MemoryProcessScan: Sendable {
    let processes: [MemoryProcess]
    /// Processes owned by root or other users whose footprint macOS won't report to us.
    let unreadable: Int
}

/// `pid_t responsibility_get_pid_responsible_for_pid(pid_t)` lives in libsystem but isn't in the SDK headers.
private typealias MemoryResponsibleFunction = @convention(c) (pid_t) -> pid_t
private let memoryResponsibleFunction: MemoryResponsibleFunction? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(symbol, to: MemoryResponsibleFunction.self)
}()

enum MemoryProcessReader {
    private static let pathBufferSize = 4 * Int(MAXPATHLEN)

    /// Reads every process. Takes a few milliseconds; call off the main actor.
    static func scan() -> MemoryProcessScan {
        let pids = allPIDs()
        var processes: [MemoryProcess] = []
        processes.reserveCapacity(pids.count)
        var unreadable = 0
        for pid in pids where pid > 0 {
            let footprint = footprint(of: pid)
            if footprint == nil { unreadable += 1 }
            let path = path(of: pid)
            let responsible = responsiblePID(of: pid)
            processes.append(MemoryProcess(pid: pid, name: name(of: pid, path: path), path: path,
                                           footprint: footprint, responsiblePID: responsible, uid: owner(of: pid)))
        }
        // pid 0 (kernel_task) is never readable from user space.
        if pids.contains(0) { unreadable += 1 }
        return MemoryProcessScan(processes: processes, unreadable: unreadable)
    }

    /// The process macOS holds responsible for `pid`, or nil when it is responsible for itself.
    static func responsiblePID(of pid: pid_t) -> pid_t? {
        memoryResponsibleFunction.map { $0(pid) }.flatMap { $0 > 0 && $0 != pid ? $0 : nil }
    }

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = buffer.withUnsafeMutableBytes { raw in
            proc_listallpids(raw.baseAddress, Int32(raw.count))
        }
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count)))
    }

    private static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    /// Executable path of a live pid. Also used to re-verify a pid right before signalling it.
    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Owning uid of a live pid.
    static func owner(of pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_uid
    }

    private static func name(of pid: pid_t, path: String?) -> String {
        if let path, let last = path.split(separator: "/").last { return String(last) }
        var buffer = [CChar](repeating: 0, count: 64)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { return String(cString: buffer) }
        return "Process \(pid)"
    }
}

// MARK: - App bundles

enum MemoryBundlePath {
    private static let bundleSuffixes = [".app", ".xpc", ".appex", ".framework", ".bundle", ".plugin", ".kext", ".systemextension"]

    /// The outermost `.app` bundle containing `path`, so "Google Chrome Helper (Renderer).app" rolls up into "Google Chrome.app".
    static func outermostApp(of path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        var built = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            built += "/" + component
            if component.count > 4, component.lowercased().hasSuffix(".app") { return built }
        }
        return nil
    }

    /// True for a plain executable that lives in no bundle of any kind (`/opt/homebrew/bin/node`, `/bin/zsh`).
    static func isCommandLineBinary(_ path: String?) -> Bool {
        guard let path, path.hasPrefix("/") else { return false }
        return !path.split(separator: "/").dropLast().contains { component in
            let lower = component.lowercased()
            return bundleSuffixes.contains { lower.count > $0.count && lower.hasSuffix($0) }
        }
    }

    /// "Google Chrome" from "/Applications/Google Chrome.app".
    static func displayName(ofApp path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.lowercased().hasSuffix(".app") ? String(last.dropLast(4)) : last
    }
}

/// Terminals and editors whose children are arbitrary command-line work, not part of the app.
enum MemoryHostApps {
    static let bundleIDs: Set<String> = [
        "net.kovidgoyal.kitty", "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "com.github.wez.wezterm", "dev.warp.Warp-Stable", "dev.warp.Warp-Preview", "dev.warp.Warp",
        "org.alacritty", "io.alacritty", "co.zeit.hyper", "org.tabby", "com.raphaelamorim.rio",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed", "dev.zed.Zed-Preview", "com.exafunction.windsurf", "com.panic.Nova",
        "com.google.android.studio", "com.apple.dt.Xcode",
    ]
    /// Every JetBrains IDE (IntelliJ, PyCharm, GoLand, Fleet…).
    private static let bundleIDPrefixes = ["com.jetbrains."]

    static func isHost(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID) || bundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Reads the bundle id from disk. Safe off the main actor.
    static func isHost(appPath: String) -> Bool {
        isHost(bundleID: Bundle(path: appPath)?.bundleIdentifier)
    }
}

// MARK: - Grouping

/// A set of processes that belong together: one app with its helpers, one command-line tool, or the system bucket.
struct MemoryGroup: Sendable, Identifiable, Equatable {
    enum Kind: Int, Sendable, Comparable {
        case app, tool, system
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    static let systemID = "system"
    static let toolPrefix = "tool:"

    /// App bundle path, `tool:<name>`, or `systemID`.
    let id: String
    let kind: Kind
    let name: String
    /// Sorted by footprint, largest first.
    let processes: [MemoryProcess]
    /// For tools: the terminal/editor apps that launched them (bundle paths, sorted).
    var hostPaths: [String] = []

    var isSystem: Bool { kind == .system }
    var isTool: Bool { kind == .tool }
    var bundlePath: String? { kind == .app ? id : nil }
    var footprint: UInt64 { processes.reduce(0) { $0 + ($1.footprint ?? 0) } }
    var hostNames: [String] { hostPaths.map(MemoryBundlePath.displayName(ofApp:)) }
}

enum MemoryGrouping {
    private enum Key: Hashable {
        case app(String)
        case tool(String)
        case system
    }

    /// Groups processes by app bundle.
    /// - A process inside an `.app` counts toward that app (a terminal's own helpers included).
    /// - A process outside any `.app` joins the app macOS holds responsible for it (Safari's WebKit processes),
    ///   unless that app is a terminal/editor host or the process is a plain command-line binary: then it's listed
    ///   as a command-line tool under its own executable name, never inflating the host.
    /// - Processes launched by `ownAppPath` (Root's own downloads) stay with Root.
    /// Processes we couldn't measure are left out and counted separately by the scan.
    static func group(_ processes: [MemoryProcess], ownAppPath: String? = nil,
                      isHost: (String) -> Bool = MemoryHostApps.isHost(appPath:)) -> [MemoryGroup] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var hostCache: [String: Bool] = [:]
        var buckets: [Key: [MemoryProcess]] = [:]
        var toolHosts: [String: Set<String>] = [:]
        for process in processes where process.footprint != nil {
            let key: Key
            if let app = MemoryBundlePath.outermostApp(of: process.path) {
                key = .app(app)
            } else if let responsible = process.responsiblePID.flatMap({ byPID[$0] }),
                      let app = MemoryBundlePath.outermostApp(of: responsible.path) {
                let host = hostCache[app] ?? isHost(app)
                hostCache[app] = host
                if app != ownAppPath, host || MemoryBundlePath.isCommandLineBinary(process.path) {
                    key = .tool(process.name)
                    toolHosts[process.name, default: []].insert(app)
                } else {
                    key = .app(app)
                }
            } else {
                key = .system
            }
            buckets[key, default: []].append(process)
        }
        return buckets.map { key, members in
            let sorted = members.sorted { ($0.footprint ?? 0, $1.pid) > ($1.footprint ?? 0, $0.pid) }
            switch key {
            case .app(let path):
                return MemoryGroup(id: path, kind: .app, name: MemoryBundlePath.displayName(ofApp: path), processes: sorted)
            case .tool(let name):
                return MemoryGroup(id: MemoryGroup.toolPrefix + name, kind: .tool, name: name, processes: sorted,
                                   hostPaths: (toolHosts[name] ?? []).sorted())
            case .system:
                return MemoryGroup(id: MemoryGroup.systemID, kind: .system, name: "System & background", processes: sorted)
            }
        }
        .sorted { ($1.kind, $0.footprint, $1.name) > ($0.kind, $1.footprint, $0.name) }
    }

    /// Bundle paths of every app that launched a command-line tool in `groups`.
    static func hostPaths(in groups: [MemoryGroup]) -> Set<String> {
        Set(groups.flatMap(\.hostPaths))
    }
}

// MARK: - Signalling processes

enum MemoryKillPolicy {
    /// Quit / Force Quit for a single process: only the user's own processes, never pid 0/1, Root itself,
    /// or anything Root launched.
    static func canSignal(_ process: MemoryProcess, ownUID: uid_t, ownPID: pid_t) -> Bool {
        guard process.pid > 1, process.pid != ownPID, process.responsiblePID != ownPID else { return false }
        guard let uid = process.uid, uid == ownUID, uid != 0 else { return false }
        return true
    }
}

// MARK: - Sorting and search

enum MemorySortOrder: String, CaseIterable, Identifiable, Sendable {
    case memory, name, processes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .memory: "Memory"
        case .name: "Name"
        case .processes: "Processes"
        }
    }
}

extension Array where Element == MemoryGroup {
    /// Groups matching `query` by name or any process name, sorted within each section: apps, then command-line
    /// tools, then the system bucket.
    func memoryFiltered(_ query: String, order: MemorySortOrder) -> [MemoryGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = needle.isEmpty ? self : filter { group in
            group.name.localizedCaseInsensitiveContains(needle)
                || group.processes.contains { $0.name.localizedCaseInsensitiveContains(needle) }
        }
        func sorted(_ groups: [MemoryGroup]) -> [MemoryGroup] {
            switch order {
            case .memory: groups.sorted { ($0.footprint, $1.name) > ($1.footprint, $0.name) }
            case .name: groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            case .processes: groups.sorted { ($0.processes.count, $0.footprint) > ($1.processes.count, $1.footprint) }
            }
        }
        return sorted(matched.filter { $0.kind == .app }) + sorted(matched.filter { $0.kind == .tool })
            + matched.filter(\.isSystem)
    }
}
