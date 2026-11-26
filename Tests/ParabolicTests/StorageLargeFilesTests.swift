import Foundation
import Testing
@testable import Parabolic

@Suite struct StorageLargeFilesTests {
    private func file(_ name: String, _ size: Int64, allocated: Int64? = nil) -> StorageLargeFile {
        StorageLargeFile(url: URL(fileURLWithPath: "/Users/test/\(name)"), size: size, allocated: allocated ?? size,
                         lastUsed: nil, kind: StorageFileKind.classify(path: name), protectionReason: nil)
    }

    @Test func thresholdFilteringKeepsOnlyFilesAtOrAboveMinimum() {
        let files = [file("a.mov", 99_999_999), file("b.mov", 100_000_000), file("c.zip", 600_000_000), file("d.dmg", 6_000_000_000)]
        #expect(StorageLargeFileSearch.filter(files, minimum: StorageThreshold.mb100.rawValue).map(\.name) == ["d.dmg", "c.zip", "b.mov"])
        #expect(StorageLargeFileSearch.filter(files, minimum: StorageThreshold.mb500.rawValue).map(\.name) == ["d.dmg", "c.zip"])
        #expect(StorageLargeFileSearch.filter(files, minimum: StorageThreshold.gb1.rawValue).map(\.name) == ["d.dmg"])
        #expect(StorageLargeFileSearch.filter(files, minimum: StorageThreshold.gb5.rawValue).map(\.name) == ["d.dmg"])
        #expect(StorageLargeFileSearch.filter(files, minimum: 100_000_000, kind: .archive).map(\.name) == ["c.zip"])
    }

    @Test func sortsByWhatActuallyTakesSpace() {
        let sparse = file("vm.qcow2", 64_000_000_000, allocated: 2_000_000_000)
        let solid = file("movie.mkv", 5_000_000_000)
        let sorted = StorageLargeFileSearch.filter([sparse, solid], minimum: 100_000_000)
        #expect(sorted.map(\.name) == ["movie.mkv", "vm.qcow2"])
        #expect(sparse.isSparse)
        #expect(!solid.isSparse)
    }

    @Test(arguments: [
        ("Movie.MOV", StorageFileKind.video), ("song.flac", .audio), ("shot.HEIC", .image), ("backup.tar", .archive),
        ("Xcode.xip", .archive), ("install.dmg", .diskImage), ("Safari.app", .app), ("Thing.pkg", .installer),
        ("Docker.raw", .virtualMachine), ("disk.vmdk", .virtualMachine), ("Report.pdf", .document), ("blob.bin", .other),
    ])
    func classifiesByExtension(name: String, kind: StorageFileKind) {
        #expect(StorageFileKind.classify(path: "/x/\(name)") == kind)
    }

    @Test func classifiesByContentTypeWhenExtensionUnknown() {
        #expect(StorageFileKind.classify(path: "/x/clip", contentTypes: ["public.movie", "public.data"]) == .video)
        #expect(StorageFileKind.classify(path: "/x/Thing", contentTypes: ["com.apple.application-bundle"]) == .app)
    }

    @Test func parsesSpotlightStatus() {
        #expect(StorageLargeFileSearch.parseIndexingStatus("/:\n\tIndexing enabled. \n") == true)
        #expect(StorageLargeFileSearch.parseIndexingStatus("/Volumes/X:\n\tIndexing disabled.\n") == false)
        #expect(StorageLargeFileSearch.parseIndexingStatus("/Volumes/X:\n\tIndex is read-only.\n") == true)
        #expect(StorageLargeFileSearch.parseIndexingStatus("/Volumes/X:\n\tSpotlight server is disabled.\n") == false)
        #expect(StorageLargeFileSearch.parseIndexingStatus("/Users/x:\n\tError: unknown indexing state.\n") == nil)
    }

