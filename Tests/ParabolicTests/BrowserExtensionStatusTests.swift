import Foundation
import Testing
@testable import Parabolic

private func prefs(_ settings: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["extensions": ["settings": settings]])
}

@Suite struct BrowserExtensionStatusTests {
    private let root = BrowserBridge.chromeExtensionID
    private let fdm = "ahmpjcflkgiildlgicmcieglgoilbfdp"

    @Test func emptyEntryMeansRemoved() {
        // What Brave keeps after an unpacked extension's folder disappeared.
        let state = BrowserExtensionReader.state(of: root, preferences: [prefs([root: [String: Any]()])])
        #expect(state == .notInstalled)
    }

    @Test func missingEntryMeansNotInstalled() {
        #expect(BrowserExtensionReader.state(of: root, preferences: [prefs([:])]) == .notInstalled)
        #expect(BrowserExtensionReader.state(of: root, preferences: [Data("not json".utf8)]) == .notInstalled)
    }

    @Test func storeExtensionWithNoDisableReasonsIsEnabled() {
        let data = prefs([fdm: ["location": 1, "path": "\(fdm)/3.3.13_0", "disable_reasons": [Int](),
                                "manifest": ["name": "Free Download Manager"]]])
        #expect(BrowserExtensionReader.state(of: fdm, preferences: [data]) == .enabled)
    }

    @Test func disableReasonsMeanTurnedOff() {
        let list = prefs([fdm: ["location": 1, "path": "x", "disable_reasons": [1]]])
        let bitmask = prefs([fdm: ["location": 1, "path": "x", "disable_reasons": 1]])
        let oldState = prefs([fdm: ["location": 1, "path": "x", "state": 0]])
        #expect(BrowserExtensionReader.state(of: fdm, preferences: [list]) == .disabled)
        #expect(BrowserExtensionReader.state(of: fdm, preferences: [bitmask]) == .disabled)
        #expect(BrowserExtensionReader.state(of: fdm, preferences: [oldState]) == .disabled)
    }

    @Test func entriesSplitAcrossSecureAndRegularPreferencesAreMerged() {
        let secure = prefs([root: ["location": 4, "path": "/Users/x/Library/Application Support/Parabolic/Extension/chromium"]])
        let regular = prefs([root: ["disable_reasons": [1]]])
        #expect(BrowserExtensionReader.state(of: root, preferences: [secure, regular]) == .disabled)
        #expect(BrowserExtensionReader.state(of: root, preferences: [secure]) == .enabled)
    }

    @Test func unpackedPathIsReported() {
        let secure = prefs([root: ["location": 4, "path": "/tmp/Root.app/Contents/Resources/Extension/chromium"]])
        #expect(BrowserExtensionReader.unpackedPath(of: root, preferences: [secure])
                == "/tmp/Root.app/Contents/Resources/Extension/chromium")
    }

    @Test func bestStateAcrossProfilesWins() {
        #expect(BrowserExtensionState.best([.notInstalled, .disabled]) == .disabled)
        #expect(BrowserExtensionState.best([.disabled, .enabled, .notInstalled]) == .enabled)
        #expect(BrowserExtensionState.best([]) == .notInstalled)
    }

    @Test func profilesAreDefaultAndNumberedOnes() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        for name in ["Default", "Profile 2", "System Profile", "Crashpad", "Guest Profile"] {
            try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: base.appendingPathComponent(name).appendingPathComponent("Preferences"))
        }
        let names = BrowserExtensionReader.profiles(in: base.path).map { ($0 as NSString).lastPathComponent }.sorted()
        #expect(names == ["Default", "Profile 2"])
    }
}

@Suite struct ExtensionInstallerTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ path: String, in dir: URL) throws {
        let file = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    @Test func mirrorsInPlaceAndOnlyRewritesChanges() throws {
        let source = try tempDir(), destination = try tempDir().appendingPathComponent("chromium")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: destination) }
        try write("{\"v\":1}", "manifest.json", in: source)
        try write("a", "background.js", in: source)
        try write("png", "icons/icon-16.png", in: source)

        #expect(try ExtensionInstaller.sync(from: source, to: destination) == 3)
        let inode = try FileManager.default.attributesOfItem(atPath: destination.path)[.systemFileNumber] as? Int
        #expect(try ExtensionInstaller.sync(from: source, to: destination) == 0, "unchanged: nothing rewritten")

        try write("b", "background.js", in: source)
        try FileManager.default.removeItem(at: source.appendingPathComponent("icons/icon-16.png"))
        #expect(try ExtensionInstaller.sync(from: source, to: destination) == 2, "one changed, one removed")
        #expect(try String(contentsOf: destination.appendingPathComponent("background.js"), encoding: .utf8) == "b")
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("icons/icon-16.png").path))
        let after = try FileManager.default.attributesOfItem(atPath: destination.path)[.systemFileNumber] as? Int
        #expect(inode == after, "the folder the browser loads from is never replaced")
    }

    @Test func missingSourceThrows() {
        let nowhere = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { try ExtensionInstaller.sync(from: nowhere, to: nowhere) }
    }
}
