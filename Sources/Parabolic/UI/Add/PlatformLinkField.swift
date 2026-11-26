import AppKit
import SwiftUI

/// Recognises what a half-typed link points at, for live feedback in link fields.
enum TypedLinkRecognizer {
    /// Nil until the text reads like a link; `.other` for links to sites without a known mark.
    static func platform(in text: String) -> Platform? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeLink(trimmed) else { return nil }
        return Platform.detect(url: trimmed)
    }

    /// True for "youtube.com/…", "https://x" and similar; false for plain words like "lofi".
    static func looksLikeLink(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" "),
              let normalized = Discovery.normalizeURL(trimmed),
              let host = URL(string: normalized)?.host else { return false }
        return trimmed.contains("://") || (host.contains(".") && host.split(separator: ".").last.map { $0.count >= 2 } == true)
    }
}

/// Large glass link field. The site's logo replaces the link symbol as soon as the text is recognisable.
struct PlatformLinkField: View {
    @Binding var text: String
    var prompt = "https://"
    var hasError = false
    var autofocus = true
    var height: CGFloat = 52
    var onSubmit: () -> Void = {}

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var platform: Platform? { TypedLinkRecognizer.platform(in: text) }

    var body: some View {
        HStack(spacing: Tokens.space3) {
            leadingMark
                .frame(width: 22, height: 22)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($focused)
                .onSubmit(onSubmit)
                .accessibilityLabel("Link")
                .accessibilityValue(platform.map { $0 == .other ? text : "\(text), \($0.title)" } ?? text)
            if let platform, platform != .other {
                Text(platform.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.primary.opacity(0.06), in: .capsule)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .accessibilityHidden(true)
            }
            if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(HoverButtonStyle(cornerRadius: 12, padding: 4))
                .accessibilityLabel("Clear link")
            }
            Button(action: paste) {
                Label("Paste", systemImage: "doc.on.clipboard")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Paste link from clipboard")
            .help("Paste from clipboard")
        }
        .padding(.leading, Tokens.space4 + 2)
        .padding(.trailing, Tokens.space2)
        .frame(height: height)
        .glassCapsule(interactive: true)
        .overlay {
            Capsule()
                .strokeBorder(hasError ? Color.red.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
        }
        .animation(reduceMotion ? nil : Tokens.quick, value: platform)
        .onAppear { if autofocus { focused = true } }
    }

    @ViewBuilder
    private var leadingMark: some View {
        if let platform {
            PlatformGlyph(platform: platform, size: 20)
                .id(platform)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
        } else {
            Image(systemName: "link")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .transition(.opacity)
                .accessibilityHidden(true)
        }
    }

    private func paste() {
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        text = LinkScanner.firstLink(in: clip) ?? clip.trimmingCharacters(in: .whitespacesAndNewlines)
        focused = true
    }
}

/// A quiet row of platform marks that lights up the one being typed.
struct LinkPlatformStrip: View {
    var highlighted: Platform?
    static let featured: [Platform] = [.youtube, .soundcloud, .instagram, .tiktok, .x, .twitch, .bandcamp, .reddit, .bilibili]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Self.featured) { platform in
                PlatformGlyph(platform: platform, size: 14, style: highlighted == platform ? .brand : .monochrome)
                    .foregroundStyle(.tertiary)
                    .opacity(highlighted == nil || highlighted == platform ? 1 : 0.45)
                    .scaleEffect(highlighted == platform ? 1.15 : 1)
                    .help(platform.title)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Works with YouTube, SoundCloud, Instagram, TikTok and many more sites")
    }
}
