import Foundation
import Testing
@testable import Parabolic

/// Each scanner runs against a fake home folder so nothing on the real machine is read or touched.
@Suite struct CleanupScannerTests {
    private let home = CleanupTempHome()

    // MARK: App caches

    @Test func userCachesSkipsClaimedSystemAndOwnFolders() {
        home.file("Library/Caches/com.example.Editor/blob")
        home.file("Library/Caches/com.apple.Something/blob")
        home.file("Library/Caches/com.hamad.parabolic/blob")
        home.file("Library/Caches/Homebrew/bottle.tar.gz")
        home.file("Library/Caches/Google/Chrome/Default/data")
        home.file("Library/Caches/Google/Other/data")

        let result = CleanupScanner.scan(.userCaches, env: home.environment())

        #expect(Set(result.names) == ["com.example.Editor", "Other"])
        #expect(result.item(endingWith: "Google/Other")?.detail == "Google")
        #expect(result.items.allSatisfy { $0.isCache })
        #expect(result.totalBytes > 0)
    }

    @Test func userCachesMarksRunningAppsAndDeselectsThem() {
        home.file("Library/Caches/com.example.Editor/blob")
        home.file("Library/Caches/com.idle.Editor/blob")
        let env = home.environment(runningApps: [CleanupRunningApp(bundleID: "com.example.Editor", name: "Example")])

        let result = CleanupScanner.scan(.userCaches, env: env)

        let busy = result.item(endingWith: "com.example.Editor")
        #expect(busy?.inUseBy == "Example")
        #expect(busy?.isSelectedByDefault == false)
        #expect(result.item(endingWith: "com.idle.Editor")?.isSelectedByDefault == true)
    }

    // MARK: Browser caches

