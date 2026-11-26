import SwiftUI

/// Floating glass banner offering to download a link the user just copied.
struct ClipboardBanner: View {
    let url: String
    var onDownload: () -> Void
    var onQuickDownload: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: Tokens.space2) {
            HStack(spacing: Tokens.space2) {
                HStack(spacing: 10) {
                    linkIcon
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(url)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 16)
                .frame(height: 44)
                .glassEffect(.regular, in: .capsule)
                .accessibilityElement(children: .combine)

                Button("Download…", action: onDownload)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .help("Choose format and quality")
                Button(action: onQuickDownload) {
                    Label("Quick Download", systemImage: "bolt.fill")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .help("Download now with your default preset")
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
                .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: 680)
    }

    private var title: String {
        let platform = Platform.detect(url: url)
        return platform == .other ? "Link copied — \(LinkText.host(of: url))" : "\(platform.title) link copied"
    }

    /// The site's logo when recognised, otherwise a plain link glyph.
    @ViewBuilder private var linkIcon: some View {
        let platform = Platform.detect(url: url)
        if platform == .other {
            Image(systemName: "link")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.14), in: .circle)
        } else {
            PlatformTile(platform: platform, size: 28)
        }
    }
}

/// Small transient confirmation shown after a clipboard link auto-started.
struct AutoStartToast: View {
    let host: String

    var body: some View {
        Label {
            Text("Downloading from \(host)")
                .font(.system(size: 12, weight: .medium))
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.parabolicAccent)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .glassEffect(.regular, in: .capsule)
        .accessibilityAddTraits(.isStaticText)
    }
}
