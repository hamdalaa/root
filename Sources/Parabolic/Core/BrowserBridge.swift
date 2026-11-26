import Foundation

/// One link handed over by the browser extension (via the native host's inbox file).
struct BrowserItem: Codable, Sendable {
    var url: String
    var pageURL: String?
    var referrer: String?
    var cookies: String?
    var userAgent: String?
    var filename: String?
    var title: String?
    /// Size and MIME type the browser already knew (caught downloads).
    var size: Int64?
    var mime: String?

    var headers: [String: String]? {
        var h: [String: String] = [:]
        if let cookies, !cookies.isEmpty { h["Cookie"] = cookies }
        if let referrer, !referrer.isEmpty { h["Referer"] = referrer }
        if let userAgent, !userAgent.isEmpty { h["User-Agent"] = userAgent }
        return h.isEmpty ? nil : h
    }
}

/// A request from the extension. `quick` downloads immediately, `add` opens the options sheet,
/// `batch` opens the batch sheet with every link.
struct BrowserRequest: Codable, Sendable {
    var action: String
    var items: [BrowserItem]
    var preset: String?
}

/// Native-messaging plumbing: the inbox the host drops requests into, and host-manifest
/// installation for every Chromium browser + Firefox.
enum BrowserBridge {
    static let hostName = "com.hamad.parabolic.host"
    static let chromeExtensionID = "nijlimkbdkelhlhcaodjeiccbpbcneca"
    static let firefoxExtensionID = "parabolic@hamad.dev"

    static var inboxDirectory: URL { ToolStore.supportDirectory.appendingPathComponent("inbox", isDirectory: true) }

    /// Reads and deletes an inbox request. IDs are UUIDs only, so this can't be pointed at other files.
    static func takeRequest(id: String) -> BrowserRequest? {
        guard UUID(uuidString: id) != nil else { return nil }
        let file = inboxDirectory.appendingPathComponent("\(id).json")
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(BrowserRequest.self, from: data)
    }

    /// Inbox files hold cookies; anything not picked up within 5 minutes is deleted.
    static func pruneInbox() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: inboxDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-300)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: file) }
        }
    }

    struct Browser: Identifiable, Hashable, Sendable {
        var id: String { name }
        let name: String
        /// Folder whose existence means the browser is installed (profile root).
        let profileRoot: String
        let isFirefox: Bool

        var hostsDirectory: String { (profileRoot as NSString).appendingPathComponent("NativeMessagingHosts") }
        var manifestPath: String { (hostsDirectory as NSString).appendingPathComponent("\(BrowserBridge.hostName).json") }
        var isInstalled: Bool { FileManager.default.fileExists(atPath: profileRoot) }
        var isConnected: Bool { FileManager.default.fileExists(atPath: manifestPath) }
    }

    static let browsers: [Browser] = {
        let base = NSHomeDirectory() + "/Library/Application Support/"
        return [
            Browser(name: "Google Chrome", profileRoot: base + "Google/Chrome", isFirefox: false),
            Browser(name: "Brave", profileRoot: base + "BraveSoftware/Brave-Browser", isFirefox: false),
            Browser(name: "Microsoft Edge", profileRoot: base + "Microsoft Edge", isFirefox: false),
            Browser(name: "Arc", profileRoot: base + "Arc/User Data", isFirefox: false),
            Browser(name: "Vivaldi", profileRoot: base + "Vivaldi", isFirefox: false),
            Browser(name: "Chromium", profileRoot: base + "Chromium", isFirefox: false),
            Browser(name: "Opera", profileRoot: base + "com.operasoftware.Opera", isFirefox: false),
            Browser(name: "Firefox", profileRoot: base + "Mozilla", isFirefox: true),
        ]
    }()

    /// The host binary inside the app bundle.
    static var hostExecutablePath: String? {
        Bundle.main.url(forAuxiliaryExecutable: "ParabolicHost")?.path
    }

    /// Writes the native-messaging manifest for every installed browser. Returns the browsers connected.
    @discardableResult
    static func installHosts() -> [String] {
        guard let host = hostExecutablePath else { return [] }
        var connected: [String] = []
        for browser in browsers where browser.isInstalled {
            var manifest: [String: Any] = [
                "name": hostName,
                "description": "Root download manager",
                "path": host,
                "type": "stdio",
            ]
            if browser.isFirefox {
                manifest["allowed_extensions"] = [firefoxExtensionID]
            } else {
                manifest["allowed_origins"] = ["chrome-extension://\(chromeExtensionID)/"]
            }
            do {
                try FileManager.default.createDirectory(atPath: browser.hostsDirectory, withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: browser.manifestPath), options: .atomic)
                connected.append(browser.name)
            } catch {
                continue
            }
        }
        return connected
    }

    static func uninstallHosts() {
        for browser in browsers { try? FileManager.default.removeItem(atPath: browser.manifestPath) }
    }

    /// Unpacked extension folders shipped inside the app (load via chrome://extensions → Load unpacked).
    static var extensionFolder: URL? { Bundle.main.url(forResource: "Extension", withExtension: nil) }
}
