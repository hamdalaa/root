import Foundation

/// Whether a background item's program is actually there.
enum LoginItemHealth: Equatable, Sendable {
    case ok
    /// The program (or the script it runs) is missing, or the file has no program at all.
    case broken(String)
    /// The program lives on a drive that isn't connected right now — not counted as broken.
    case volumeOffline(String)
    /// Couldn't confirm either way (bare command names, app-relative programs).
    case unverified(String)

    var isBroken: Bool { if case .broken = self { true } else { false } }

    var reason: String? {
        switch self {
        case .ok: nil
        case .broken(let text), .unverified(let text): text
        case .volumeOffline(let name): "Its program is on “\(name)”, which isn’t connected."
        }
    }
}

/// Pure checks on a parsed plist, with the file system injected for tests.
enum LoginItemInspector {
    static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "fish", "python", "python3", "python2", "node", "ruby", "perl", "osascript",
        "bun", "deno", "php", "swift",
    ]

    static let defaultSearchPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Expands `~` and `$HOME` the way people (wrongly) expect launchd to.
    static func expand(_ path: String, home: String) -> String {
        var result = path
        if result == "~" { return home }
        if result.hasPrefix("~/") { result = home + result.dropFirst(1) }
        return result.replacingOccurrences(of: "$HOME", with: home).replacingOccurrences(of: "${HOME}", with: home)
    }

    /// The script an interpreter runs (`/usr/bin/python3 /path/script.py` → the script), when there is one.
    static func scriptPath(_ plist: LoginItemPlist) -> String? {
        guard let executable = plist.executable else { return nil }
        let name = (executable as NSString).lastPathComponent
        var args = plist.arguments.dropFirst()
        if name == "env" {
            // `/usr/bin/env python3 script.py`
            while let first = args.first, first.hasPrefix("-") || first.contains("=") { args = args.dropFirst() }
            guard let interpreter = args.first, interpreters.contains((interpreter as NSString).lastPathComponent) else { return nil }
            args = args.dropFirst()
        } else if !interpreters.contains(name) {
            return nil
        }
        for arg in args {
            if arg == "-c" || arg == "-e" || arg == "-m" { return nil } // inline code, not a file
            if arg.hasPrefix("-") { continue }
            return arg.hasPrefix("/") || arg.hasPrefix("~") ? arg : nil
        }
        return nil
    }

    static func evaluate(plist: LoginItemPlist?, parseError: String?, home: String,
                         fileExists: (String) -> Bool, mountedVolumes: Set<String>) -> LoginItemHealth {
        guard let plist else { return .broken(parseError ?? "The file can’t be read.") }
        guard let rawExecutable = plist.executable else {
            if plist.bundleProgram != nil { return .unverified("Runs a program from inside its app.") }
            return .broken("The file doesn’t say which program to run.")
        }
        let executable = expand(rawExecutable, home: home)
        if executable.hasPrefix("/") {
            if !fileExists(executable) { return missing(executable, what: "Program", mountedVolumes: mountedVolumes) }
        } else {
            let search = (plist.pathEnvironment ?? defaultSearchPath).split(separator: ":").map(String.init)
            let found = search.contains { fileExists(($0 as NSString).appendingPathComponent(executable)) }
            if !found { return .unverified("Couldn’t find “\(executable)” in launchd’s search path.") }
        }
        if let script = scriptPath(plist).map({ expand($0, home: home) }), !fileExists(script) {
            return missing(script, what: "Script", mountedVolumes: mountedVolumes)
        }
        return .ok
    }

    private static func missing(_ path: String, what: String, mountedVolumes: Set<String>) -> LoginItemHealth {
        let parts = path.split(separator: "/")
        if parts.count >= 2, parts[0] == "Volumes", !mountedVolumes.contains(String(parts[1])) {
            return .volumeOffline(String(parts[1]))
        }
        return .broken("\(what) not found at \(path)")
    }
}

/// Who a background item belongs to.
struct LoginItemOwner: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case app, developer, program }

    var name: String
    var kind: Kind
    /// The owning .app bundle, when the program lives inside one (or the item names one).
    var appPath: String?
}

