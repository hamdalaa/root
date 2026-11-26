import Foundation
import Testing
@testable import Parabolic

@Suite("Uninstaller symlinked support files")
struct UninstallLinkTests {
    /// Compares by path so file-URL details (trailing slash) don't matter.
    private func path(_ link: UninstallLinkTarget?) -> String? {
        switch link {
        case .supportTarget(let url)?: "data:" + url.path
        case .unexpected(let url)?: "other:" + url.path
        case .broken?: "broken"
        case .none?: "none"
        case nil: nil
        }
    }
    private func link(_ at: URL, to destination: String) throws {
        try FileManager.default.createDirectory(at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: at.path, withDestinationPath: destination)
    }

    @Test("A link to the same item in another Library's support folder is moved data")
    func supportTarget() throws {
        let temp = try UninstallTempDir()
        let data = try temp.makeFile("Drive/Library/Caches/com.foo.app/blob.bin", bytes: 80_000)
        let target = data.deletingLastPathComponent()
        let item = temp.url.appendingPathComponent("Home/Library/Caches/com.foo.app")
        try link(item, to: target.path)
        let resolved = UninstallLinks.resolve(item)
        #expect(path(resolved) == "data:" + target.path)
        #expect(UninstallLinks.measureURL(for: item, link: resolved)?.path == target.path)
        let measured = try #require(UninstallSizer.measure(target).bytes)
        #expect(measured >= 80_000)
        #expect(UninstallLinks.volumeNote(.supportTarget(URL(fileURLWithPath: "/Volumes/External/Library/Caches/x"))) == "on External")
    }

    @Test("Relative links and preference plists resolve too")
    func relativeAndPlist() throws {
        let temp = try UninstallTempDir()
        try temp.makeFile("Drive/Library/Preferences/com.foo.app.plist")
        let item = temp.url.appendingPathComponent("Home/Library/Preferences/com.foo.app.plist")
        try link(item, to: "../../../Drive/Library/Preferences/com.foo.app.plist")
        #expect(UninstallLinks.resolve(item).target?.lastPathComponent == "com.foo.app.plist")
    }

    @Test("Missing targets are broken links; nothing is measured")
    func broken() throws {
        let temp = try UninstallTempDir()
        let item = temp.url.appendingPathComponent("Home/Library/Caches/com.gone.app")
        try link(item, to: temp.url.appendingPathComponent("Drive/Library/Caches/com.gone.app").path)
        #expect(UninstallLinks.resolve(item) == .broken)
        #expect(UninstallLinks.measureURL(for: item, link: .broken) == nil)
    }

    @Test("Targets outside a support folder, renamed targets and link chains are unexpected")
    func unexpected() throws {
        let temp = try UninstallTempDir()
        let elsewhere = try temp.makeDir("Projects/com.foo.app")
        let a = temp.url.appendingPathComponent("Home/Library/Caches/com.foo.app")
        try link(a, to: elsewhere.path)
        #expect(path(UninstallLinks.resolve(a)) == "other:" + elsewhere.path)

        let renamed = try temp.makeDir("Drive/Library/Caches/something-else")
        let b = temp.url.appendingPathComponent("Home/Library/Caches/com.bar.app")
        try link(b, to: renamed.path)
        #expect(path(UninstallLinks.resolve(b)) == "other:" + renamed.path)

        try temp.makeDir("Real/Library/Caches/com.chain.app")
        let middle = temp.url.appendingPathComponent("Drive/Library/Caches/com.chain.app")
        try link(middle, to: temp.url.appendingPathComponent("Real/Library/Caches/com.chain.app").path)
        let c = temp.url.appendingPathComponent("Home/Library/Caches/com.chain.app")
        try link(c, to: middle.path)
        if case .unexpected = UninstallLinks.resolve(c) {} else { Issue.record("chains must not be followed") }

        let protected = temp.url.appendingPathComponent("Home/Library/Caches/Keychains")
        try temp.makeDir("Drive/Library/Caches/Keychains")
        try link(protected, to: temp.url.appendingPathComponent("Drive/Library/Caches/Keychains").path)
        if case .unexpected = UninstallLinks.resolve(protected) {} else { Issue.record("protected targets are never data") }
    }

