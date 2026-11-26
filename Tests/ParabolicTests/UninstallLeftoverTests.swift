import Foundation
import Testing
@testable import Parabolic

@Suite("Uninstaller leftovers and safety")
struct UninstallLeftoverTests {
    @Test("Canonical IDs strip extensions, ByHost UUIDs, team and group prefixes", arguments: [
        ("com.foo.bar.plist", "com.foo.bar"),
        ("com.foo.bar.savedState", "com.foo.bar"),
        ("com.foo.bar.binarycookies", "com.foo.bar"),
        ("com.foo.bar.0F3A1B2C-1234-5678-9ABC-DEF012345678.plist", "com.foo.bar"),
        ("UBF8T346G9.com.foo.bar", "com.foo.bar"),
        ("4FG648TM2A.group.com.aone.keka", "com.aone.keka"),
        ("group.com.foo.shared", "com.foo.shared"),
        ("io.vendor.App-Name", "io.vendor.app-name"),
    ])
    func canonical(input: String, expected: String) {
        #expect(UninstallLeftovers.canonicalID(fromEntryName: input) == expected)
    }

    @Test("Names that aren't bundle-ID shaped are ignored", arguments: [
        "Blender", "com.foo", "Adobe.macy-internal-root-leftover-20260519", "AI.ChitChat.ChatGPT-Mac",
        "2DC3B05C-3D0A-48B8-86DE-2192B4DBFC74", "22MMUN2RN5.lv", "default.store", "main.kts.compiled", "burp.community.frames",
    ])
    func notBundleShaped(input: String) {
        #expect(UninstallLeftovers.canonicalID(fromEntryName: input) == nil)
    }

    @Test("Classification is conservative")
    func classify() {
        let index = UninstallLeftovers.Index(bundleIDs: ["com.adobe.Photoshop", "com.hnc.Discord"], names: ["Blender"])
        #expect(UninstallLeftovers.classify("com.hnc.discord", index: index) == .installed)
        #expect(UninstallLeftovers.classify("com.hnc.discord.helper", index: index) == .installed)
        #expect(UninstallLeftovers.classify("com.adobe.dunamis", index: index) == .ambiguous)
        #expect(UninstallLeftovers.classify("org.blenderfoundation.blender", index: index) == .ambiguous)
        #expect(UninstallLeftovers.classify("com.vercel.cli", index: index) == .ambiguous)
        #expect(UninstallLeftovers.classify("com.crashlytics.data", index: index) == .ambiguous)
        #expect(UninstallLeftovers.classify("com.android.emulator", index: index) == .ambiguous)
        #expect(UninstallLeftovers.classify("is.workflow.shortcuts", index: index) == .ambiguous)
        #expect(UninstallLeftovers.classify("com.gone.app", index: index) == .orphan)
        #expect(UninstallLeftovers.classify("com.gone.app", index: index, isKnownApp: { $0 == "com.gone.app" }) == .installed)
    }