    @Test func excludesBundleInternalsAndTrash() {
        #expect(StorageLargeFileSearch.isExcluded("/Applications/Xcode.app/Contents/Developer/big.dylib"))
        #expect(!StorageLargeFileSearch.isExcluded("/Applications/Xcode.app"))
        #expect(StorageLargeFileSearch.isExcluded("/Users/me/.Trash/old.mov"))
        #expect(StorageLargeFileSearch.isExcluded("/System/Library/foo.bin"))
        #expect(!StorageLargeFileSearch.isExcluded("/Users/me/Movies/v1.0.final.mov"))
    }

    @Test func walkFallbackFindsFilesAboveThreshold() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageLarge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub/Thing.app/Contents"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 300_000).write(to: root.appendingPathComponent("big.mov"))
        try Data(repeating: 7, count: 1_000).write(to: root.appendingPathComponent("small.mov"))
        try Data(repeating: 7, count: 400_000).write(to: root.appendingPathComponent("sub/Thing.app/Contents/payload"))
        let result = StorageLargeFileSearch.walk(root, minimum: 200_000)
        #expect(Set(result.files.map(\.name)) == ["big.mov", "Thing.app"])
        #expect(result.files.first { $0.name == "Thing.app" }?.kind == .app)
        #expect(result.unreadable == 0)
    }

    @Test func abbreviatesHome() {
        #expect(StorageLargeFileSearch.abbreviate("/Users/me/Movies", home: "/Users/me") == "~/Movies")
        #expect(StorageLargeFileSearch.abbreviate("/Users/me", home: "/Users/me") == "~")
        #expect(StorageLargeFileSearch.abbreviate("/Volumes/External/x", home: "/Users/me") == "/Volumes/External/x")
    }
}

@Suite struct StorageSafetyTests {
    private let home = URL(fileURLWithPath: "/Users/me")

    @Test(arguments: [
        "/", "/System/Library", "/usr/bin/ls", "/Volumes/External", "/Users/me", "/Users/me/Documents", "/Users/me/Library",
        "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/a.pdf", "/Users/me/Library/Mail/V10",
        "/Users/me/Library/Messages", "/Users/me/Library/Keychains/login.keychain-db",
        "/Users/me/Library/Application Support/Parabolic/history.json", "/Users/me/Pictures/Photos Library.photoslibrary",
        "/Users/me/Music/Music/Media/song.m4a", "/System/Volumes/Data/Users/me/Library/Mail",
        "/Users/me/Library/Application Support", "/Users/me/Library/Containers", "/Volumes", "/private",
    ])
    func protectsSystemAndPersonalData(path: String) {
        #expect(StorageSafety.protectionReason(for: URL(fileURLWithPath: path), home: home) != nil)
    }

    @Test(arguments: [
        "/Users/me/Downloads/big.dmg", "/Users/me/Movies/clip.mov", "/Users/me/Library/Caches/com.example",
        "/Volumes/External/old-backup.zip", "/usr/local/Cellar/thing", "/Users/me/Library/Application Support/Other",
    ])
    func allowsOrdinaryFiles(path: String) {
        #expect(StorageSafety.protectionReason(for: URL(fileURLWithPath: path), home: home) == nil)
    }

    @Test func volumePressureThresholds() {
        let gb: Int64 = 1_000_000_000
        #expect(StoragePressure(available: 5 * gb, total: 500 * gb) == .critical)
        #expect(StoragePressure(available: 25 * gb, total: 500 * gb) == .warning)
        #expect(StoragePressure(available: 200 * gb, total: 500 * gb) == .ok)
        #expect(StoragePressure(available: 0, total: 0) == .ok)
    }

    @Test func volumeMathSplitsPurgeable() {
        let gb: Int64 = 1_000_000_000
        let volume = StorageVolume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD", total: 500 * gb, free: 5 * gb,
                                   availableForImportant: 12 * gb, isInternal: true, isRemovable: false, isRoot: true,
                                   isLocal: true, format: "APFS")
        #expect(volume.purgeable == 7 * gb)
        #expect(volume.used == 488 * gb)
        #expect(volume.available == 12 * gb)
        #expect(volume.used + volume.purgeable + volume.free == volume.total)
    }
}