    @Test func browserCachesListOnlyCacheFoldersNeverProfileData() {
        let profile = "Library/Application Support/Google/Chrome"
        home.file("\(profile)/Default/Cache/data_0")
        home.file("\(profile)/Default/Cookies")
        home.file("\(profile)/Default/History")
        home.file("\(profile)/Profile 1/Code Cache/js/index")
        home.file("\(profile)/ShaderCache/data")
        home.file("\(profile)/Local State")
        home.file("Library/Caches/Google/Chrome/Default/Cache/f_000001")
        home.file("Library/Caches/com.apple.Safari/WebKitCache/blob")
        let env = home.environment(runningApps: [CleanupRunningApp(bundleID: "com.google.Chrome", name: "Google Chrome")])

        let result = CleanupScanner.scan(.browserCaches, env: env)

        let suffixes = ["Default/Cache", "Profile 1/Code Cache", "Chrome/ShaderCache",
                        "Caches/Google/Chrome/Default", "com.apple.Safari/WebKitCache"]
        for suffix in suffixes { #expect(result.item(endingWith: suffix) != nil, "missing \(suffix)") }
        #expect(result.items.count == suffixes.count)
        #expect(!result.paths.contains { $0.hasSuffix("Cookies") || $0.hasSuffix("History") || $0.hasSuffix("Local State") })
        #expect(result.item(endingWith: "Default/Cache")?.inUseBy == "Google Chrome")
        #expect(result.item(endingWith: "com.apple.Safari/WebKitCache")?.inUseBy == nil)
    }

    // MARK: Developer

    @Test func developerNamesDerivedDataAndKeepsArchivesOff() {
        home.file("Library/Developer/Xcode/DerivedData/Parabolic-abcdefghijklmnopqrstuvwxyzab/Build/x")
        home.file("Library/Developer/Xcode/DerivedData/ModuleCache.noindex/x")
        home.file(".npm/_cacache/index-v5/x")
        home.file("Library/Developer/Xcode/Archives/2026-10-01/App.xcarchive/Info.plist")

        let result = CleanupScanner.scan(.developer, env: home.environment())

        #expect(Set(result.names) == ["Parabolic", "Module cache", "npm cache", "Xcode Archives"])
        let archives = result.items.first { $0.name == "Xcode Archives" }
        #expect(archives?.isSelectedByDefault == false)
        #expect(archives?.isCache == false)
        #expect(archives?.note != nil)
        #expect(result.items.first { $0.name == "npm cache" }?.isSelectedByDefault == true)
    }

    @Test func developerMarksXcodeInUse() {
        home.file("Library/Developer/Xcode/DerivedData/App-abcdefghijklmnopqrstuvwxyzab/x")
        let env = home.environment(runningApps: [CleanupRunningApp(bundleID: "com.apple.dt.Xcode", name: "Xcode")])

        let result = CleanupScanner.scan(.developer, env: env)

        #expect(result.items.first?.inUseBy == "Xcode")
    }

    // MARK: Logs

    @Test func logsListAppLogsAndCrashReportsSeparately() {
        home.file("Library/Logs/SomeApp/app.log")
        home.file("Library/Logs/com.apple.something/x.log")
        home.file("Library/Logs/DiagnosticReports/SomeApp-2026.ips")

        let result = CleanupScanner.scan(.logs, env: home.environment())

        #expect(Set(result.names) == ["SomeApp", "SomeApp-2026.ips"])
        #expect(result.items.first { $0.name == "SomeApp-2026.ips" }?.detail == "Crash report")
        #expect(!result.names.contains("DiagnosticReports"))
    }

    // MARK: Project artifacts

    @Test func projectArtifactsNeedMarkerAndIdleProject() {
        home.file("Desktop/idle-app/package.json", bytes: 100)
        home.file("Desktop/idle-app/node_modules/pkg/big.bin", bytes: 1_200_000)
        home.ageTree("Desktop/idle-app", days: 60)

        home.file("Desktop/fresh-app/package.json", bytes: 100)
        home.file("Desktop/fresh-app/node_modules/pkg/big.bin", bytes: 1_200_000)

        home.file("Desktop/not-a-project/node_modules/big.bin", bytes: 1_200_000)
        home.ageTree("Desktop/not-a-project", days: 60)

        home.file("Desktop/tiny-app/package.json", bytes: 100)
        home.file("Desktop/tiny-app/node_modules/small.bin", bytes: 1_000)
        home.ageTree("Desktop/tiny-app", days: 60)

        let result = CleanupScanner.scan(.projectArtifacts, env: home.environment(projectIdleDays: 30))

        #expect(result.paths.count == 1)
        let item = result.item(endingWith: "idle-app/node_modules")
        #expect(item?.name == "idle-app")
        #expect(item?.detail == "node_modules")
        #expect(item?.isCache == false)
    }

    @Test func projectArtifactsRespectRecentGitActivity() {
        home.file("Desktop/rust/Cargo.toml", bytes: 100)
        home.file("Desktop/rust/target/debug/big.bin", bytes: 1_200_000)
        home.file("Desktop/rust/.git/index", bytes: 100)
        home.ageTree("Desktop/rust", days: 60)
        home.age("Desktop/rust/.git/index", days: 1)

        let result = CleanupScanner.scan(.projectArtifacts, env: home.environment(projectIdleDays: 30))

        #expect(result.items.isEmpty)
    }

    @Test func artifactMatchingUsesBundleSuffixMarkers() {
        #expect(CleanupProjectScanner.artifacts(presentIn: ["App.xcodeproj", "DerivedData"]).map(\.folder) == ["DerivedData"])
        #expect(CleanupProjectScanner.artifacts(presentIn: ["build", "README.md"]).isEmpty)
        #expect(CleanupProjectScanner.artifacts(presentIn: ["build", "pubspec.yaml", ".dart_tool"]).map(\.folder)
                == ["build", ".dart_tool"])
    }

    // MARK: Installers