enum LoginItemOwnerResolver {
    /// "/Applications/Foo.app/Contents/Library/LoginItems/Helper.app/Contents/MacOS/x" → "/Applications/Foo.app".
    static func outermostApp(in path: String) -> String? {
        var components: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            components.append(String(part))
            if part.lowercased().hasSuffix(".app"), part.count > 4 {
                return components.joined(separator: "/")
            }
        }
        return nil
    }

    /// The first app bundle path written anywhere in the arguments, e.g. inside a `zsh -c` one-liner.
    /// Paths may contain spaces, so the longest candidate that exists wins; failing that, the one after a quote.
    static func mentionedApp(in arguments: [String], appExists: (String) -> Bool) -> String? {
        for argument in arguments {
            let text = argument as NSString
            var searchStart = 0
            while searchStart < text.length {
                let found = text.range(of: ".app", options: [.caseInsensitive],
                                       range: NSRange(location: searchStart, length: text.length - searchStart))
                guard found.location != NSNotFound else { break }
                let end = found.location + found.length
                searchStart = end
                if end < text.length, let scalar = UnicodeScalar(text.character(at: end)),
                   !CharacterSet(charactersIn: "/'\"; \t\n)").contains(scalar) { continue }
                let candidates = startCandidates(in: text, before: found.location).map {
                    text.substring(with: NSRange(location: $0, length: end - $0))
                }
                if let existing = candidates.first(where: appExists) { return existing }
                if let quoted = candidates.last { return quoted }
            }
        }
        return nil
    }

    /// Indexes of "/" that could start a path: at the beginning or after a quote, space, `=` or `(`. Longest first.
    private static func startCandidates(in text: NSString, before limit: Int) -> [Int] {
        var starts: [Int] = []
        let boundaries = CharacterSet(charactersIn: "'\" \t=(")
        for index in 0..<limit where text.character(at: index) == 0x2F { // "/"
            if index == 0 { starts.append(index); continue }
            if let scalar = UnicodeScalar(text.character(at: index - 1)), boundaries.contains(scalar) { starts.append(index) }
        }
        return starts
    }

    /// "Developer ID Application: Google LLC (EQHXZ8M8AV)" → "Google LLC".
    static func developerName(fromCertificateSummary summary: String) -> String? {
        var name = summary
        if let colon = name.range(of: ": ") { name = String(name[colon.upperBound...]) }
        if let open = name.range(of: " (", options: .backwards), name.hasSuffix(")") { name = String(name[..<open.lowerBound]) }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix("Software Signing") || name.hasPrefix("Apple ") { return "Apple" }
        return name.isEmpty ? nil : name
    }

    /// "com.google.keystone.agent" → "keystone agent"-ish fallback name for items with nothing better.
    static func displayName(forLabel label: String) -> String {
        let parts = label.split(separator: ".")
        guard parts.count >= 3 else { return label }
        return parts.dropFirst(2).joined(separator: " ")
    }

    static func resolve(plist: LoginItemPlist?, label: String, home: String,
                        appExists: (String) -> Bool,
                        appForBundleID: (String) -> String?,
                        appName: (String) -> String,
                        signer: (String) -> String?) -> LoginItemOwner {
        let executable = plist?.executable.map { LoginItemInspector.expand($0, home: home) }
        let subject = plist.flatMap(LoginItemInspector.scriptPath).map { LoginItemInspector.expand($0, home: home) } ?? executable

        // 1. The program lives inside an app bundle.
        for path in [subject, executable].compactMap({ $0 }) {
            if let app = outermostApp(in: path) { return LoginItemOwner(name: appName(app), kind: .app, appPath: app) }
        }
        // 2. The item names an app in its arguments (`open -a`, shell one-liners) or by bundle ID.
        if let plist {
            if let app = mentionedApp(in: plist.arguments, appExists: appExists) {
                return LoginItemOwner(name: appName(app), kind: .app, appPath: app)
            }
            for id in plist.associatedBundleIDs + openBundleIDs(plist.arguments) {
                if let app = appForBundleID(id) { return LoginItemOwner(name: appName(app), kind: .app, appPath: app) }
            }
            if let name = openAppName(plist.arguments) { return LoginItemOwner(name: name, kind: .app, appPath: nil) }
        }
        // 3. Who signed the program.
        if let subject, subject.hasPrefix("/"), let developer = signer(subject), developer != "Apple" {
            return LoginItemOwner(name: developer, kind: .developer, appPath: nil)
        }
        // 4. The program's own name — unless it's just a shell or interpreter, where the label says more.
        let systemTool = ["/bin/", "/usr/bin/", "/usr/sbin/", "/sbin/"].contains { subject?.hasPrefix($0) ?? false }
        if let subject, !systemTool {
            let name = (subject as NSString).lastPathComponent
            let ext = (name as NSString).pathExtension.lowercased()
            let base = scriptExtensions.contains(ext) ? (name as NSString).deletingPathExtension : name
            if !LoginItemInspector.interpreters.contains(base), base != "env", !base.isEmpty {
                return LoginItemOwner(name: base, kind: .program, appPath: nil)
            }
        }
        return LoginItemOwner(name: displayName(forLabel: label), kind: .program, appPath: nil)
    }

    private static let scriptExtensions: Set<String> = ["sh", "zsh", "bash", "py", "js", "mjs", "ts", "rb", "pl", "command", "scpt"]

    /// `open -b com.vendor.app` → ["com.vendor.app"].
    static func openBundleIDs(_ arguments: [String]) -> [String] {
        guard let first = arguments.first, (first as NSString).lastPathComponent == "open" else { return [] }
        return zip(arguments, arguments.dropFirst()).compactMap { $0 == "-b" ? $1 : nil }
    }

    /// `open -a "Some App"` → "Some App".
    static func openAppName(_ arguments: [String]) -> String? {
        guard let first = arguments.first, (first as NSString).lastPathComponent == "open" else { return nil }
        return zip(arguments, arguments.dropFirst()).first { $0.0 == "-a" }.map { ($0.1 as NSString).lastPathComponent }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
    }
}
