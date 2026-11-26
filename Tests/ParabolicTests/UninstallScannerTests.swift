import Foundation
import Testing
@testable import Parabolic

/// Temp directory helper for Uninstaller tests; removed on deinit.
final class UninstallTempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uninstall-tests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func makeApp(_ relative: String, bundleID: String? = nil, name: String? = nil) throws -> URL {
        let app = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleShortVersionString": "1.2"]
        if let bundleID { info["CFBundleIdentifier"] = bundleID }
        if let name { info["CFBundleName"] = name }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    @discardableResult
    func makeFile(_ relative: String, bytes: Int = 10) throws -> URL {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: file)
        return file
    }

    @discardableResult
    func makeDir(_ relative: String) throws -> URL {
        let dir = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

@Suite("Uninstaller app discovery")
struct UninstallScannerTests {
    @Test("Volume comes from /Volumes/<name>")
    func volumeFromPath() {
        #expect(UninstallVolume.from(path: "/Applications/Foo.app") == .startup)
        #expect(UninstallVolume.from(path: "/Volumes/External/Applications/Foo.app") == .external("External"))
        #expect(UninstallVolume.from(path: "/Volumes/Macintosh HD/Applications/Foo.app") == .startup)
        #expect(UninstallVolume.external("External").title == "External")
        #expect(UninstallVolume.startup.title == "Internal")
    }

    @Test("Finds apps at the top level and one folder down, and ignores other files")
    func discoversNested() throws {
        let temp = try UninstallTempDir()
        try temp.makeApp("Apps/Top.app", bundleID: "com.example.top")
        try temp.makeApp("Apps/Suite 2026/Suite 2026.app", bundleID: "com.example.suite")
        try temp.makeApp("Apps/A/B/TooDeep.app")
        try temp.makeFile("Apps/readme.txt")
        let bundles = UninstallAppScanner.discoverBundles(roots: [temp.url.appendingPathComponent("Apps")])
        let names = Set(bundles.map(\.url.lastPathComponent))
        #expect(names == ["Top.app", "Suite 2026.app"])
    }

    @Test("Symlinked apps are deduplicated by real path and kept as aliases")
    func dedupesSymlinks() throws {
        let temp = try UninstallTempDir()
        let real = try temp.makeApp("External/Applications/Big.app", bundleID: "com.example.big")
        try temp.makeDir("Apps")
        let link = temp.url.appendingPathComponent("Apps/Big.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let bundles = UninstallAppScanner.discoverBundles(roots: [temp.url.appendingPathComponent("Apps"),
                                                                  temp.url.appendingPathComponent("External/Applications")])
        #expect(bundles.count == 1)
        #expect(bundles.first?.url.path == real.path)
        #expect(bundles.first?.aliases.map(\.lastPathComponent) == ["Big.app"])
    }

    @Test("The same root reached twice is scanned once")
    func dedupesRoots() throws {
        let temp = try UninstallTempDir()
        try temp.makeApp("Apps/One.app")
        let alias = temp.url.appendingPathComponent("AppsLink")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: temp.url.appendingPathComponent("Apps"))
        let bundles = UninstallAppScanner.discoverBundles(roots: [temp.url.appendingPathComponent("Apps"), alias])
        #expect(bundles.count == 1)
    }

    @Test("Apple apps, /System and Root are excluded")
    func exclusions() throws {
        #expect(UninstallAppScanner.isExcluded(bundleID: "com.apple.Safari", path: "/Applications/Safari.app"))
        #expect(UninstallAppScanner.isExcluded(bundleID: "com.hamad.parabolic", path: "/Applications/Root.app"))
        #expect(UninstallAppScanner.isExcluded(bundleID: nil, path: "/System/Applications/Notes.app"))
        #expect(!UninstallAppScanner.isExcluded(bundleID: "com.hnc.Discord", path: "/Applications/Discord.app"))

        let temp = try UninstallTempDir()
        let apple = try temp.makeApp("Apps/Pages.app", bundleID: "com.apple.iWork.Pages")
        let mine = try temp.makeApp("Apps/Tool.app", bundleID: "com.example.tool", name: "Tool")
        #expect(UninstallAppScanner.loadApp(.init(url: apple, aliases: [])) == nil)
        let loaded = try #require(UninstallAppScanner.loadApp(.init(url: mine, aliases: [])))
        #expect(loaded.bundleID == "com.example.tool")
        #expect(loaded.version == "1.2")
        #expect(!loaded.isAppStore)
        #expect(!loaded.needsAdmin)
    }

    @Test("App Store receipt is detected")
    func appStore() throws {
        let temp = try UninstallTempDir()
        let app = try temp.makeApp("Apps/Store.app", bundleID: "com.example.store")
        try temp.makeFile("Apps/Store.app/Contents/_MASReceipt/receipt")
        #expect(UninstallAppScanner.loadApp(.init(url: app, aliases: []))?.isAppStore == true)
    }

    @Test("The longer of Finder name and display name wins")
    func preferredName() {
        #expect(UninstallAppScanner.preferredName(fileName: "Visual Studio Code", displayName: "Code") == "Visual Studio Code")
        #expect(UninstallAppScanner.preferredName(fileName: "VSC", displayName: "Visual Studio Code") == "Visual Studio Code")
        #expect(UninstallAppScanner.preferredName(fileName: "Foo", displayName: nil) == "Foo")
    }

    @Test("Sizer counts files and never follows symlinks")
    func sizer() throws {
        let temp = try UninstallTempDir()
        try temp.makeFile("Data/a.bin", bytes: 50_000)
        try temp.makeFile("Big/huge.bin", bytes: 400_000)
        try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("Data/link"),
                                                   withDestinationURL: temp.url.appendingPathComponent("Big"))
        let measured = UninstallSizer.measure(temp.url.appendingPathComponent("Data"))
        let bytes = try #require(measured.bytes)
        #expect(bytes >= 50_000)
        #expect(bytes < 400_000)
        #expect(UninstallSizer.measure(temp.url.appendingPathComponent("missing")).bytes == nil)
    }
}