    @Test("Plain items aren't links")
    func plain() throws {
        let temp = try UninstallTempDir()
        let file = try temp.makeFile("Home/Library/Caches/com.foo.app/x")
        #expect(UninstallLinks.resolve(file.deletingLastPathComponent()) == .none)
        #expect(UninstallLinks.isEquivalentSupportLocation("/Volumes/External/Library/Application Support/com.foo"))
        #expect(UninstallLinks.isEquivalentSupportLocation("/Volumes/External/Library/Preferences/ByHost/com.foo.X.plist"))
        #expect(!UninstallLinks.isEquivalentSupportLocation("/Volumes/External/Library/Caches/com.foo/nested"))
        #expect(!UninstallLinks.isEquivalentSupportLocation("/Volumes/External/Stuff/com.foo"))
        #expect(!UninstallLinks.isEquivalentSupportLocation("/Volumes/External/Library/Mail/com.foo"))
    }

    @Test("Related files and leftovers carry the link state")
    func carriedThrough() throws {
        let temp = try UninstallTempDir()
        let library = temp.url.appendingPathComponent("Home/Library")
        let appURL = try temp.makeApp("Apps/Foo.app", bundleID: "com.foo.app")
        let target = try temp.makeDir("Drive/Library/Caches/com.foo.app")
        try link(library.appendingPathComponent("Caches/com.foo.app"), to: target.path)
        try link(library.appendingPathComponent("Preferences/com.foo.app.plist"),
                 to: temp.url.appendingPathComponent("Drive/Library/Preferences/com.foo.app.plist").path)

        let app = UninstallApp(url: appURL, aliases: [], name: "Foo", bundleID: "com.foo.app", bundleName: nil, version: nil,
                               volume: .startup, isAppStore: false, lastUsed: nil, needsAdmin: false)
        let files = UninstallRelatedFinder.find(for: app, library: library, context: .init(), teamID: nil)
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.url.lastPathComponent, $0) })
        #expect(path(byName["com.foo.app"]?.link) == "data:" + target.path)
        #expect(byName["com.foo.app"]?.measureURL?.path == target.path)
        #expect(byName["com.foo.app.plist"]?.link == .broken)
        #expect(byName["com.foo.app.plist"]?.measureURL == nil)

        let found = UninstallLeftovers.candidates(library: library, index: .init(bundleIDs: [], names: []),
                                                  isKnownApp: { _ in false })
        #expect(path(found.first { $0.item.url.lastPathComponent == "com.foo.app" }?.item.link) == "data:" + target.path)
    }

    @Test("Plans hand the link target to the trasher")
    func planCarriesTarget() {
        let target = URL(fileURLWithPath: "/Volumes/External/Library/Caches/com.foo.app")
        let app = UninstallApp(url: URL(fileURLWithPath: "/Applications/Foo.app"), aliases: [], name: "Foo",
                               bundleID: "com.foo.app", bundleName: nil, version: nil, volume: .startup,
                               isAppStore: false, lastUsed: nil, needsAdmin: false)
        let file = UninstallRelatedFile(url: URL(fileURLWithPath: "/Users/me/Library/Caches/com.foo.app"), kind: .caches,
                                        match: .bundleID, sharedWith: nil, link: .supportTarget(target))
        let plan = UninstallerPlan(app: app, appBytes: 10, files: [file], fileSizes: [file.id: 500], isRunning: false,
                                   pendingSizes: false)
        let item = plan.trashItems.first { $0.url == file.url }
        #expect(item?.linkedTarget == target)
        #expect(item?.bytes == 500)
        #expect(plan.totalBytes == 510)
    }
}
