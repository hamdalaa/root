import Foundation
import Testing
@testable import Parabolic

@Suite("Uninstaller related files")
struct UninstallRelatedTests {
    private func app(_ url: URL, id: String?, name: String) -> UninstallApp {
        UninstallApp(url: url, aliases: [], name: name, bundleID: id, bundleName: nil, version: nil, volume: .startup,
                     isAppStore: false, lastUsed: nil, needsAdmin: false)
    }

    @Test("Finds files by bundle ID, sub-ID, ByHost, containers, groups, name and launch agent")
    func findsEverything() throws {
        let temp = try UninstallTempDir()
        let library = temp.url.appendingPathComponent("Library")
        let appURL = try temp.makeApp("Apps/Foo Editor.app", bundleID: "com.foo.editor")
        try temp.makeDir("Library/Application Support/com.foo.editor")
        try temp.makeDir("Library/Application Support/Foo Editor")
        try temp.makeDir("Library/Caches/com.foo.editor.ShipIt")
        try temp.makeFile("Library/Preferences/com.foo.editor.plist")
        try temp.makeFile("Library/Preferences/ByHost/com.foo.editor.0F3A1B2C-1234-5678-9ABC-DEF012345678.plist")
        try temp.makeDir("Library/Containers/com.foo.editor.ShareExtension")
        try temp.makeDir("Library/Group Containers/ABCDE12345.com.foo.editor")
        try temp.makeDir("Library/Saved Application State/com.foo.editor.savedState")
        try temp.makeFile("Library/Cookies/com.foo.editor.binarycookies")
        // Not ours:
        try temp.makeDir("Library/Application Support/com.foo.editorial")
        try temp.makeDir("Library/Caches/com.other.app")
        // Launch agent that runs a helper inside the bundle.
        let agent: [String: Any] = ["Label": "com.foo.updater",
                                    "ProgramArguments": [appURL.path + "/Contents/MacOS/updater", "--check"]]
        try temp.makeDir("Library/LaunchAgents")
        try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
            .write(to: library.appendingPathComponent("LaunchAgents/com.foo.updater.plist"))

        let target = app(appURL, id: "com.foo.editor", name: "Foo Editor")
        let files = UninstallRelatedFinder.find(for: target, library: library, context: .init(), teamID: nil)
        let names = Set(files.map(\.url.lastPathComponent))
        #expect(names == [
            "com.foo.editor", "Foo Editor", "com.foo.editor.ShipIt", "com.foo.editor.plist",
            "com.foo.editor.0F3A1B2C-1234-5678-9ABC-DEF012345678.plist", "com.foo.editor.ShareExtension",
            "ABCDE12345.com.foo.editor", "com.foo.editor.savedState", "com.foo.editor.binarycookies",
            "com.foo.updater.plist",
        ])
        #expect(files.first { $0.url.lastPathComponent == "com.foo.updater.plist" }?.match == .launchAgentTarget)
        #expect(files.first { $0.url.lastPathComponent == "Foo Editor" }?.match == .name)
        #expect(files.allSatisfy { $0.sharedWith == nil })
    }

    @Test("Files of a more specific installed app are skipped; same-ID files are marked shared")
    func sharedAndSpecific() throws {
        let temp = try UninstallTempDir()
        let library = temp.url.appendingPathComponent("Library")
        let base = try temp.makeApp("Apps/Foo.app", bundleID: "com.foo.app")
        let pro = try temp.makeApp("Apps/Foo Pro.app", bundleID: "com.foo.app.pro")
        let twin = try temp.makeApp("Apps/Foo 2025.app", bundleID: "com.foo.app")
        try temp.makeDir("Library/Caches/com.foo.app")
        try temp.makeDir("Library/Caches/com.foo.app.pro")
        let target = app(base, id: "com.foo.app", name: "Foo")
        let all = [target, app(pro, id: "com.foo.app.pro", name: "Foo Pro"), app(twin, id: "com.foo.app", name: "Foo 2025")]
        let files = UninstallRelatedFinder.find(for: target, library: library,
                                                context: .init(apps: all, excluding: target), teamID: nil)
        #expect(files.map(\.url.lastPathComponent) == ["com.foo.app"])
        #expect(files.first?.sharedWith == "Foo 2025")
        #expect(files.first.map(UninstallerModel.isDefaultSelected) == false)
    }

    @Test("Developer-team group containers are found but not selected by default")
    func teamContainers() throws {
        let temp = try UninstallTempDir()
        let library = temp.url.appendingPathComponent("Library")
        let url = try temp.makeApp("Apps/Word.app", bundleID: "com.microsoft.Word")
        try temp.makeDir("Library/Group Containers/UBF8T346G9.Office")
        let files = UninstallRelatedFinder.find(for: app(url, id: "com.microsoft.Word", name: "Word"), library: library,
                                                context: .init(), teamID: "UBF8T346G9")
        let office = try #require(files.first)
        #expect(office.match == .developerTeam)
        #expect(!UninstallerModel.isDefaultSelected(office))
    }

    @Test("Path mentions need a boundary")
    func mentions() {
        let path = "/Applications/Foo.app"
        #expect(UninstallRelatedFinder.mentions("/Applications/Foo.app/Contents/MacOS/foo", path: path))
        #expect(UninstallRelatedFinder.mentions("app='/Applications/Foo.app'; open \"$app\"", path: path))
        #expect(UninstallRelatedFinder.mentions(path, path: path))
        #expect(!UninstallRelatedFinder.mentions("/Applications/Foo.appendix", path: path))
    }

    @Test("Generic and short names aren't used for name matching")
    func usableNames() {
        #expect(!UninstallNames.isUsable("Electron"))
        #expect(!UninstallNames.isUsable("Go"))
        #expect(UninstallNames.isUsable("Blender"))
        #expect(UninstallNames.vendorPrefix("com.adobe.Photoshop") == "com.adobe")
        #expect(UninstallNames.vendorPrefix("com.adobe") == nil)
    }
}
