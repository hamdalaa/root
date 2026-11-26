import Darwin
import Foundation
import Testing
@testable import Parabolic

/// Builds a small tree in a temp folder and checks the scanner's sums against stat(2).
@Suite struct StorageScannerTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/deep/deeper"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        try write("top.bin", 10_000)
        try write("a/one.bin", 50_000)
        try write("a/deep/two.bin", 200_000)
        try write("a/deep/deeper/three.bin", 30_000)
        try write("b/four.bin", 5_000)
    }

    private func write(_ relative: String, _ count: Int) throws {
        try Data(repeating: 0xA5, count: count).write(to: root.appendingPathComponent(relative))
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: root) }

    private func allocated(_ relative: String) -> Int64 {
        var st = stat()
        lstat(root.appendingPathComponent(relative).path, &st)
        return Int64(st.st_blocks) * 512
    }

    @Test func walkSumsAllocatedBytesOfEveryEntry() {
        defer { cleanUp() }
        let paths = ["", "top.bin", "a", "a/one.bin", "a/deep", "a/deep/two.bin", "a/deep/deeper", "a/deep/deeper/three.bin",
                     "b", "b/four.bin"]
        let expected = paths.reduce(Int64(0)) { $0 + allocated($1) }
        let walk = StorageScanner.walk(root)
        #expect(walk.bytes == expected)
        #expect(walk.files == 5)
        #expect(walk.unreadable == 0)
        #expect(!walk.cancelled)
    }

    @Test func walkRecordsListingsForRootAndChildren() throws {
        defer { cleanUp() }
        let walk = StorageScanner.walk(root, recordDepth: 1)
        let top = try #require(walk.listings[root.standardizedFileURL] ?? walk.listings.first { $0.key.path == root.path }?.value)
        #expect(Set(top.items.map(\.name)) == ["top.bin", "a", "b"])
        #expect(top.items.first?.name == "a") // largest first
        #expect(top.totalBytes + allocated("") == walk.bytes)
        let a = try #require(walk.listings.first { $0.key.lastPathComponent == "a" }?.value)
        let deep = try #require(a.items.first { $0.name == "deep" })
        #expect(deep.bytes == allocated("a/deep") + allocated("a/deep/two.bin") + allocated("a/deep/deeper")
                + allocated("a/deep/deeper/three.bin"))
        #expect(deep.fileCount == 2)
        // Depth 2 isn't recorded.
        #expect(walk.listings.keys.contains { $0.lastPathComponent == "deep" } == false)
    }

    @Test func hardLinksAreCountedOnce() throws {
        defer { cleanUp() }
        let before = StorageScanner.walk(root).bytes
        #expect(link(root.appendingPathComponent("a/one.bin").path, root.appendingPathComponent("b/one-link.bin").path) == 0)
        let after = StorageScanner.walk(root)
        #expect(after.bytes == before)
        #expect(after.files == 6)
    }

    @Test func symlinksAreNotFollowed() throws {
        defer { cleanUp() }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("StorageOutside-\(UUID().uuidString).bin")
        try Data(repeating: 1, count: 400_000).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let before = StorageScanner.walk(root).bytes
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.bin"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dirlink"),
                                                   withDestinationURL: FileManager.default.temporaryDirectory)
        let after = StorageScanner.walk(root).bytes
        #expect(after - before < 400_000)
    }

    @Test func streamingScanMatchesWalk() async throws {
        defer { cleanUp() }
        let expected = StorageScanner.walk(root).bytes - allocated("")
        var items: [URL: StorageItem] = [:]
        var finished = false
        var sawListing = false
        for await event in StorageScanner.scan(root, concurrency: 2) {
            switch event {
            case .listed(let listing):
                sawListing = true
                for item in listing.items { items[item.url] = item }
                #expect(listing.items.contains { $0.name == "a" && $0.isSizing })
            case .sized(let item, let listings, _):
                items[item.url] = item
                #expect(!item.isSizing)
                if item.name == "a" { #expect(listings.keys.contains { $0.lastPathComponent == "deep" }) }
            case .finished(let cancelled):
                #expect(!cancelled)
                finished = true
            case .progress, .failed:
                break
            }
        }
        #expect(sawListing && finished)
        #expect(items.values.reduce(0) { $0 + $1.bytes } == expected)
    }

    @Test func listingFoldsTheLongTail() {
        defer { cleanUp() }
        let items = (0..<(StorageListing.keep + 5)).map {
            StorageItem(url: URL(fileURLWithPath: "/tmp/x\($0)"), kind: .file, bytes: Int64($0 + 1), fileCount: 1)
        }
        let listing = StorageListing.make(folder: URL(fileURLWithPath: "/tmp"), items: items, isComplete: true)
        #expect(listing.items.count == StorageListing.keep)
        #expect(listing.otherCount == 5)
        #expect(listing.otherBytes == 1 + 2 + 3 + 4 + 5)
        #expect(listing.totalBytes == items.reduce(0) { $0 + $1.bytes })
        #expect(listing.items.first?.bytes == Int64(StorageListing.keep + 5))
    }

    @Test func missingFolderReportsFailure() async {
        defer { cleanUp() }
        var failed = false
        for await event in StorageScanner.scan(root.appendingPathComponent("nope")) {
            if case .failed = event { failed = true }
        }
        #expect(failed)
    }
}
