import Testing
@testable import Parabolic

@Suite struct ArgumentBuilderTests {
    let tools = ToolPaths(ytdlp: "/bin/yt-dlp", ffmpeg: "/bin/ffmpeg", deno: nil, aria2c: nil)

    @Test func audioDownloadExtractsWithQuality() {
        var options = DownloadOptions(url: "https://example.com/v", saveFolder: "/tmp")
        options.fileType = .mp3
        options.audioQuality = .k320
        let args = ArgumentBuilder.download(options: options, prefs: Preferences(), tools: tools, credential: nil)
        #expect(args.contains("--extract-audio"))
        #expect(args.containsSequence(["--audio-format", "mp3", "--audio-quality", "320K"]))
        #expect(args.contains("--no-playlist"))
    }

    @Test func videoHeightCapBuildsFormatSelector() {
        var options = DownloadOptions(url: "https://example.com/v", saveFolder: "/tmp")
        options.videoQuality = .p720
        let args = ArgumentBuilder.formatArguments(options: options, prefs: Preferences())
        #expect(args.containsSequence(["-f", "bestvideo*[height<=720][vcodec!^=vp]+bestaudio/bestvideo*[height<=720]+bestaudio/best[height<=720]/bestvideo*+bestaudio/best"]))
        #expect(args.containsSequence(["--merge-output-format", "mp4"]))
    }

    @Test func credentialsAreForwarded() {
        let options = DownloadOptions(url: "https://example.com/v", saveFolder: "/tmp")
        let args = ArgumentBuilder.download(options: options, prefs: Preferences(), tools: tools,
                                            credential: ResolvedCredential(username: "", password: "pw"))
        #expect(args.containsSequence(["--video-password", "pw"]))
    }

    @Test func splitsQuotedCommandLines() {
        #expect(ArgumentBuilder.splitCommandLine(#"--foo "a b" 'c d' e\ f"#) == ["--foo", "a b", "c d", "e f"])
    }

    @Test func userFilenameEscapesPercent() {
        var options = DownloadOptions(url: "https://example.com", saveFolder: "/tmp")
        options.filename = "100% real/clip"
        #expect(ArgumentBuilder.resolvedFilename(options: options, prefs: Preferences()) == "100%% real-clip")
    }
}

@Suite struct ProgressParserTests {
    @Test func parsesTemplateLine() {
        let event = ProgressParser.parse("[PB];downloading;500;1000;NA;250.5;2")
        #expect(event == .downloading(fraction: 0.5, downloaded: 500, total: 1000, speed: 250.5, eta: 2))
    }

    @Test func parsesUnknownTotal() {
        let event = ProgressParser.parse("[PB];downloading;500;NA;NA;NA;NA")
        #expect(event == .downloading(fraction: nil, downloaded: 500, total: nil, speed: nil, eta: nil))
    }

    @Test func parsesFinalFile() {
        #expect(ProgressParser.parse("[PBFILE]/tmp/a.mp4") == .finalFile("/tmp/a.mp4"))
    }

    @Test func parsesAriaLine() {
        let event = ProgressParser.parse("[#2089b0 400.0KiB/33.2MiB(1%) CN:1 DL:115.7KiB ETA:4m51s]")
        guard case let .downloading(fraction, _, _, speed, eta) = event else { Issue.record("not progress"); return }
        #expect(fraction == 0.01)
        #expect(eta == 291)
        #expect(Int(speed ?? 0) == Int(115.7 * 1024))
    }

    @Test func detectsPostProcessing() {
        #expect(ProgressParser.parse("[Merger] Merging formats into \"x.mp4\"") == .processing("Merging video and audio…"))
    }
}

@Suite struct DiscoveryTests {
    @Test func cleansExtractorErrors() {
        #expect(Discovery.cleanError("noise\nERROR: [youtube] abc123: Video unavailable") == "Video unavailable")
    }

    @Test func normalizesBareHosts() {
        #expect(Discovery.normalizeURL("youtu.be/xyz") == "https://youtu.be/xyz")
        #expect(Discovery.normalizeURL("not a url") == nil)
    }

    @Test func parsesPlaylistEntries() {
        let root: [String: Any] = ["_type": "playlist", "title": "Mix", "entries": [
            ["id": "a", "url": "https://x/a", "title": "A", "duration": 10],
            ["id": "b", "url": "https://x/b", "title": "B"],
        ]]
        let info = Discovery.parse(root, sourceURL: "https://x")
        #expect(info.isPlaylist)
        #expect(info.entries.map(\.title) == ["A", "B"])
        #expect(info.entries[1].index == 2)
    }
}

extension Array where Element == String {
    func containsSequence(_ seq: [String]) -> Bool {
        guard seq.count <= count else { return false }
        return (0...(count - seq.count)).contains { Array(self[$0..<$0 + seq.count]) == seq }
    }
}
