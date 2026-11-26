import AppKit
import SwiftUI

/// Glass capsule URL field. Recognises the platform live: the link icon morphs into the site's logo
/// with a small name chip, and holding ⌥ previews which preset ⌥-Return will use.
struct URLEntryField: View {
    @Binding var text: String
    var onSubmit: () -> Void
    var onQuickSubmit: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isPasteHovered = false
    @State private var isOptionHeld = false
    @State private var flagsMonitor: Any?

    /// The recognised platform, or nil while the text isn't a link to a known site.
    private var platform: Platform? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 3, trimmed.contains(".") else { return nil }
        let detected = Platform.detect(url: LinkText.link(in: trimmed) ?? trimmed)
        return detected == .other ? nil : detected
    }

    private var quickPreset: DownloadPreset {
        settings.prefs.preset(for: platform ?? .other)
    }

    var body: some View {
        let platform = platform
        HStack(spacing: 7) {
            leadingIcon(platform)

            TextField("Paste a link to download…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onSubmit {
                    if NSEvent.modifierFlags.contains(.option) { onQuickSubmit() } else { onSubmit() }
                }
                .accessibilityLabel("Link to download")
                .accessibilityValue(platform.map { "\(text), \($0.title) link" } ?? text)
                .accessibilityHint("Return opens download options. Option-Return downloads right away with \(quickPreset.name).")

            trailingChip(platform)

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear")
                .transition(.opacity)
            }

            pasteButton
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .frame(height: 34)
        .frame(minWidth: 200, idealWidth: 420, maxWidth: 560)
        .glassEffect(.regular.interactive(), in: .capsule)
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(isFocused ? 0.6 : 0), lineWidth: 1.5))
        .help("Return: choose options · ⌥Return: download now as “\(quickPreset.name)”")
        .animation(.adaptive(reduceMotion, Tokens.motion), value: platform)
        .animation(.adaptive(reduceMotion, Tokens.quick), value: isFocused)
        .animation(.adaptive(reduceMotion, Tokens.quick), value: text.isEmpty)
        .animation(.adaptive(reduceMotion, Tokens.quick), value: isOptionHeld)
        .onAppear(perform: installMonitor)
        .onDisappear(perform: removeMonitor)
    }

    @ViewBuilder private func leadingIcon(_ platform: Platform?) -> some View {
        ZStack {
            if let platform {
                PlatformGlyph(platform: platform, size: 16)
                    .id(platform)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else {
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isFocused ? Color.accentColor : .secondary)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }

    /// Platform name chip; while ⌥ is held it previews the quick-download preset instead.
    @ViewBuilder private func trailingChip(_ platform: Platform?) -> some View {
        if isOptionHeld, !text.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill").imageScale(.small)
                Text("⌥↩ \(quickPreset.name)")
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Color.accentColor.opacity(0.13), in: .capsule)
            .fixedSize()
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            .accessibilityLabel("Option-Return downloads with \(quickPreset.name)")
        } else if let platform {
            Text(platform.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(.primary.opacity(0.07), in: .capsule)
                .overlay(Capsule().strokeBorder(.primary.opacity(0.06)))
                .fixedSize()
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                .accessibilityHidden(true)
        }
    }

    private var pasteButton: some View {
        Button(action: paste) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(Circle().fill(.primary.opacity(isPasteHovered ? 0.08 : 0)))
        .onHover { isPasteHovered = $0 }
        .help("Paste link from clipboard")
        .accessibilityLabel("Paste link")
    }

    private func paste() {
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        guard !clip.isEmpty else { NSSound.beep(); return }
        text = LinkScanner.firstLink(in: clip) ?? clip.trimmingCharacters(in: .whitespacesAndNewlines)
        isFocused = true
    }

    // MARK: ⌥ tracking

    private func installMonitor() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
            if held != isOptionHeld { isOptionHeld = held }
            return event
        }
    }

    private func removeMonitor() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
    }
}
