import AVKit
import SwiftUI

extension ConversionTarget {
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "opus", "flac", "wav", "ogg", "aac", "aiff"]

    /// True when the file on disk is audio, whatever the download options said.
    static func isAudioFile(_ url: URL) -> Bool { audioExtensions.contains(url.pathExtension.lowercased()) }
}

/// 16:9 artwork for items without a playable file.
struct InspectorArtwork: View {
    let item: DownloadItem

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    ItemArtwork(item: item, size: proxy.size, cornerRadius: 12)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.showsPlatformBadge {
                    PlatformBadge(platform: item.platform, size: 26)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .padding(8)
                }
            }
            .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
            .accessibilityHidden(true)
    }
}

/// Plays the finished file in place. The AVPlayer is only built while this view exists
/// (the inspector is visible and the file is on disk) and is paused when it goes away.
struct InspectorPlayer: View {
    let url: URL
    let isAudio: Bool
    var artworkURL: String?

    @State private var model: PlayerModel?

    var body: some View {
        Group {
            if let model {
                if isAudio {
                    AudioPlayerCard(model: model, artworkURL: artworkURL)
                } else {
                    NativeVideoPlayer(player: model.player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 12, style: .continuous))
                        .hairline(cornerRadius: 12)
                        .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
                }
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.primary.opacity(0.06))
                    .aspectRatio(16 / 9, contentMode: .fit)
            }
        }
        .onAppear { model = PlayerModel(url: url) }
        .onDisappear {
            model?.tearDown()
            model = nil
        }
        .accessibilityLabel(isAudio ? "Audio player" : "Video player")
    }
}

/// Wraps an AVPlayer with observable time, duration and play state for the custom audio controls.
@MainActor
@Observable
final class PlayerModel {
    let player: AVPlayer
    var currentTime: Double = 0
    var duration: Double = 0
    var isPlaying = false
    @ObservationIgnored private var timeObserver: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let seconds = self.player.currentItem?.duration.seconds, seconds.isFinite { self.duration = seconds }
                self.isPlaying = self.player.timeControlStatus != .paused
            }
        }
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            if duration > 0, currentTime >= duration - 0.25 { seek(to: 0) }
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func tearDown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }
}

/// Square-ish artwork with a glass control strip: play/pause, scrubber, elapsed and remaining time.
struct AudioPlayerCard: View {
    @Bindable var model: PlayerModel
    var artworkURL: String?

    @State private var scrubValue: Double?

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    GeometryReader { proxy in
                        ThumbnailView(url: artworkURL, size: proxy.size, cornerRadius: 0, symbol: "waveform")
                    }
                }
                .clipped()
            controls
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.regularMaterial)
        }
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .hairline(cornerRadius: 12)
        .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button(action: model.togglePlay) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(model.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

            VStack(spacing: 2) {
                Slider(value: Binding(get: { scrubValue ?? model.currentTime }, set: { scrubValue = $0 }),
                       in: 0...max(model.duration, 0.1)) { editing in
                    if !editing, let value = scrubValue {
                        model.seek(to: value)
                        scrubValue = nil
                    }
                }
                .controlSize(.mini)
                .disabled(model.duration <= 0)
                .accessibilityLabel("Position")
                HStack {
                    Text(Format.duration(scrubValue ?? model.currentTime) ?? "0:00")
                    Spacer()
                    Text("-" + (Format.duration(max(0, model.duration - (scrubValue ?? model.currentTime))) ?? "0:00"))
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// AVKit's AVPlayerView with inline macOS controls. Used instead of SwiftUI's `VideoPlayer`, whose
/// wrapper fails to resolve AVPlayerView at runtime in a SwiftPM-built app ("failed to demangle superclass").
struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
