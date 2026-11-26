import Foundation
import Testing
@testable import Parabolic

/// A throwaway folder with real files, removed after each test.
private final class Sandbox {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("finder-reveal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func path(_ relative: String) -> String { root.appendingPathComponent(relative).path }

    @discardableResult
    func file(_ relative: String, modified: Date = Date()) throws -> String {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url.path
    }
}

@Suite struct FinderRevealTests {
    @Test func existingFileIsSelected() throws {
        let box = try Sandbox()
        let path = try box.file("deepseek-harness-0.2.2-rc.5-mac-arm64.dmg")
        #expect(FinderReveal.plan(paths: [path]) == .select([URL(fileURLWithPath: path)]))
    }

    @Test func arabicNameWithSpacesAndPipeIsSelected() throws {
        let box = try Sandbox()
        let path = try box.file("حقيقة النُصحجيّة | كشكول مع بدر صالح.mp4")
        #expect(FinderReveal.plan(paths: [path]) == .select([URL(fileURLWithPath: path)]))
    }

    @Test func fileSortedIntoACategoryFolderIsFound() throws {
        let box = try Sandbox()
        let moved = try box.file("Programs/AmTv.apk")
        #expect(FinderReveal.plan(paths: [box.path("AmTv.apk")]) == .select([URL(fileURLWithPath: moved)]))
    }

    @Test func remuxedOrMergedOutputIsFound() throws {
        let box = try Sandbox()
        try box.file("clip.webm.part")
        let merged = try box.file("clip.mkv")
        #expect(FinderReveal.plan(paths: [box.path("clip.f137.mp4")]) == .select([URL(fileURLWithPath: merged)]))
    }

    @Test func newestMatchWinsWhenSeveralShareTheTitle() throws {
        let box = try Sandbox()
        try box.file("talk.webm", modified: Date(timeIntervalSinceNow: -3600))
        let newer = try box.file("talk.mp4")
        #expect(FinderReveal.plan(paths: [box.path("talk.mkv")]) == .select([URL(fileURLWithPath: newer)]))
    }

    @Test func deletedFileOpensItsFolderInsteadOfDoingNothing() throws {
        let box = try Sandbox()
        try box.file("other.zip")
        let plan = FinderReveal.plan(paths: [box.path("AM_SNAP.apk")])
        #expect(plan == .openFolder(URL(fileURLWithPath: box.root.path, isDirectory: true)))
    }

    @Test func missingFolderFallsBackToNearestExistingParent() throws {
        let box = try Sandbox()
        let plan = FinderReveal.plan(paths: [box.path("gone/deeper/file.pdf")])
        #expect(plan == .openFolder(URL(fileURLWithPath: box.root.path, isDirectory: true)))
    }

    @Test func noPathUsesTheSaveFolder() throws {
        let box = try Sandbox()
        let plan = FinderReveal.plan(paths: [nil], fallbackFolder: box.root.path)
        #expect(plan == .openFolder(URL(fileURLWithPath: box.root.path, isDirectory: true)))
    }

    @Test func onlyExistingFilesAreSelectedAndDuplicatesCollapse() throws {
        let box = try Sandbox()
        let a = try box.file("a.dmg")
        let plan = FinderReveal.plan(paths: [a, box.path("missing.iso"), a])
        #expect(plan == .select([URL(fileURLWithPath: a)]))
    }

    @Test func nothingToShow() {
        #expect(FinderReveal.plan(paths: [nil, ""]) == .none)
    }

    @Test func stemDropsExtensionAndFormatID() {
        #expect(FinderReveal.stem(of: "clip.f137.mp4") == "clip")
        #expect(FinderReveal.stem(of: "clip.f140-1.m4a") == "clip")
        #expect(FinderReveal.stem(of: "v1.2 notes.txt") == "v1.2 notes")
    }
}