    @Test("Candidates skip Apple, installed apps and non-bundle names")
    func candidates() throws {
        let temp = try UninstallTempDir()
        let library = temp.url.appendingPathComponent("Library")
        try temp.makeDir("Library/Application Support/com.gone.app")
        try temp.makeDir("Library/Application Support/com.apple.something")
        try temp.makeDir("Library/Application Support/com.kept.app")
        try temp.makeDir("Library/Application Support/Blender")
        try temp.makeFile("Library/Preferences/com.gone.app.plist")
        try temp.makeFile("Library/Preferences/ByHost/com.gone.app.0F3A1B2C-1234-5678-9ABC-DEF012345678.plist")
        try temp.makeDir("Library/Group Containers/74J34U3R6X.com.apple.iWork")
        try temp.makeDir("Library/Group Containers/243LU875E5.groups.com.apple.podcasts")
        let index = UninstallLeftovers.Index(bundleIDs: ["com.kept.app"], names: [])
        let found = UninstallLeftovers.candidates(library: library, index: index, isKnownApp: { _ in false })
        #expect(Set(found.map(\.item.url.lastPathComponent)) == [
            "com.gone.app", "com.gone.app.plist", "com.gone.app.0F3A1B2C-1234-5678-9ABC-DEF012345678.plist",
        ])
        #expect(Set(found.map(\.key)) == ["com.gone.app"])
    }

    @Test("Groups drop anything changed in the last 30 days")
    func quietPeriod() {
        let now = Date()
        let old = now.addingTimeInterval(-60 * 24 * 3600)
        let fresh = now.addingTimeInterval(-2 * 24 * 3600)
        let items: [(key: String, item: UninstallLeftoverItem)] = [
            ("com.old.app", UninstallLeftoverItem(url: URL(fileURLWithPath: "/a"), kind: .caches, bytes: 100, newest: old)),
            ("com.old.app", UninstallLeftoverItem(url: URL(fileURLWithPath: "/b"), kind: .logs, bytes: 50, newest: old)),
            ("com.new.app", UninstallLeftoverItem(url: URL(fileURLWithPath: "/c"), kind: .caches, bytes: 999, newest: fresh)),
        ]
        let groups = UninstallLeftovers.group(items, now: now)
        #expect(groups.map(\.id) == ["com.old.app"])
        #expect(groups.first?.bytes == 150)
        #expect(groups.first?.displayName == "App")
        #expect(groups.first?.vendor == "old")
    }

    @Test("Protected paths are never removable")
    func protection() {
        let library = "/Users/me/Library"
        #expect(UninstallSafety.isProtected(path: "/System/Library/Foo"))
        #expect(UninstallSafety.isProtected(path: "/"))
        #expect(UninstallSafety.isProtected(path: "\(library)/Mobile Documents"))
        #expect(UninstallSafety.isProtected(path: "\(library)/Application Support/Parabolic"))
        #expect(UninstallSafety.isProtected(path: "\(library)/Preferences/com.hamad.parabolic.plist"))
        #expect(UninstallSafety.isProtected(path: "\(library)/Containers/com.apple.mail"))
        #expect(UninstallSafety.isProtected(path: "\(library)/Group Containers/74J34U3R6X.com.apple.iWork"))
        #expect(UninstallSafety.isProtected(path: "/Users/me/Pictures/Photos Library.photoslibrary"))
        #expect(UninstallSafety.isProtected(path: "\(library)/Keychains"))
        #expect(UninstallSafety.isAppleOwned("243LU875E5.groups.com.apple.podcasts"))
        #expect(!UninstallSafety.isAppleOwned("com.applesauce.app"))

        #expect(UninstallSafety.isRemovableSupportItem(path: "\(library)/Caches/com.foo.bar", library: library))
        #expect(UninstallSafety.isRemovableSupportItem(path: "\(library)/Preferences/ByHost/com.foo.bar.X.plist", library: library))
        #expect(!UninstallSafety.isRemovableSupportItem(path: "\(library)/Caches", library: library))
        #expect(!UninstallSafety.isRemovableSupportItem(path: "\(library)/Caches/com.foo.bar/inner", library: library))
        #expect(!UninstallSafety.isRemovableSupportItem(path: "\(library)/Mail/com.foo.bar", library: library))
        #expect(!UninstallSafety.isRemovableSupportItem(path: "\(library)/Caches/../Keychains/x", library: library))

        #expect(UninstallSafety.isRemovableApp(path: "/Applications/Discord.app", bundleID: "com.hnc.Discord"))
        #expect(!UninstallSafety.isRemovableApp(path: "/Applications/Safari.app", bundleID: "com.apple.Safari"))
        #expect(!UninstallSafety.isRemovableApp(path: "/Applications/Root.app", bundleID: "com.hamad.parabolic"))
        #expect(!UninstallSafety.isRemovableApp(path: "/Applications/Folder", bundleID: nil))
    }
}
