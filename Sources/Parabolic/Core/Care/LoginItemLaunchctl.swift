import Foundation

/// What `launchctl print` reports about one service.
struct LoginItemServiceInfo: Equatable, Sendable {
    var state: String?
    var pid: Int?
    var lastExitCode: String?
    var runs: Int?
    var path: String?
}

/// Live state of a background item.
enum LoginItemStatus: Equatable, Sendable {
    case running(pid: Int)
    /// Loaded into launchd but not running right now.
    case loaded(lastExit: String?)
    case notLoaded
    case disabled
    case unknown

    var title: String {
        switch self {
        case .running: "Running"
        case .loaded: "Loaded"
        case .notLoaded: "Not loaded"
        case .disabled: "Off"
        case .unknown: "Status unknown"
        }
    }

    var isActive: Bool {
        switch self {
        case .running, .loaded: true
        default: false
        }
    }

    static func derive(info: LoginItemServiceInfo?, isDisabled: Bool, queried: Bool) -> LoginItemStatus {
        if let pid = info?.pid, pid > 0 { return .running(pid: pid) }
        if isDisabled { return .disabled }
        guard queried else { return .unknown }
        guard let info else { return .notLoaded }
        if info.state == "running" { return .running(pid: info.pid ?? 0) }
        return .loaded(lastExit: info.lastExitCode)
    }
}

/// Runs and parses `launchctl`. Only the read-only verbs run automatically; `disable`/`enable` run on an explicit user action.
enum LoginItemLaunchctl {
    static let tool = "/bin/launchctl"

    static var userDomain: String { "gui/\(getuid())" }

    /// Parses the top-level `key = value` lines of `launchctl print`. Nil when the service isn't loaded.
    static func parsePrint(_ output: String) -> LoginItemServiceInfo? {
        if output.contains("Could not find service") || output.contains("Bad request") { return nil }
        var info = LoginItemServiceInfo()
        var sawHeader = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasSuffix("= {"), !line.hasPrefix("\t") { sawHeader = true; continue }
            // Only depth-1 keys: exactly one leading tab.
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let body = line.dropFirst()
            guard let separator = body.range(of: " = ") else { continue }
            let key = body[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = body[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "state": info.state = value
            case "pid": info.pid = Int(value)
            case "last exit code": info.lastExitCode = value
            case "runs": info.runs = Int(value)
            case "path": info.path = value
            default: break
            }
        }
        return sawHeader || info.state != nil ? info : nil
    }

    /// Parses `launchctl print-disabled <domain>` into label → disabled.
    static func parseDisabled(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""), let arrow = trimmed.range(of: "\" => ") else { continue }
            let label = String(trimmed[trimmed.index(after: trimmed.startIndex)..<arrow.lowerBound])
            let value = trimmed[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("disabled") || value == "true" { result[label] = true }
            else if value.hasPrefix("enabled") || value == "false" { result[label] = false }
        }
        return result
    }

    /// Parses `launchctl list` ("PID  Status  Label") into label → pid (nil when not running).
    static func parseList(_ output: String) -> [String: Int?] {
        var result: [String: Int?] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3 else { continue }
            result[String(columns[2])] = Int(columns[0])
        }
        return result
    }

    struct Output: Sendable {
        var status: Int32
        var text: String
    }

    private static let queue = DispatchQueue(label: "scoop.loginitems.launchctl", qos: .userInitiated, attributes: .concurrent)

    /// Runs launchctl on a GCD queue (never the main actor or the cooperative pool) and returns its combined output.
    static func run(_ arguments: [String]) async -> Output {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: runBlocking(arguments)) }
        }
    }

    private static func runBlocking(_ arguments: [String]) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Output(status: -1, text: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
    }

    /// Stops the agent now and keeps it from loading at the next login. Reversible with `enable`.
    static func disable(label: String, plistPath: String) async -> String? {
        let domain = userDomain
        _ = await run(["bootout", domain, plistPath]) // fails harmlessly when it isn't loaded
        let result = await run(["disable", "\(domain)/\(label)"])
        return result.status == 0 ? nil : failure(result, verb: "turn off")
    }

    /// Allows the agent again and loads it now.
    static func enable(label: String, plistPath: String) async -> String? {
        let domain = userDomain
        let allowed = await run(["enable", "\(domain)/\(label)"])
        guard allowed.status == 0 else { return failure(allowed, verb: "turn on") }
        let loaded = await run(["bootstrap", domain, plistPath])
        // 37 / 17 / "already loaded" all mean it's in launchd now, which is what we want.
        if loaded.status == 0 || loaded.text.localizedCaseInsensitiveContains("already") || loaded.status == 37 { return nil }
        return failure(loaded, verb: "start")
    }

    /// Unloads an item before its file is removed.
    static func unload(plistPath: String) async {
        _ = await run(["bootout", userDomain, plistPath])
    }

    private static func failure(_ output: Output, verb: String) -> String {
        let message = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "launchctl couldn’t \(verb) this item (code \(output.status))." : message
    }
}
