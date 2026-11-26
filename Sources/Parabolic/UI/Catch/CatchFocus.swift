import AppKit

/// Whether a new popup takes the keyboard (Return = Download, Esc = Cancel at once).
/// Only from a web browser the user just clicked a download in, or from Root itself: typing in Telegram or an
/// editor must never land in the popup (a Return there would start the download).
enum CatchFocus {
    static func takesKeyboard(frontmost: String?, isSelf: Bool, browsers: Set<String>) -> Bool {
        if isSelf { return true }
        guard let frontmost else { return false }
        return browsers.contains(frontmost)
    }

    /// Web browsers by bundle ID. Not "every app that opens https links": terminals (kitty), chat apps and other
    /// download managers register for https too, and the popup once took a Return typed in the terminal.
    static let knownBrowsers: Set<String> = [
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "org.chromium.Thorium", "com.kagi.kagimacOS",
        "app.zen-browser.zen", "com.duckduckgo.macos.browser", "net.imput.helium",
    ]

    /// The known browsers plus whatever the system default browser is.
    @MainActor static var installedBrowsers: Set<String> {
        guard let probe = URL(string: "https://example.com"),
              let url = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let id = Bundle(url: url)?.bundleIdentifier else { return knownBrowsers }
        return knownBrowsers.union([id])
    }

    @MainActor static func takesKeyboardNow() -> Bool {
        let front = NSWorkspace.shared.frontmostApplication
        return takesKeyboard(frontmost: front?.bundleIdentifier,
                             isSelf: front?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                             browsers: installedBrowsers)
    }
}
