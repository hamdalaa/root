import SwiftUI

/// The first thing a new user sees: a large glass drop target that explains how to start.
struct WelcomeDropZone: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: Tokens.space5) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.parabolicAccent)
                .frame(width: 76, height: 76)
                .glassEffect(.regular.tint(Color.parabolicAccent.opacity(0.16)), in: .circle)
                .accessibilityHidden(true)

            VStack(spacing: Tokens.space2) {
                Text("Drop a link or paste with ⌘⇧V")
                    .font(.system(size: 22, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("Videos, music, playlists and whole channels from YouTube and the many other sites yt-dlp supports.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }

            Button { appState.presentAdd() } label: {
                Label("New Download", systemImage: "plus")
                    .padding(.horizontal, Tokens.space1)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .help("New Download (⌘N)")

            hints
                .padding(.top, Tokens.space1)
        }
        .padding(.horizontal, Tokens.space6 + Tokens.space2)
        .padding(.vertical, Tokens.space6 + Tokens.space1)
        .frame(maxWidth: 560)
        .background {
            RoundedRectangle(cornerRadius: Tokens.radiusWindowCard - 8, style: .continuous)
                .strokeBorder(Color.parabolicAccent.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                .padding(10)
        }
        .glassPanel(cornerRadius: Tokens.radiusWindowCard)
        .padding(Tokens.space6)
        // Zero minimums: a width-dependent min height here feeds back into the split view's constraints.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private var hints: some View {
        Grid(alignment: .leading, horizontalSpacing: Tokens.space5, verticalSpacing: Tokens.space2) {
            GridRow {
                ShortcutHint(keys: "⌘N", label: "New download")
                ShortcutHint(keys: "⌘⇧D", label: "Quick download")
            }
            GridRow {
                ShortcutHint(keys: "⌘⇧I", label: "Import links")
                ShortcutHint(keys: "⌥↩", label: "Quick from field")
            }
        }
    }
}

/// Short, specific empty message for each non-All filter.
struct FilterEmptyView: View {
    let filter: SidebarItem

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: filter.symbol)
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch filter {
        case .downloading: "Nothing downloading"
        case .queued: "Queue is empty"
        case .completed: "No finished downloads yet"
        case .failed: "No failed downloads"
        case .platform(let p): "No \(p.title) downloads"
        default: "Nothing here"
        }
    }

    private var message: String {
        switch filter {
        case .downloading: "Downloads in progress show their speed and time left here."
        case .queued: "Downloads waiting for a free slot or a scheduled start time wait here."
        case .completed: "Finished files land here, ready to open, preview or reveal in Finder."
        case .failed: "Downloads that fail or are stopped show up here so you can retry them."
        case .platform(let p): "Paste a \(p.title) link and it lands here automatically."
        default: ""
        }
    }
}
