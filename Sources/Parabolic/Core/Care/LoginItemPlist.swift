import Foundation

/// The parts of a launchd property list that matter for showing and checking a background item.
struct LoginItemPlist: Sendable, Equatable {
    enum KeepAlive: Sendable, Equatable {
        case never, always, conditional
    }

    var label: String?
    var program: String?
    var arguments: [String] = []
    var runAtLoad = false
    var keepAlive: KeepAlive = .never
    /// SMAppService-style items: a path relative to the owning app bundle.
    var bundleProgram: String?
    var associatedBundleIDs: [String] = []
    /// The legacy `Disabled` key in the file itself.
    var isDisabledInFile = false
    var startInterval: Int?
    var hasCalendarSchedule = false
    var watchesPaths = false
    var hasMachServices = false
    var pathEnvironment: String?

    enum ParseError: LocalizedError, Equatable {
        case unreadable
        case notADictionary

        var errorDescription: String? {
            switch self {
            case .unreadable: "The file isn’t a valid property list."
            case .notADictionary: "The file doesn’t describe a background item."
            }
        }
    }

    static func parse(data: Data) throws(ParseError) -> LoginItemPlist {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw .unreadable
        }
        guard let dict = object as? [String: Any] else { throw .notADictionary }
        return LoginItemPlist(dictionary: dict)
    }

    init(dictionary dict: [String: Any]) {
        label = Self.nonEmpty(dict["Label"] as? String)
        program = Self.nonEmpty(dict["Program"] as? String)
        arguments = (dict["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? []
        runAtLoad = (dict["RunAtLoad"] as? Bool) ?? false
        switch dict["KeepAlive"] {
        case let flag as Bool: keepAlive = flag ? .always : .never
        case let conditions as [String: Any]: keepAlive = conditions.isEmpty ? .never : .conditional
        default: keepAlive = .never
        }
        bundleProgram = Self.nonEmpty(dict["BundleProgram"] as? String)
        associatedBundleIDs = (dict["AssociatedBundleIdentifiers"] as? [String])
            ?? (dict["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
        isDisabledInFile = (dict["Disabled"] as? Bool) ?? false
        startInterval = dict["StartInterval"] as? Int
        hasCalendarSchedule = dict["StartCalendarInterval"] != nil
        watchesPaths = dict["WatchPaths"] != nil || dict["QueueDirectories"] != nil
        hasMachServices = dict["MachServices"] != nil || dict["Sockets"] != nil
        pathEnvironment = (dict["EnvironmentVariables"] as? [String: Any])?["PATH"] as? String
    }

    init() {}

    /// What launchd executes: `Program` wins over `ProgramArguments[0]`.
    var executable: String? { program ?? arguments.first.flatMap(Self.nonEmpty) }

    /// Starts by itself when you log in (rather than on demand).
    var startsAtLogin: Bool { runAtLoad || keepAlive == .always }

    /// Plain description of when the item runs.
    var trigger: String {
        if keepAlive == .always { return "Always running" }
        if runAtLoad { return keepAlive == .conditional ? "At login, restarts when needed" : "At login" }
        if let startInterval, startInterval > 0 { return "Every \(LoginItemPlist.interval(startInterval))" }
        if hasCalendarSchedule { return "On a schedule" }
        if watchesPaths { return "When files change" }
        if keepAlive == .conditional { return "When needed" }
        return "On demand"
    }

    static func interval(_ seconds: Int) -> String {
        if seconds % 86400 == 0 { return seconds == 86400 ? "day" : "\(seconds / 86400) days" }
        if seconds % 3600 == 0 { return seconds == 3600 ? "hour" : "\(seconds / 3600) hours" }
        if seconds % 60 == 0 { return seconds == 60 ? "minute" : "\(seconds / 60) min" }
        return "\(seconds) s"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
