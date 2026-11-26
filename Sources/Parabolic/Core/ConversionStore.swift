import Foundation
import Observation

/// Formats a finished file can be converted into with ffmpeg.
enum ConversionTarget: String, CaseIterable, Identifiable, Codable, Sendable {
    case mp3, m4a, flac, wav, mp4, mov, gif

    var id: String { rawValue }
    var label: String {
        switch self {
        case .mp3: "MP3 Audio"
        case .m4a: "AAC Audio (M4A)"
        case .flac: "FLAC (Lossless)"
        case .wav: "WAV"
        case .mp4: "MP4 (H.264)"
        case .mov: "QuickTime MOV"
        case .gif: "Animated GIF"
        }
    }
    var symbol: String {
        switch self {
        case .mp3, .m4a, .flac, .wav: "waveform"
        case .mp4, .mov: "film"
        case .gif: "photo.stack"
        }
    }

    var ffmpegArguments: [String] {
        switch self {
        case .mp3: ["-vn", "-c:a", "libmp3lame", "-q:a", "0"]
        case .m4a: ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case .flac: ["-vn", "-c:a", "flac"]
        case .wav: ["-vn", "-c:a", "pcm_s16le"]
        case .mp4: ["-c:v", "h264_videotoolbox", "-b:v", "8M", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case .mov: ["-c:v", "h264_videotoolbox", "-b:v", "8M", "-c:a", "aac", "-b:a", "192k"]
        case .gif: ["-vf", "fps=12,scale=480:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0", "-an"]
        }
    }
}

@MainActor
@Observable
final class ConversionJob: Identifiable {
    enum State: Equatable { case running, completed, failed(String), cancelled }

    let id = UUID()
    let source: URL
    let output: URL
    let target: ConversionTarget
    var progress: Double?
    var state: State = .running
    @ObservationIgnored var runner: ProcessRunner?

    init(source: URL, output: URL, target: ConversionTarget) {
        self.source = source
        self.output = output
        self.target = target
    }
}

/// Runs ffmpeg conversions of downloaded files, with progress.
@MainActor
@Observable
final class ConversionStore {
    private(set) var jobs: [ConversionJob] = []
    @ObservationIgnored private let tools: ToolStore

    init(tools: ToolStore) { self.tools = tools }

    var activeCount: Int { jobs.filter { $0.state == .running }.count }

    /// Starts converting `file`. Output goes next to the source with a unique name.
    @discardableResult
    func convert(_ file: URL, to target: ConversionTarget, duration: Double?) -> ConversionJob? {
        guard let ffmpeg = tools.paths.ffmpeg else { return nil }
        let output = uniqueURL(for: file.deletingPathExtension().appendingPathExtension(target.rawValue))
        let job = ConversionJob(source: file, output: output, target: target)
        jobs.insert(job, at: 0)
        let args = ["-hide_banner", "-nostdin", "-y", "-i", file.path] + target.ffmpegArguments + ["-progress", "pipe:1", "-nostats", output.path]
        let total = duration ?? 0
        do {
            job.runner = try ProcessRunner(
                executable: ffmpeg, arguments: args, environment: ["PATH": tools.paths.childPATH],
                onLine: { line in
                    guard total > 0, line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms="),
                          let micros = Double(line.split(separator: "=").last ?? "") else { return }
                    let fraction = min(1, micros / 1_000_000 / total)
                    DispatchQueue.main.async { MainActor.assumeIsolated { job.progress = fraction } }
                },
                onExit: { code in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            job.runner = nil
                            guard job.state == .running else { return }
                            job.state = code == 0 ? .completed : .failed("ffmpeg exited with code \(code).")
                            if code == 0 { job.progress = 1 } else { try? FileManager.default.removeItem(at: job.output) }
                        }
                    }
                })
        } catch {
            job.state = .failed(error.localizedDescription)
        }
        return job
    }

    func cancel(_ job: ConversionJob) {
        job.state = .cancelled
        job.runner?.terminate()
        try? FileManager.default.removeItem(at: job.output)
    }

    func clearFinished() { jobs.removeAll { $0.state != .running } }

    private func uniqueURL(for url: URL) -> URL {
        var candidate = url
        var n = 2
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
