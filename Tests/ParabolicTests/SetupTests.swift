import Foundation
import Testing
@testable import Parabolic

@Suite struct TorrentPathTests {
    @Test func localTorrentWithSpacesIsAccepted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Root Test \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("My Show S01.torrent")
        try Data("d4:infod4:name1:aee".utf8).write(to: file)
        #expect(Discovery.normalizeURL(file.path) == file.path)
        #expect(Discovery.normalizeURL(file.absoluteString) == file.path, "file:// URLs from Finder")
        #expect(EngineRouter.engine(for: file.path) == .torrent)
    }

    @Test func textWithSpacesIsStillNotALink() {
        #expect(Discovery.normalizeURL("not a url") == nil)
        #expect(Discovery.normalizeURL("/missing/My Show.torrent") == nil, "only existing files")
    }
}

@Suite struct PermissionProbeTests {
    @Test func readableProtectedFileMeansGranted() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(PermissionCenter.probeFullDiskAccess(paths: [file.path]) == .granted)
    }

    @Test func unreadableFileMeansDenied() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("x".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: file)
        }
        #expect(PermissionCenter.probeFullDiskAccess(paths: [file.path]) == .denied)
    }

    @Test func noProbeFileMeansUnknown() {
        #expect(PermissionCenter.probeFullDiskAccess(paths: ["/nonexistent-\(UUID().uuidString)"]) == .notAsked)
    }

    @Test func folderProbe() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(PermissionCenter.probeFolder(dir.path) == .granted)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)
        #expect(PermissionCenter.probeFolder(dir.path) == .denied)
    }

    /// System Events quits when idle; macOS then can't answer (-600). A grant seen before must not
    /// flip back to "Not set" just because System Events isn't running.
    @Test func automationStatusWhenSystemEventsIsNotRunning() {
        #expect(PermissionCenter.automationStatus(.unknown, rememberedGrant: true) == .granted)
        #expect(PermissionCenter.automationStatus(.unknown, rememberedGrant: false) == .notAsked)
        #expect(PermissionCenter.automationStatus(.granted, rememberedGrant: false) == .granted)
        #expect(PermissionCenter.automationStatus(.denied, rememberedGrant: true) == .denied)
        #expect(PermissionCenter.automationStatus(.notDetermined, rememberedGrant: true) == .notAsked,
                "-1744 is a real answer: macOS would ask again (e.g. after a reset)")
    }
}

/// History doesn't record the engine, and plain-file downloads keep the default `.mp4` file type,
/// so an .apk used to show as "MP4" with a video placeholder.
@Suite struct HistoryKindTests {
    private func entry(title: String, path: String?, type: MediaFileType = .mp4) -> HistoryEntry {
        HistoryEntry(url: "https://example.com/x", title: title, filePath: path, fileType: type, fileSize: 1, date: Date())
    }

    @Test func plainFilesShowTheirOwnType() {
        let apk = entry(title: "AM_SNAP.apk", path: "/Users/x/Downloads/AM_SNAP.apk")
        #expect(apk.kindLabel == "APK")
        #expect(apk.placeholderSymbol == FileArtwork.symbol(forFilename: "AM_SNAP.apk"))
        #expect(entry(title: "Book.pdf", path: nil).kindLabel == "PDF", "title is the fallback when no path was recorded")
    }

    @Test func mediaKeepsItsFormat() {
        #expect(entry(title: "Some Video", path: "/x/Some Video.mp4").kindLabel == "MP4")
        let song = entry(title: "Song v2.0", path: nil, type: .mp3)
        #expect(song.kindLabel == "MP3", "a dot in a media title is not a file extension")
        #expect(song.placeholderSymbol == "waveform")
        #expect(entry(title: "Clip", path: "/x/Clip.webm", type: .webm).placeholderSymbol == "play.rectangle")
    }

    @Test func statisticsCountPlainFilesSeparately() {
        let data = StatisticsData(entries: [
            entry(title: "a.apk", path: "/x/a.apk"), entry(title: "b.pdf", path: "/x/b.pdf"),
            entry(title: "Video", path: "/x/Video.mp4"), entry(title: "Song", path: "/x/Song.mp3", type: .mp3),
        ])
        #expect(data.fileCount == 2)
        #expect(data.videoCount == 1)
        #expect(data.audioCount == 1)
    }
}
