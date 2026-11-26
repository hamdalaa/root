import Foundation
import Testing
@testable import Parabolic

/// The popup's «More details»: ETA, free space, connections, media pages.
@Suite struct CatchDetailsTests {
    @Test func etaFromTheLastSpeedTest() {
        // 100 MB at 80 Mbps (10 MB/s) = 10 s.
        #expect(CatchDetails.eta(bytes: 100_000_000, mbps: 80) == 10)
        #expect(CatchDetails.eta(bytes: 1, mbps: 80) == 1, "never shows 0 s")
        #expect(CatchDetails.eta(bytes: nil, mbps: 80) == nil, "unknown size: no guess")
        #expect(CatchDetails.eta(bytes: 100, mbps: nil) == nil, "no speed test yet: no guess")
        #expect(CatchDetails.eta(bytes: 100, mbps: 0) == nil)
    }

    @Test func freeSpaceWarnings() {
        let gb: Int64 = 1_000_000_000
        #expect(CatchDetails.space(free: 50 * gb, needed: 1 * gb) == .plenty)
        #expect(CatchDetails.space(free: 3 * gb, needed: 2 * gb) == .low, "under 2 GB left after the download")
        #expect(CatchDetails.space(free: 1 * gb, needed: 2 * gb) == .notEnough)
        #expect(CatchDetails.space(free: 1 * gb, needed: nil) == .low, "unknown size: judge the free space alone")
        #expect(CatchDetails.space(free: nil, needed: 1) == .unknown)
    }

    @Test func freeSpaceOfARealFolder() throws {
        #expect((CatchDetails.freeSpace(at: NSTemporaryDirectory()) ?? 0) > 0)
        #expect(CatchDetails.freeSpace(at: "/nonexistent-\(UUID().uuidString)/sub") != nil,
                "a folder that doesn't exist yet is judged by its nearest existing parent")
    }

    @Test func connections() {
        var prefs = Preferences()
        prefs.directConnections = 8
        #expect(CatchDetails.connections(prefs: prefs, resumable: true) == 8)
        #expect(CatchDetails.connections(prefs: prefs, resumable: nil) == 8)
        #expect(CatchDetails.connections(prefs: prefs, resumable: false) == 1, "no ranges: one connection")
        prefs.turboMode = true
        #expect(CatchDetails.connections(prefs: prefs, resumable: true) == 16)
    }

    @Test func mediaPagesGetQualityChoices() {
        #expect(CatchFlow.isMediaPage("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        #expect(!CatchFlow.isMediaPage("https://x.com/files/app.zip"))
        #expect(!CatchFlow.isMediaPage("magnet:?xt=urn:btih:abc"))
    }

    @MainActor
    @Test func mediaPageRequestCarriesThePreset() {
        let page = BrowserItem(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        let model = CatchModel(source: page, folder: "/d")
        #expect(model.isMediaPage)
        #expect(model.fileType == "", "no «don't ask» box for pages")
        let preset = DownloadPreset.builtIn[2]
        model.preset = preset
        #expect(model.request(paused: false).preset == preset)
    }

    @MainActor
    @Test func startPausedIsRemembered() {
        var prefs = Preferences()
        let model = CatchModel(source: BrowserItem(url: "https://x.com/a.zip"), folder: "/d")
        model.startPaused = true
        #expect(model.request(paused: model.startPaused).startPaused)
        model.remember(in: &prefs)
        #expect(prefs.catchStartPaused)
    }
}
