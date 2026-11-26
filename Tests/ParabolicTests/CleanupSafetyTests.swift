import Darwin
import Foundation
import Testing
@testable import Parabolic

/// The safety gate, de-duplication, planning and execution. Execution only ever deletes inside the temp home;
/// nothing is moved to the real Trash.
@Suite struct CleanupSafetyTests {
    private let home = CleanupTempHome()
    private let outside = CleanupTempHome()

    private var env: CleanupEnvironment { home.environment() }
    private var caches: URL { env.locations.caches }

    private func check(_ path: String, root: URL? = nil) -> CleanupRejection? {
        CleanupSafety.check(home.url.appendingPathComponent(path), root: root ?? caches,
                            allowlist: env.allowlist, home: env.home)
    }

    // MARK: Safety gate

    @Test func acceptsOrdinaryCacheFolder() {
        home.file("Library/Caches/com.example.Editor/blob")
        #expect(check("Library/Caches/com.example.Editor") == nil)
    }

    @Test func rejectsMissingAndSymlinkedItems() {
        home.folder("Library/Caches")
        home.link("Library/Caches/link", to: outside.file("secret.txt"))

        #expect(check("Library/Caches/nope") == .missing)
        #expect(check("Library/Caches/link") == .symlink)
    }

    @Test func rejectsItemsReachedThroughASymlinkedParent() {
        outside.file("victim/important.txt")
        home.link("Library/Caches/sneaky", to: outside.url.appendingPathComponent("victim"))

        #expect(check("Library/Caches/sneaky/important.txt") == .escapesRoot)
    }

    @Test func rejectsRootsOutsideTheAllowlistAndItemsOutsideTheirRoot() {
        home.file("Pictures/holiday.jpg")
        home.file("Downloads/file.txt")
        home.folder("Library/Caches")

        #expect(check("Pictures/holiday.jpg", root: home.url.appendingPathComponent("Pictures")) == .notAllowlisted)
        #expect(check("Downloads/file.txt") == .escapesRoot)
        #expect(check("Library/Caches") == .escapesRoot)
    }

    @Test func rejectsProtectedLocations() {
        home.file("Library/Caches/com.hamad.parabolic/blob")
        home.file("Downloads/Thing.app/Contents/Info.plist")
        home.file("Documents/Photos.photoslibrary/database")

        #expect(check("Library/Caches/com.hamad.parabolic") == .protectedLocation)
        #expect(check("Downloads/Thing.app", root: env.locations.downloads) == .protectedLocation)
        #expect(check("Documents/Photos.photoslibrary/database", root: env.locations.documents) == .protectedLocation)
        #expect(CleanupSafety.isProtected("/System/Library/x", home: "/Users/me"))
        #expect(CleanupSafety.isProtected("/Users/me/Library/Mobile Documents/doc", home: "/Users/me"))
        #expect(!CleanupSafety.isProtected("/Users/me/Library/Caches/foo", home: "/Users/me"))
    }

    /// A bundle-ID cache folder ending in ".app" is cleanable; a real app bundle is not.
    @Test func bundleIDsEndingInAppAreCleanableButRealAppsAreNot() {
        let cache = home.file("Library/Caches/com.example.App/data.bin").deletingLastPathComponent()
        #expect(!CleanupSafety.isProtected(cache.path, home: home.url.path))
        let app = home.file("Library/Caches/Real.app/Contents/Info.plist")
            .deletingLastPathComponent().deletingLastPathComponent()
        #expect(CleanupSafety.isProtected(app.path, home: home.url.path))
        #expect(CleanupSafety.isProtected(app.appendingPathComponent("Contents/MacOS").path, home: home.url.path))
    }

    @Test func rejectsImmutableFiles() {
        let file = home.file("Library/Caches/locked.bin")
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(file.path, 0) }

