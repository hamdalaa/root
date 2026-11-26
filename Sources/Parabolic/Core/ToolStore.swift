import Foundation
import Observation

/// Resolved helper binaries. Value type so it can be handed to background work.
struct ToolPaths: Sendable, Equatable {
    var ytdlp: String?
    var ffmpeg: String?
    var deno: String?
    var aria2c: String?

    /// PATH for child processes: tool directories first, then the usual system dirs.
    var childPATH: String {
        let toolDirs = [ytdlp, ffmpeg, deno, aria2c].compactMap { $0 }.map { ($0 as NSString).deletingLastPathComponent }
        var seen = Set<String>()
        return (toolDirs + ToolStore.searchDirectories + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }
}

/// Finds yt-dlp / ffmpeg / deno / aria2c and manages the app's own yt-dlp copy.
@MainActor
@Observable
final class ToolStore {
    private(set) var paths = ToolPaths()
    private(set) var ytdlpVersion: String?
    private(set) var ffmpegVersion: String?
    private(set) var isUpdating = false
    private(set) var lastMessage: String?

    var isReady: Bool { paths.ytdlp != nil }
    var usingManagedCopy: Bool { paths.ytdlp == Self.managedYtdlpPath }

    nonisolated static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Parabolic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    nonisolated static var managedBinDirectory: URL { supportDirectory.appendingPathComponent("bin", isDirectory: true) }
    nonisolated static var managedYtdlpPath: String { managedBinDirectory.appendingPathComponent("yt-dlp").path }

    nonisolated static let searchDirectories: [String] = {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin", "\(NSHomeDirectory())/.deno/bin", "/opt/local/bin"]
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            dirs += envPath.split(separator: ":").map(String.init)
        }
        return dirs
    }()

    /// Re-resolves every tool. Cheap; call on launch and after settings change.
    func refresh(channel: YtdlpChannel) async {
        let found = await Task.detached { Self.resolve(channel: channel) }.value
        paths = found
        async let yv = Self.version(of: found.ytdlp, args: ["--version"])
        async let fv = Self.version(of: found.ffmpeg, args: ["-version"])
        ytdlpVersion = await yv
        ffmpegVersion = await fv.flatMap { line in
            // "ffmpeg version 7.1 Copyright ..." -> "7.1"
            line.split(separator: " ").dropFirst(2).first.map(String.init)
        }
    }

    nonisolated static func resolve(channel: YtdlpChannel) -> ToolPaths {
        var paths = ToolPaths()
        let managed = managedYtdlpPath
        if channel == .automatic, FileManager.default.isExecutableFile(atPath: managed) {
            paths.ytdlp = managed
        } else {
            paths.ytdlp = find("yt-dlp") ?? (FileManager.default.isExecutableFile(atPath: managed) ? managed : nil)
        }
        paths.ffmpeg = find("ffmpeg")
        paths.deno = find("deno")
        // aria2 ships inside the app bundle; fall back to one on PATH.
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "aria2c")?.path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            paths.aria2c = bundled
        } else {
            paths.aria2c = find("aria2c")
        }
        return paths
    }

    nonisolated static func find(_ name: String) -> String? {
        for dir in searchDirectories {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    nonisolated static func version(of path: String?, args: [String]) async -> String? {
        guard let path else { return nil }
        let result = try? await ProcessRunner.capture(executable: path, arguments: args, environment: ["PATH": ToolPaths().childPATH])
        return result?.stdout.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Managed yt-dlp

    /// Downloads the official standalone macOS build into Application Support.
    func installManagedYtdlp(nightly: Bool) async {
        isUpdating = true
        defer { isUpdating = false }
        let repo = nightly ? "yt-dlp/yt-dlp-nightly-builds" : "yt-dlp/yt-dlp"
        guard let url = URL(string: "https://github.com/\(repo)/releases/latest/download/yt-dlp_macos") else { return }
        do {
            let (temp, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                lastMessage = "Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))."
                return
            }
            let fm = FileManager.default
            try fm.createDirectory(at: Self.managedBinDirectory, withIntermediateDirectories: true)
            let dest = URL(fileURLWithPath: Self.managedYtdlpPath)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: temp, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            await refresh(channel: .automatic)
            lastMessage = "Installed yt-dlp \(ytdlpVersion ?? "")."
        } catch {
            lastMessage = "Couldn't install yt-dlp: \(error.localizedDescription)"
        }
    }

    /// Updates whichever copy is in use. The managed copy self-updates; Homebrew copies are pointed at brew.
    func updateYtdlp(nightly: Bool, channel: YtdlpChannel) async {
        guard let ytdlp = paths.ytdlp else {
            await installManagedYtdlp(nightly: nightly)
            return
        }
        guard usingManagedCopy else {
            lastMessage = "This yt-dlp is managed by Homebrew/PATH. Run `brew upgrade yt-dlp`, or switch to the managed copy."
            return
        }
        isUpdating = true
        defer { isUpdating = false }
        let target = nightly ? "nightly" : "stable"
        do {
            let result = try await ProcessRunner.capture(executable: ytdlp, arguments: ["--update-to", target], environment: ["PATH": paths.childPATH])
            let output = (result.stdout + result.stderr).split(separator: "\n").last.map(String.init) ?? ""
            await refresh(channel: channel)
            lastMessage = output.isEmpty ? "yt-dlp is up to date." : output
        } catch {
            lastMessage = "Update failed: \(error.localizedDescription)"
        }
    }

    func removeManagedYtdlp(channel: YtdlpChannel) async {
        try? FileManager.default.removeItem(atPath: Self.managedYtdlpPath)
        await refresh(channel: channel)
    }
}
