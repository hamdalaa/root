import CoreGraphics
import Foundation
import Testing
@testable import Parabolic

/// The FDM-style popup: catch → popup (or straight to the queue) → enqueue request.
@Suite struct CatchFlowTests {
    private func item(_ url: String, filename: String? = nil, size: Int64? = nil) -> BrowserItem {
        var item = BrowserItem(url: url)
        item.filename = filename
        item.size = size
        return item
    }

    @Test func fileTypeComesFromTheNameThenTheLink() {
        #expect(CatchFlow.fileType(of: item("https://x.com/get?id=1", filename: "Setup.DMG")) == "dmg")
        #expect(CatchFlow.fileType(of: item("https://x.com/files/app.apk")) == "apk")
        #expect(CatchFlow.fileType(of: item("magnet:?xt=urn:btih:abc")) == "torrent")
        #expect(CatchFlow.fileType(of: item("https://x.com/download")) == "")
    }

    @Test func routeShowsThePopupUnlessTurnedOffOrSkipped() {
        var prefs = Preferences()
        let zip = item("https://x.com/a.zip")
        #expect(CatchFlow.route(zip, prefs: prefs) == .popup)

        prefs.catchSkipTypes = ["zip"]
        #expect(CatchFlow.route(zip, prefs: prefs) == .enqueue, "«Don't ask for ZIP files» was ticked before")
        #expect(CatchFlow.route(item("https://x.com/b.pdf"), prefs: prefs) == .popup)
        #expect(CatchFlow.route(item("https://x.com/download"), prefs: prefs) == .popup, "no type: always ask")

        prefs.catchSkipTypes = []
        prefs.browserShowCatchWindow = false
        #expect(CatchFlow.route(zip, prefs: prefs) == .enqueue, "the setting turns the popup off")
    }

    @Test func startFolderIsTheLastOneUsedWhileItExists() {
        var prefs = Preferences()
        prefs.downloadFolder = "/Users/x/Downloads"
        #expect(CatchFlow.startFolder(prefs: prefs) { _ in true } == "/Users/x/Downloads")
        prefs.catchLastFolder = "/Volumes/Big/Apps"
        #expect(CatchFlow.startFolder(prefs: prefs) { _ in true } == "/Volumes/Big/Apps")
        #expect(CatchFlow.startFolder(prefs: prefs) { $0 != "/Volumes/Big/Apps" } == "/Users/x/Downloads",
                "an unplugged drive falls back to the download folder")
    }

    @Test func rememberKeepsTheFolderAndTheTypeChoice() {
        var prefs = Preferences()
        CatchFlow.remember(folder: "/Volumes/Big/Apps", skipType: "zip", in: &prefs)
        #expect(prefs.catchLastFolder == "/Volumes/Big/Apps")
        #expect(prefs.catchSkipTypes == ["zip"])
        CatchFlow.remember(folder: "/Volumes/Big/Apps", skipType: "zip", in: &prefs)
        #expect(prefs.catchSkipTypes == ["zip"], "no duplicates")
        CatchFlow.remember(folder: "/tmp", skipType: nil, in: &prefs)
        #expect(prefs.catchSkipTypes == ["zip"])
        #expect(prefs.catchLastFolder == "/tmp")
    }

    /// The whole flow without AppKit: popup model → «Download» → enqueue request → next ZIP skips the popup.
    @MainActor
    @Test func catchPopupEnqueueFlow() {
        var prefs = Preferences()
        prefs.downloadFolder = "/Users/x/Downloads"
        let caught = item("https://x.com/a.zip", filename: "a.zip", size: 2_048)
        #expect(CatchFlow.route(caught, prefs: prefs) == .popup)

        let model = CatchModel(source: caught, folder: CatchFlow.startFolder(prefs: prefs) { _ in true })
        #expect(model.fileType == "zip")
        #expect(model.category == .archives, "category picked from the file type")
        model.filename = "renamed.zip"
        model.folder = "/Volumes/Big"
        model.skipThisType = true

        let request = model.request(paused: false)
        #expect(request == CatchRequest(url: "https://x.com/a.zip", filename: "renamed.zip", headers: nil,
                                        folder: "/Volumes/Big", size: 2_048, startPaused: false))
        model.remember(in: &prefs)
        #expect(prefs.catchLastFolder == "/Volumes/Big")
        #expect(CatchFlow.route(item("https://y.com/other.zip"), prefs: prefs) == .enqueue)
        #expect(CatchFlow.startFolder(prefs: prefs) { _ in true } == "/Volumes/Big")
        #expect(model.request(paused: true).startPaused, "«Download Later» queues it stopped")
    }

    @MainActor
    @Test func untickedTypeChoiceIsNotRemembered() {
        var prefs = Preferences()
        let model = CatchModel(source: item("https://x.com/a.zip"), folder: "/d")
        model.remember(in: &prefs)
        #expect(prefs.catchSkipTypes.isEmpty)
    }
}

