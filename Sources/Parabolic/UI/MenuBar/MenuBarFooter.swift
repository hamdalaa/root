import AppKit
import SwiftUI

/// Subscriptions status: "Checking subscriptions…" while a check runs, "3 new uploads" after.
/// Hidden when there's nothing to say.
struct MenuBarSubscriptionsLine: View {
    @Environment(SubscriptionStore.self) private var subscriptions
    var open: () -> Void
    @State private var isHovered = false

    private var newCount: Int { subscriptions.subscriptions.reduce(0) { $0 + $1.newCount } }

    private var text: String? {
        if subscriptions.isChecking { return "Checking subscriptions…" }
        guard newCount > 0 else { return nil }
        return newCount == 1 ? "1 new upload" : "\(newCount) new uploads"
    }

    var body: some View {
        if let text {
            Button(action: open) {
                HStack(spacing: Tokens.space2) {
                    ZStack {
                        if subscriptions.isChecking {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.parabolicAccent)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(text)
                        .font(.system(size: 12, weight: subscriptions.isChecking ? .regular : .medium))
                        .foregroundStyle(subscriptions.isChecking ? .secondary : .primary)
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                    Text("Subscriptions")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Tokens.space2)
                .frame(height: 30)
                .background(.primary.opacity(isHovered ? 0.07 : 0.035), in: .rect(cornerRadius: 10))
                .contentShape(.rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .onHover { hovering in withAnimation(Tokens.quick) { isHovered = hovering } }
            .accessibilityLabel(text)
            .accessibilityHint("Opens Subscriptions")
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// Footer: open app, search, pause/resume all, settings, quit, grouped on Liquid Glass.
struct MenuBarFooter: View {
    @Environment(DownloadManager.self) private var manager
    var openMain: () -> Void
    var openSearch: () -> Void

    private var canResumeAll: Bool { manager.items.contains { $0.status == .paused || $0.status == .stopped } }

    var body: some View {
        GlassEffectContainer(spacing: Tokens.space2) {
            HStack(spacing: 6) {
                Button(action: openMain) {
                    Label("Open", systemImage: "macwindow")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.glass)
                .help("Open Root")

                Button(action: openSearch) {
                    Label("Search…", systemImage: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.glass)
                .help("Search YouTube, SoundCloud and more")

                Spacer(minLength: Tokens.space2)

                if manager.runningCount > 0 {
                    iconButton("pause.fill", label: "Pause All") { manager.pauseAll() }
                } else {
                    iconButton("play.fill", label: "Resume All") { manager.resumeAll() }
                        .disabled(!canResumeAll)
                }
                iconButton("xmark.octagon", label: "Force Quit Apps… \(GlobalHotKey.forceQuitDisplayString)") {
                    ForceQuitWindowController.shared.show()
                }
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Settings…")
                .accessibilityLabel("Settings")
                iconButton("power", label: "Quit Root") { NSApp.terminate(nil) }
            }
            .controlSize(.regular)
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Circular icon button with hover and press feedback, sized for the menu bar window.
struct MenuBarIconButtonStyle: ButtonStyle {
    var size: CGFloat
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, size: size, filled: filled)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let filled: Bool
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? (isHovered ? Color.primary : Color.secondary) : Color.secondary.opacity(0.4))
                .frame(width: size, height: size)
                .background(Circle().fill(.primary.opacity(background)))
                .overlay(Circle().strokeBorder(.primary.opacity(filled ? 0.08 : 0)))
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .contentShape(.circle)
                .onHover { hovering in withAnimation(Tokens.quick) { isHovered = hovering } }
                .animation(Tokens.quick, value: configuration.isPressed)
        }

        private var background: Double {
            guard isEnabled else { return filled ? 0.04 : 0 }
            if configuration.isPressed { return 0.16 }
            if isHovered { return 0.1 }
            return filled ? 0.06 : 0
        }
    }
}
