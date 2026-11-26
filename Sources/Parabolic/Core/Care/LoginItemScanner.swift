import AppKit
import Foundation
import Security

/// Where a background item is installed.
enum LoginItemScope: String, Sendable, CaseIterable {
    case user, systemAgent, systemDaemon

    var title: String {
        switch self {
        case .user: "Your background items"
        case .systemAgent: "Background items for all users"
        case .systemDaemon: "System services"
        }
    }

    var folderPath: String {
        switch self {
        case .user: "~/Library/LaunchAgents"
        case .systemAgent: "/Library/LaunchAgents"
        case .systemDaemon: "/Library/LaunchDaemons"
        }
    }

    /// Only your own LaunchAgents are changed from here; the rest need an administrator.
    var isManageable: Bool { self == .user }

    func folder(home: URL) -> URL {
        switch self {
        case .user: home.appendingPathComponent("Library/LaunchAgents")
        case .systemAgent: URL(fileURLWithPath: "/Library/LaunchAgents")
        case .systemDaemon: URL(fileURLWithPath: "/Library/LaunchDaemons")
        }
    }

    func serviceTarget(label: String) -> String {
        self == .systemDaemon ? "system/\(label)" : "\(LoginItemLaunchctl.userDomain)/\(label)"
    }
}

/// One launchd background item.
struct LoginItemEntry: Identifiable, Sendable, Equatable {
    var id: String { plistURL.path }
    let plistURL: URL
    let isSymlink: Bool
    let scope: LoginItemScope
    let plist: LoginItemPlist?
    let label: String
    let owner: LoginItemOwner
    let health: LoginItemHealth
    /// The program, or the script an interpreter runs, with `~` expanded.
    let subjectPath: String?
    var status: LoginItemStatus = .unknown
    var lastExitCode: String?

    var startsAtLogin: Bool { plist?.startsAtLogin ?? false }
    var isOff: Bool { status == .disabled }
    /// Counted in "runs at login": starts by itself and isn't turned off.
    var countsAsAutomatic: Bool { startsAtLogin && !isOff && !health.isBroken }
}

/// Reads LaunchAgents / LaunchDaemons folders. File reading is synchronous and runs off the main actor.
enum LoginItemScanner {
    static func mountedVolumes() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [])
    }

    /// Every .plist in one folder, parsed and checked. Status is filled in separately.
    static func readEntries(scope: LoginItemScope, folder: URL, home: String,
                            mounted: Set<String>, fileManager: FileManager = .default) -> [LoginItemEntry] {
        // Name-based listing keeps dangling symlinks (they show up as broken items).
        let files = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .map { folder.appendingPathComponent($0) }
        var signerCache: [String: String?] = [:]
        return files
            .filter { $0.pathExtension.lowercased() == "plist" }
            .map { url in
                let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                var plist: LoginItemPlist?
                var parseError: String?
                if let data = fileManager.contents(atPath: url.path) {
                    do { plist = try LoginItemPlist.parse(data: data) } catch { parseError = error.localizedDescription }
                } else {
                    parseError = isLink ? "The file it links to is missing." : "The file can’t be read."
                }
                let label = plist?.label ?? url.deletingPathExtension().lastPathComponent
                let health = LoginItemInspector.evaluate(plist: plist, parseError: parseError, home: home,
                                                         fileExists: { fileManager.fileExists(atPath: $0) },
                                                         mountedVolumes: mounted)
                let owner = LoginItemOwnerResolver.resolve(
                    plist: plist, label: label, home: home,
                    appExists: { fileManager.fileExists(atPath: $0) },
                    appForBundleID: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path },
                    appName: { fileManager.displayName(atPath: $0).replacingOccurrences(of: ".app", with: "") },
                    signer: { path in
                        if let cached = signerCache[path] { return cached }
                        let value = LoginItemSigner.developer(atPath: path)
                        signerCache[path] = value
                        return value
                    })
                let subject = (plist.flatMap(LoginItemInspector.scriptPath) ?? plist?.executable)
                    .map { LoginItemInspector.expand($0, home: home) }
                return LoginItemEntry(plistURL: url, isSymlink: isLink, scope: scope, plist: plist, label: label,
                                      owner: owner, health: health, subjectPath: subject)
            }
            .sorted { $0.owner.name.localizedStandardCompare($1.owner.name) == .orderedAscending }
    }

    /// All three folders.
    static func readAll(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [LoginItemEntry] {
        let mounted = mountedVolumes()
        return LoginItemScope.allCases.flatMap {
            readEntries(scope: $0, folder: $0.folder(home: home), home: home.path, mounted: mounted)
        }
    }

    /// Which labels launchd has turned off, for the user and system domains (two read-only calls, in parallel).
    struct DisabledMaps: Sendable {
        var user: [String: Bool] = [:]
        var system: [String: Bool] = [:]

        func isDisabled(_ entry: LoginItemEntry) -> Bool {
            let map = entry.scope == .systemDaemon ? system : user
            return map[entry.label] ?? (entry.plist?.isDisabledInFile ?? false)
        }
    }

    static func disabledMaps() async -> DisabledMaps {
        async let user = LoginItemLaunchctl.run(["print-disabled", LoginItemLaunchctl.userDomain])
        async let system = LoginItemLaunchctl.run(["print-disabled", "system"])
        return DisabledMaps(user: LoginItemLaunchctl.parseDisabled(await user.text),
                            system: LoginItemLaunchctl.parseDisabled(await system.text))
    }

    /// Live status of one entry from a read-only `launchctl print`.
    static func status(of entry: LoginItemEntry, disabled: DisabledMaps) async -> (LoginItemStatus, String?) {
        let output = await LoginItemLaunchctl.run(["print", entry.scope.serviceTarget(label: entry.label)])
        let queried = output.status == 0 || output.text.contains("Could not find service")
        let info = LoginItemLaunchctl.parsePrint(output.text)
        return (LoginItemStatus.derive(info: info, isDisabled: disabled.isDisabled(entry), queried: queried), info?.lastExitCode)
    }

    /// Reads the three folders on a GCD queue so the caller's actor is never blocked.
    static func readAllOffMain() async -> [LoginItemEntry] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: readAll()) }
        }
    }
}


/// Developer name from a program's code signature, read in-process (no `codesign` subprocess).
enum LoginItemSigner {
    private static func signingInfo(_ path: String) -> [String: Any]? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return info as? [String: Any]
    }

    /// The 10-character Apple developer team, e.g. "EQHXZ8M8AV".
    static func teamIdentifier(atPath path: String) -> String? {
        signingInfo(path)?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func developer(atPath path: String) -> String? {
        guard let dict = signingInfo(path),
              let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first,
              let summary = SecCertificateCopySubjectSummary(leaf) as String? else { return nil }
        return LoginItemOwnerResolver.developerName(fromCertificateSummary: summary)
    }
}
