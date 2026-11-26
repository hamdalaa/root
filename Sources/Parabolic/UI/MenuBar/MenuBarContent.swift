import AppKit
import SwiftUI

/// The menu bar extra window: a solid, glassy mini-console for the queue.
struct MenuBarContent: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(ClipboardWatcher.self) private var clipboard
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    @State private var urlText = ""

    private static let maxActive = 5
    private static let maxRecent = 3

    private var inFlight: [DownloadItem] {
        Array((manager.activeItems + manager.queuedItems).prefix(Self.maxActive))
    }

    private var recent: [DownloadItem] {
        Array(manager.completedItems
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
            .prefix(Self.maxRecent))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuBarHeader()
                .padding(.horizontal, Tokens.space4)
                .padding(.top, Tokens.space4)
                .padding(.bottom, Tokens.space3)

            MenuBarURLField(text: $urlText, onSubmit: submit, onOpenAdd: openAddSheet)
                .padding(.horizontal, Tokens.space3)

            // Skip the suggestion when that same link is already in the field.
            if let detected = clipboard.detectedURL, detected != urlText.trimmingCharacters(in: .whitespacesAndNewlines) {
                MenuBarClipboardRow(url: detected,
                                    onDownload: { downloadDetected(detected) },
                                    onDismiss: { clipboard.dismiss() })
                    .padding(.horizontal, Tokens.space3)
                    .padding(.top, Tokens.space2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            MenuBarSubscriptionsLine(open: { navigate(to: .subscriptions) })
                .padding(.horizontal, Tokens.space3)
                .padding(.top, Tokens.space2)

            content
                .padding(.horizontal, Tokens.space3)
                .padding(.top, Tokens.space3)

            MenuBarNetworkLine(open: { navigate(to: .speedTest) })
                .padding(.horizontal, Tokens.space3)
                .padding(.vertical, Tokens.space2)

            Divider()

            MenuBarFooter(openMain: openMain, openSearch: { navigate(to: .search) })
                .padding(.horizontal, Tokens.space3)
                .padding(.vertical, 10)
        }
        .frame(width: 348)
        .animation(Tokens.motion, value: clipboard.detectedURL)
        .animation(Tokens.motion, value: inFlight.map(\.id))
    }

    @ViewBuilder
    private var content: some View {
        if inFlight.isEmpty && recent.isEmpty {
            MenuBarEmptyState()
                .padding(.vertical, Tokens.space5)
                .frame(maxWidth: .infinity)
                .menuBarPanel()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if !inFlight.isEmpty {
                    sectionCaption(inFlightCaption)
                    ForEach(inFlight) { item in
                        MenuBarActiveRow(item: item)
                    }
                }
                if !recent.isEmpty {
                    if !inFlight.isEmpty {
                        Divider().padding(.horizontal, Tokens.space2).padding(.vertical, Tokens.space1)
                    }
                    sectionCaption("Recently finished")
                    ForEach(recent) { item in
                        MenuBarRecentRow(item: item)
                    }
                }
            }
            .padding(Tokens.space1)
            .padding(.bottom, 2)
            .menuBarPanel()
        }
    }

    private var inFlightCaption: String {
        let total = manager.activeItems.count + manager.queuedItems.count
        return total > Self.maxActive ? "In progress · \(total)" : "In progress"
    }

    private func sectionCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Tokens.space2)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    // MARK: - Actions

    private func submit() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manager.quickDownload(url: trimmed)
        clipboard.markSeen(trimmed)
        urlText = ""
    }

    private func downloadDetected(_ url: String) {
        manager.quickDownload(url: url)
        clipboard.dismiss()
    }

    private func openAddSheet() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        openMain()
        appState.presentAdd(url: trimmed)
        urlText = ""
    }

    private func navigate(to item: SidebarItem) {
        openMain()
        if appState.sidebarSelection != item { appState.sidebarSelection = item }
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

extension View {
    /// The solid content panel: a faint fill with a hairline edge, so rows sit on a defined surface.
    func menuBarPanel() -> some View {
        background(.primary.opacity(0.035), in: .rect(cornerRadius: Tokens.radiusRow))
            .overlay(RoundedRectangle(cornerRadius: Tokens.radiusRow).strokeBorder(.primary.opacity(0.08)))
    }
}

// MARK: - Header

private struct MenuBarHeader: View {
    @Environment(DownloadManager.self) private var manager

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Root")
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: Tokens.space3)
            if manager.runningCount > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.speed(manager.totalSpeed))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText())
                    Sparkline(samples: manager.totalSpeedSamples)
                        .frame(width: 72, height: 16)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Total speed \(Format.speed(manager.totalSpeed))")
            }
        }
        .animation(Tokens.quick, value: manager.runningCount)
    }

    private var subtitle: String {
        let running = manager.runningCount, queued = manager.queuedItems.count
        switch (running, queued) {
        case (0, 0): return manager.activeItems.isEmpty ? "Ready" : "Paused"
        case (0, _): return "\(queued) queued"
        case (_, 0): return "\(running) downloading"
        default: return "\(running) downloading · \(queued) queued"
        }
    }
}

// MARK: - URL field

/// Link field with live platform recognition: the brand mark and the preset that will be used appear as you type.
private struct MenuBarURLField: View {
    @Environment(AppSettings.self) private var settings
    @Binding var text: String
    var onSubmit: () -> Void
    var onOpenAdd: () -> Void
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Nil until the text looks like a link, so typing a word doesn't flash a globe.
    private var platform: Platform? {
        guard trimmed.contains("."), !trimmed.contains(" ") else { return nil }
        return Platform.detect(url: trimmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            field
            if let platform {
                recognition(platform)
                    .padding(.horizontal, Tokens.space3)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Tokens.motion, value: platform)
    }

    private var field: some View {
        HStack(spacing: Tokens.space2) {
            ZStack {
                if let platform {
                    PlatformBadge(platform: platform, size: 22)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .id(platform)
                } else {
                    Image(systemName: "link")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)

            TextField("Paste a link to download", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(onSubmit)
                .accessibilityLabel("Link to download")

            Button(action: onOpenAdd) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(MenuBarIconButtonStyle(size: 26))
            .help("Choose format and options…")
            .accessibilityLabel("Open download options")

            if !trimmed.isEmpty {
                Button(action: onSubmit) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .help("Download now")
                .accessibilityLabel("Download now")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .frame(height: 36)
        .glassCapsule(interactive: true)
        .overlay(Capsule().strokeBorder(.primary.opacity(focused ? 0.14 : 0.06)))
        .animation(Tokens.quick, value: trimmed.isEmpty)
    }

    private func recognition(_ platform: Platform) -> some View {
        let preset = settings.prefs.preset(for: platform)
        return HStack(spacing: 4) {
            Text(platform == .other ? "Link" : "\(platform.title) link")
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            Text("·")
            Image(systemName: preset.symbol)
                .imageScale(.small)
            Text(preset.name)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(platform.title) link, downloads as \(preset.name)")
    }
}

// MARK: - Empty state

private struct MenuBarEmptyState: View {
    @Environment(AppSettings.self) private var settings

    private var hint: String {
        settings.prefs.globalHotKeyEnabled
            ? "Paste a link above, or press \(GlobalHotKey.displayString)\nafter copying one anywhere."
            : "Paste a link above, or copy one anywhere\nand it'll show up here."
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing downloading")
                .font(.system(size: 13, weight: .semibold))
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