        #expect(check("Library/Caches/locked.bin") == .lockedBySystem)
    }

    @Test func pathContainmentIsComponentWise() {
        #expect(CleanupSafety.isStrictlyInside("/a/b/c", "/a/b"))
        #expect(!CleanupSafety.isStrictlyInside("/a/bc", "/a/b"))
        #expect(!CleanupSafety.isStrictlyInside("/a/b", "/a/b"))
        #expect(CleanupSafety.isInsideOrEqual("/a/b", "/a/b"))
    }

    // MARK: Measuring

    @Test func measureCountsHardLinksOnceAndNeverFollowsSymlinks() throws {
        let original = home.file("tree/data.bin", bytes: 100_000)
        try FileManager.default.linkItem(at: original, to: home.url.appendingPathComponent("tree/hardlink.bin"))
        home.link("tree/link", to: outside.file("huge.bin", bytes: 5_000_000))

        let size = CleanupFS.measure(home.url.appendingPathComponent("tree"))

        #expect(size.bytes >= 100_000)
        #expect(size.bytes < 200_000)
        #expect(size.denied == 0)
    }

    // MARK: De-duplication

    @Test func deduplicateKeepsEarlierCategoryAndDropsNestedOrParentItems() {
        let homebrew = home.file("Library/Caches/Homebrew/x").deletingLastPathComponent()
        let app = home.file("Desktop/app/node_modules/x").deletingLastPathComponent().deletingLastPathComponent()
        let modules = app.appendingPathComponent("node_modules")
        func item(_ url: URL) -> CleanupItem { CleanupItem(url: url, root: url, name: url.lastPathComponent, bytes: 1, isCache: true) }

        let results = CleanupEngine.deduplicate([
            CleanupCategoryResult(category: .developer, items: [item(homebrew)], deniedCount: 0),
            CleanupCategoryResult(category: .userCaches, items: [item(homebrew)], deniedCount: 0),
            CleanupCategoryResult(category: .projectArtifacts, items: [item(modules)], deniedCount: 0),
            CleanupCategoryResult(category: .installers, items: [item(app)], deniedCount: 0),
            CleanupCategoryResult(category: .oldDownloads, items: [item(modules.appendingPathComponent("x"))], deniedCount: 0),
        ])

        let byCategory = Dictionary(uniqueKeysWithValues: results.map { ($0.category, $0.items.count) })
        #expect(byCategory == [.userCaches: 1, .developer: 0, .projectArtifacts: 1, .installers: 0, .oldDownloads: 0])
        #expect(results.map(\.category) == [.userCaches, .developer, .projectArtifacts, .installers, .oldDownloads])
    }

    // MARK: Planning

    @Test func planChoosesTrashOrDeletePerCategory() {
        let url = home.url.appendingPathComponent("x")
        let cache = CleanupItem(url: url, root: home.url, name: "cache", bytes: 1, isCache: true)
        let file = CleanupItem(url: url, root: home.url, name: "file", bytes: 1, isCache: false)

        let immediate = CleanupEngine.plan([(.developer, cache), (.installers, file), (.trash, file), (.logs, cache)],
                                           deleteCachesImmediately: true)
        #expect(immediate.map(\.action) == [.delete, .trash, .delete, .trash])

        let safe = CleanupEngine.plan([(.userCaches, cache), (.trash, file)], deleteCachesImmediately: false)
        #expect(safe.map(\.action) == [.trash, .delete])
    }

    // MARK: Executing

    @Test func executeDeletesSafeItemsAndReportsUnsafeOnes() {
        home.file(".npm/_cacache/index/blob", bytes: 50_000)
        home.file(".Trash/old.txt")
        home.file("Downloads/keep.txt")
        home.link("Library/Caches/link", to: outside.file("precious.txt"))

        let developer = CleanupScanner.scan(.developer, env: env).items
        let trash = CleanupScanner.scan(.trash, env: env).items
        let symlink = CleanupItem(url: home.url.appendingPathComponent("Library/Caches/link"), root: caches,
                                  name: "link", bytes: 1, isCache: true)
        let notInTrash = CleanupItem(url: home.url.appendingPathComponent("Downloads/keep.txt"),
                                     root: env.locations.downloads, name: "keep.txt", bytes: 1, isCache: false)
        #expect(developer.count == 1)
        #expect(trash.count == 1)

        let plan = CleanupEngine.plan(developer.map { (.developer, $0) } + trash.map { (.trash, $0) }
                                      + [(.developer, symlink), (.trash, notInTrash)], deleteCachesImmediately: true)
        #expect(plan.allSatisfy { $0.action == .delete })

        let outcome = CleanupEngine.execute(plan, env: env, cancel: CleanupCancellation(), settleDelay: 0) { _, _ in }

        #expect(outcome.deletedCount == 2)
        #expect(outcome.trashedCount == 0)
        #expect(outcome.failures.count == 2)
        #expect(!home.exists(".npm/_cacache"))
        #expect(!home.exists(".Trash/old.txt"))
        #expect(home.exists("Downloads/keep.txt"))
        #expect(outside.exists("precious.txt"))
        #expect(outcome.failures.contains { $0.reason == CleanupRejection.symlink.reason })
        #expect(outcome.failures.contains { $0.reason == CleanupRejection.notAllowlisted.reason })
    }

    @Test func executeStopsWhenCancelled() {
        home.file(".npm/_cacache/index/blob")
        let plan = CleanupEngine.plan(CleanupScanner.scan(.developer, env: env).items.map { (.developer, $0) },
                                      deleteCachesImmediately: true)
        let cancel = CleanupCancellation()
        cancel.cancel()

        let outcome = CleanupEngine.execute(plan, env: env, cancel: cancel, settleDelay: 0) { _, _ in }

        #expect(outcome.deletedCount == 0)
        #expect(home.exists(".npm/_cacache"))
    }

    // MARK: Small helpers

    @Test func derivedDataNamesDropTheHashSuffix() {
        #expect(CleanupNaming.derivedDataProject("Parabolic-abcdefghijklmnopqrstuvwxyzab") == "Parabolic")
        #expect(CleanupNaming.derivedDataProject("My-App-abcdefghijklmnopqrstuvwxyzab") == "My-App")
        #expect(CleanupNaming.derivedDataProject("ModuleCache.noindex") == "Module cache")
        #expect(CleanupNaming.derivedDataProject("Not-AHash") == "Not-AHash")
    }

    @Test func parsesMountedImagesFromHdiutilPlist() throws {
        let plist: [String: Any] = ["images": [["image-path": "/Users/me/Downloads/Tool.dmg"], ["other": 1]]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        #expect(CleanupLiveEnvironment.parseMountedImages(data) == ["/Users/me/Downloads/Tool.dmg"])
        #expect(CleanupLiveEnvironment.parseMountedImages(Data("junk".utf8)).isEmpty)
    }

    @Test func historyRoundTripsThroughDefaults() throws {
        let suite = "cleanup-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = CleanupHistory(lastScanDate: Date(timeIntervalSince1970: 1_000), lastScanBytes: 42,
                                     lastCleanDate: nil, lastCleanFreedBytes: 7,
                                     lastCleanTrashedBytes: 3, lastCleanDeletedBytes: 4)

        history.save(to: defaults)

        let empty = try #require(UserDefaults(suiteName: suite + "-empty"))
        #expect(CleanupHistory.load(from: defaults) == history)
        #expect(CleanupHistory.load(from: empty) == CleanupHistory())
    }
}