    @Test func installersPreferDownloadsAndSkipMountedImages() {
        home.file("Downloads/Tool.dmg")
        home.file("Downloads/Mounted.dmg")
        home.file("Downloads/Apps/Nested.pkg")
        home.file("Desktop/Kept.dmg")
        home.file("Downloads/notes.txt")
        let mounted = home.url.appendingPathComponent("Downloads/Mounted.dmg").standardizedFileURL.path

        let result = CleanupScanner.scan(.installers, env: home.environment(mounted: [mounted]))

        #expect(Set(result.names) == ["Tool.dmg", "Mounted.dmg", "Nested.pkg", "Kept.dmg"])
        let tool = result.item(endingWith: "Tool.dmg")
        #expect(tool?.isSelectedByDefault == true)
        #expect(tool?.note == nil)
        #expect(tool?.detail == "Downloads")
        #expect(result.item(endingWith: "Nested.pkg")?.detail == "Downloads › Apps")
        #expect(result.item(endingWith: "Mounted.dmg")?.isSelectedByDefault == false)
        #expect(result.item(endingWith: "Mounted.dmg")?.note?.contains("Mounted") == true)
        #expect(result.item(endingWith: "Kept.dmg")?.isSelectedByDefault == false)
    }

    @Test func zipCountsAsInstallerOnlyWhenItHoldsAnApp() throws {
        home.file("work/Foo.app/Contents/Info.plist", bytes: 200)
        home.file("work/readme/notes.txt", bytes: 200)
        try zip("work/Foo.app", to: "Downloads/Foo.zip")
        try zip("work/readme", to: "Downloads/Docs.zip")

        #expect(CleanupFileScanners.isInstaller(home.url.appendingPathComponent("Downloads/Foo.zip")))
        #expect(!CleanupFileScanners.isInstaller(home.url.appendingPathComponent("Downloads/Docs.zip")))
        #expect(!CleanupFS.isInstallerPayloadName("__MACOSX/Foo.app/x"))
        #expect(CleanupFS.isInstallerPayloadName("Setup.pkg"))
    }

    // MARK: Old downloads

    @Test func oldDownloadsSkipRecentPartialAndInstallerFiles() {
        home.file("Downloads/old.pdf", age: 120)
        home.file("Downloads/new.pdf")
        home.file("Downloads/half.crdownload", age: 120)
        home.file("Downloads/old.dmg", age: 120)
        home.file("Downloads/.hidden", age: 120)
        home.folder("Downloads/Old Folder", age: 120)
        home.file("Downloads/Old Folder/a.txt", age: 120)
        home.age("Downloads/Old Folder", days: 120)

        let result = CleanupScanner.scan(.oldDownloads, env: home.environment())

        #expect(Set(result.names) == ["old.pdf", "Old Folder"])
        #expect(result.items.allSatisfy { $0.lastActivity != nil && !$0.isCache })
    }

    @Test func oldDownloadsUseLastTouchedOverModificationDate() {
        home.file("Downloads/opened-recently.pdf", age: 200)
        let recent = Date()
        let env = home.environment(lastTouched: { _ in recent })

        #expect(CleanupScanner.scan(.oldDownloads, env: env).items.isEmpty)
    }

    // MARK: Trash

    @Test func trashListsEverythingIncludingEmptyFilesAndVolumeTrashes() {
        home.file(".Trash/empty.txt", bytes: 0)
        home.file(".Trash/folder/b.bin")
        let volumeTrash = home.folder("VolumeTrash")
        home.file("VolumeTrash/c.bin")

        let result = CleanupScanner.scan(.trash, env: home.environment(volumeTrashes: [volumeTrash]))

        #expect(Set(result.names) == ["empty.txt", "folder", "c.bin"])
        #expect(CleanupCategoryID.trash.isSelectedByDefault == false)
    }

    // MARK: Cancellation

    @Test func cancelledScanReturnsNothing() {
        home.file("Library/Caches/com.example.Editor/blob")
        let cancel = CleanupCancellation()
        cancel.cancel()

        #expect(CleanupScanner.scan(.userCaches, env: home.environment(), cancel: cancel).items.isEmpty)
    }

    // MARK: Helpers

    private func zip(_ source: String, to destination: String) throws {
        let target = home.url.appendingPathComponent(destination)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", home.url.appendingPathComponent(source).path, target.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
