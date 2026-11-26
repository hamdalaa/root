import AppKit
import UniformTypeIdentifiers

/// "Root = default download manager": Root opens magnet links and .torrent files, and catches browser
/// downloads through its extension.
///
/// http(s) links are deliberately not claimed: the default handler for http(s) is the default *web browser*,
/// so web downloads are taken over by the browser extension instead (Settings → Browser).
@MainActor
enum DefaultDownloadManager {
    static let magnetScheme = "magnet"
    /// Declared in Info.plist (UTImportedTypeDeclarations) so .torrent files have a real type to own.
    static let torrentTypeIdentifier = "org.bittorrent.torrent"

    static var torrentType: UTType {
        UTType(torrentTypeIdentifier) ?? UTType(filenameExtension: "torrent") ?? .data
    }

    private static var ownBundle: URL { Bundle.main.bundleURL }

    /// App that opens magnet links now.
    static var magnetHandler: URL? {
        URL(string: "magnet:?xt=urn:btih:0").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    static var torrentHandler: URL? { NSWorkspace.shared.urlForApplication(toOpen: torrentType) }

    static func isRoot(_ app: URL?) -> Bool {
        guard let app else { return false }
        return app.standardizedFileURL == ownBundle.standardizedFileURL
            || Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static var ownsMagnetLinks: Bool { isRoot(magnetHandler) }
    static var ownsTorrentFiles: Bool { isRoot(torrentHandler) }
    static var isDefault: Bool { ownsMagnetLinks && ownsTorrentFiles }

    /// Display name of an app bundle ("Free Download Manager").
    static func name(of app: URL?) -> String? {
        guard let app else { return nil }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Makes Root the handler for magnet links and .torrent files. Only from a real app bundle
    /// (a debug binary in .build has no Info.plist entries to register).
    static func claim() async -> String? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return "Run Root from its app bundle to make it the default." }
        var problems: [String] = []
        if !ownsMagnetLinks {
            do { try await NSWorkspace.shared.setDefaultApplication(at: ownBundle, toOpenURLsWithScheme: magnetScheme) }
            catch { problems.append("magnet links: \(error.localizedDescription)") }
        }
        if !ownsTorrentFiles {
            do { try await NSWorkspace.shared.setDefaultApplication(at: ownBundle, toOpen: torrentType) }
            catch { problems.append(".torrent files: \(error.localizedDescription)") }
        }
        return problems.isEmpty ? nil : "Couldn’t take over " + problems.joined(separator: "; ")
    }
}
