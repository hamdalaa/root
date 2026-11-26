import SwiftUI

/// Stage 4: one video or track — hero, presets, options and the Download bar.
struct SingleMediaView: View {
    @Bindable var model: AddDownloadModel
    var info: MediaInfo
    var onClose: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var manager
    @Environment(ClipboardWatcher.self) private var clipboard
    @Environment(AppState.self) private var appState

    private static let barHeight: CGFloat = 72

    var body: some View {
        VStack(spacing: 0) {
            AdaptiveScroll(maxHeight: AddDownloadSheet.maxHeight - Self.barHeight) {
                VStack(alignment: .leading, spacing: Tokens.space5) {
                    MediaHero(meta: info.meta, platform: model.platform) { model.backToInput() }
                    DuplicateNoticeSlot(urls: [model.options.url, info.meta.webpageURL])
                    PresetChipsRow(presets: settings.prefs.allPresets, isApplied: model.matches) { model.apply($0); model.markFormatTouched() }
                    FormatSection(model: model, info: info)
                    if !info.subtitleLanguages.isEmpty || !info.autoCaptionLanguages.isEmpty {
                        SubtitlesSection(model: model, info: info)
                    }
                    TrimAndExtrasSection(model: model, info: info)
                    SaveSection(model: model, credentials: settings.prefs.credentials)
                }
                .padding(.horizontal, Tokens.space5)
                .padding(.top, Tokens.space5)
                .padding(.bottom, Tokens.space4)
            }
            bottomBar
        }
    }

    private var bottomBar: some View {
        SheetBottomBar {
            if let trimError = model.trimError {
                Label(trimError, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if let size = model.estimatedSize {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Estimated size").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("About \(Format.bytes(size))")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .contentTransition(.numericText())
                }
                .accessibilityElement(children: .combine)
            } else {
                Text(model.options.fileType.isAudio ? "Audio · \(model.options.fileType.label)" : "Video · \(model.options.fileType.label)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } trailing: {
            Button("Cancel", role: .cancel, action: onClose)
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Button(action: download) {
                Label(model.startLater ? "Schedule" : "Download",
                      systemImage: model.startLater ? "calendar.badge.clock" : "arrow.down")
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.trimError != nil)
            .accessibilityHint(model.startLater ? "Adds the download to the queue for later" : "Starts the download")
        }
        .controlSize(.large)
    }

    private func download() {
        guard case .success(let frame) = model.trimResult else { return }
        var options = model.options
        options.timeFrame = frame
        options.credentialID = model.credentialID
        if options.fileType.isAudio { options.videoFormatID = nil }
        if !info.meta.isLive { options.liveFromStart = false }
        if info.chapterCount == 0 { options.splitChapters = false }
        options.filename = options.filename.trimmingCharacters(in: .whitespacesAndNewlines)
        options.engine = .media
        options.httpHeaders = appState.browserHeaders(for: options.url)

        manager.enqueue(options: options, meta: info.meta, scheduledAt: model.startLater ? model.scheduledAt : nil)
        settings.prefs.lastUsedFileType = options.fileType
        settings.prefs.lastUsedVideoQuality = options.videoQuality
        settings.prefs.lastUsedAudioQuality = options.audioQuality
        clipboard.markSeen(options.url)
        clipboard.markSeen(model.urlText.trimmingCharacters(in: .whitespacesAndNewlines))
        if let page = info.meta.webpageURL { clipboard.markSeen(page) }
        onClose()
    }
}

// MARK: - Hero

struct MediaHero: View {
    var meta: MediaMeta
    var platform: Platform
    var onBack: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.space4) {
            ThumbnailView(url: meta.thumbnailURL, size: Tokens.heroThumb, duration: meta.isLive ? nil : meta.duration,
                          symbol: "play.rectangle")
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Tokens.space2) {
                Text(meta.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 3) {
                    if let uploader = meta.uploader {
                        Label(uploader, systemImage: "person.crop.circle")
                    }
                    if !meta.isLive, let duration = Format.duration(meta.duration) {
                        Label(duration, systemImage: "clock").monospacedDigit()
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .labelStyle(HeroLabelStyle())

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    HeroPlatformChip(platform: platform, fallback: meta.extractor)
                    if meta.isLive { Chip(text: "Live", symbol: "dot.radiowaves.left.and.right", tint: .red) }
                    Spacer(minLength: 0)
                    Button(action: onBack) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.hover)
                    .help("Use a different link")
                    .accessibilityLabel("Use a different link")
                }
            }
            .frame(maxWidth: .infinity, minHeight: Tokens.heroThumb.height, maxHeight: Tokens.heroThumb.height, alignment: .topLeading)
        }
    }
}

/// PlatformBadge plus the platform's name in a hairline capsule. Unknown sites show yt-dlp's extractor name.
struct HeroPlatformChip: View {
    var platform: Platform
    var fallback: String?

    private var name: String { platform == .other ? (fallback ?? platform.title) : platform.title }

    var body: some View {
        HStack(spacing: 6) {
            PlatformBadge(platform: platform, size: 20)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .padding(.leading, 2)
        .padding(.trailing, 10)
        .padding(.vertical, 2)
        .background(.primary.opacity(0.05), in: .capsule)
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("From \(name)")
    }
}

private struct HeroLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(.tertiary).frame(width: 14)
            configuration.title.lineLimit(1)
        }
    }
}

// MARK: - Presets

/// Horizontally scrolling glass chips. Tapping one fills the options below.
struct PresetChipsRow: View {
    var presets: [DownloadPreset]
    var isApplied: (DownloadPreset) -> Bool
    var onApply: (DownloadPreset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: Tokens.space2) {
                    HStack(spacing: Tokens.space2) {
                        ForEach(presets) { preset in
                            PresetChip(preset: preset, isApplied: isApplied(preset)) { onApply(preset) }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
            }
            .scrollIndicators(.never)
        }
    }
}

private struct PresetChip: View {
    var preset: DownloadPreset
    var isApplied: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isApplied ? "checkmark" : preset.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isApplied ? Color.parabolicAccent : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                Text(preset.name)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(isApplied ? Color.parabolicAccent.opacity(0.22) : (hovering ? Color.primary.opacity(0.06) : nil)).interactive(),
                     in: .capsule)
        .onHover { hovering = $0 }
        .animation(Tokens.quick, value: hovering)
        .accessibilityLabel("Preset \(preset.name)")
        .accessibilityAddTraits(isApplied ? .isSelected : [])
        .accessibilityHint("Applies this preset's file type and quality")
    }
}