/// Popups stack under each other in the top-right corner, like notifications.
@Suite struct CatchPanelLayoutTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 460, height: 200)

    @Test func firstPanelSitsTopRight() {
        let origin = CatchPanelLayout.origin(for: size, occupied: [], in: screen)
        #expect(origin == CGPoint(x: 1440 - 16 - 460, y: 875 - 16 - 200))
    }

    @Test func nextPanelGoesBelow() {
        let first = CGRect(origin: CatchPanelLayout.origin(for: size, occupied: [], in: screen), size: size)
        let second = CatchPanelLayout.origin(for: size, occupied: [first], in: screen)
        #expect(second.x == first.minX)
        #expect(second.y == first.minY - 10 - 200)
    }

    @Test func fullColumnStartsANewOneToTheLeft() {
        var occupied: [CGRect] = []
        for _ in 0..<5 { occupied.append(CGRect(origin: CatchPanelLayout.origin(for: size, occupied: occupied, in: screen), size: size)) }
        // 875 tall fits 4 × 200 + 3 × 10 between the 16-point margins; the 5th starts a second column.
        #expect(occupied[3].minX == occupied[0].minX)
        #expect(occupied[4].minX == occupied[0].minX - 10 - 460)
        #expect(occupied[4].maxY == screen.maxY - CatchPanelLayout.margin)
        #expect(occupied.allSatisfy { screen.contains($0) })
    }

    @Test func aClosedSlotIsReused() {
        let first = CGRect(origin: CatchPanelLayout.origin(for: size, occupied: [], in: screen), size: size)
        let second = CGRect(origin: CatchPanelLayout.origin(for: size, occupied: [first], in: screen), size: size)
        // The top one closed: the next popup takes the top slot again.
        #expect(CatchPanelLayout.origin(for: size, occupied: [second], in: screen) == first.origin)
    }
}

/// The popup takes the keyboard (Return = Download, Esc = Cancel) only from a browser the user just clicked
/// a download in. Typing in Telegram or an editor must never land in it.
@Suite struct CatchFocusTests {
    private let browsers: Set<String> = ["com.brave.Browser", "com.apple.Safari"]

    @Test func takesTheKeyboardFromABrowserOrRoot() {
        #expect(CatchFocus.takesKeyboard(frontmost: "com.brave.Browser", isSelf: false, browsers: browsers))
        #expect(CatchFocus.takesKeyboard(frontmost: "com.hamad.parabolic", isSelf: true, browsers: browsers))
    }

    @Test func neverFromOtherApps() {
        #expect(!CatchFocus.takesKeyboard(frontmost: "ru.keepcoder.Telegram", isSelf: false, browsers: browsers))
        #expect(!CatchFocus.takesKeyboard(frontmost: nil, isSelf: false, browsers: browsers))
    }
}

/// Apps that only *open* https links don't count as browsers: kitty registers for https, and the popup took
/// a Return the owner typed in the terminal (2026-11-18).
@Suite struct CatchBrowserListTests {
    @Test func onlyRealBrowsers() {
        for browser in ["com.brave.Browser", "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox"] {
            #expect(CatchFocus.knownBrowsers.contains(browser), "\(browser)")
        }
        for app in ["net.kovidgoyal.kitty", "com.openai.codex", "org.freedownloadmanager.fdm6", "ru.keepcoder.Telegram"] {
            #expect(!CatchFocus.knownBrowsers.contains(app), "\(app)")
        }
    }
}
