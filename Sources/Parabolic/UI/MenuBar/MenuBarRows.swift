import AppKit
import SwiftUI

/// One in-flight download: artwork with its platform badge, title, progress capsule, figures, pause/resume.
struct MenuBarActiveRow: View {
    @Environment(DownloadManager.self) private var manager
    var item: DownloadItem
    @State private var isHovered = false

    private var detail: String {
        switch item.status {
        case .running:
            let parts = [Format.percent(item.progress), item.speed > 0 ? Format.speed(item.speed) : nil, Format.eta(item.eta)]
                .compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? item.statusText : parts.joined(separator: " · ")
        default:
            return item.statusText
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(url: item.meta.thumbnailURL, size: CGSize(width: 52, height: 29), cornerRadius: 6,
                          symbol: item.engineSymbol ?? item.options.fileType.symbol)
                .overlay(alignment: .bottomTrailing) {
                    if item.showsPlatformBadge {
                        PlatformBadge(platform: item.platform, size: 18)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            .offset(x: 5, y: 5)
                    }
                }
                .padding(.trailing, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressCapsule(progress: item.status == .queued || item.status == .scheduled ? 0 : item.progress,
                                tint: Color.status(item.status), height: 4)
                Text(detail)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            controlButton
        }
        .padding(.horizontal, Tokens.space2)
        .padding(.vertical, 7)
        .menuBarRowHover(isHovered)
        .onHover { hovering in withAnimation(Tokens.quick) { isHovered = hovering } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.platform.title), \(item.status.label)")
        .accessibilityValue(item.progress.map { Format.percent($0) } ?? "")
    }

    @ViewBuilder
    private var controlButton: some View {
        if item.canPause {
            iconButton("pause.fill", label: "Pause") { manager.pause(item) }
        } else if item.canResume {
            iconButton("play.fill", label: "Resume") { manager.resume(item) }
        } else if item.status == .queued || item.status == .scheduled {
            iconButton("arrow.down.to.line", label: "Start now") { manager.startNow(item) }
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
        }
        .buttonStyle(MenuBarIconButtonStyle(size: 26, filled: true))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A finished download: platform badge, title, size and time, reveal-in-Finder on hover.
struct MenuBarRecentRow: View {
    var item: DownloadItem
    @State private var isHovered = false

    private var detail: String {
        [Format.bytes(item.totalBytes), item.finishedAt?.formatted(.relative(presentation: .named))]
            .compactMap { $0 }.filter { $0 != "—" }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            PlatformBadge(platform: item.platform, size: 26)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.status(.completed))
                        .background(Circle().fill(.background).padding(1))
                        .offset(x: 3, y: 3)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Tokens.space2)
            if item.fileExists, let url = item.fileURL {
                Button {
                    FinderReveal.reveal([url])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(MenuBarIconButtonStyle(size: 26))
                .opacity(isHovered ? 1 : 0)
                .help("Show in Finder")
                .accessibilityLabel("Show \(item.title) in Finder")
            }
        }
        .padding(.horizontal, Tokens.space2)
        .padding(.vertical, 6)
        .menuBarRowHover(isHovered)
        .onHover { hovering in withAnimation(Tokens.quick) { isHovered = hovering } }
        .onTapGesture(count: 2) { if let url = item.fileURL, item.fileExists { NSWorkspace.shared.open(url) } }
        .help("Double-click to open")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.platform.title), finished")
        .accessibilityAction(named: "Open") { if let url = item.fileURL, item.fileExists { NSWorkspace.shared.open(url) } }
    }
}

/// Copied-link suggestion: the platform is recognised and one click downloads with its preset.
struct MenuBarClipboardRow: View {
    @Environment(AppSettings.self) private var settings
    var url: String
    var onDownload: () -> Void
    var onDismiss: () -> Void
    @State private var isHovered = false

    private var platform: Platform { Platform.detect(url: url) }
    private var host: String { URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? url }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onDownload) {
                HStack(spacing: 10) {
                    PlatformBadge(platform: platform, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Download copied \(platform == .other ? "link" : platform.title + " link")")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text("\(host) · \(settings.prefs.preset(for: platform).name)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.parabolicAccent)
                        .opacity(isHovered ? 1 : 0.85)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download copied link from \(platform == .other ? host : platform.title)")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(MenuBarIconButtonStyle(size: 22))
            .help("Dismiss")
            .accessibilityLabel("Dismiss copied link")
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(.primary.opacity(isHovered ? 0.07 : 0.045), in: .rect(cornerRadius: Tokens.radiusRow))
        .overlay(RoundedRectangle(cornerRadius: Tokens.radiusRow).strokeBorder(.primary.opacity(0.08)))
        .onHover { hovering in withAnimation(Tokens.quick) { isHovered = hovering } }
        .help(url)
    }
}

extension View {
    /// Row hover highlight shared by the menu bar rows.
    func menuBarRowHover(_ isHovered: Bool) -> some View {
        background(RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(isHovered ? 0.06 : 0)))
            .contentShape(.rect(cornerRadius: 10))
    }
}
