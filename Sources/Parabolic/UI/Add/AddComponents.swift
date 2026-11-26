import AppKit
import SwiftUI

// MARK: - Layout

/// Scroll view that hugs its content up to `maxHeight`, so the sheet grows with what it shows.
struct AdaptiveScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight ?? maxHeight, maxHeight))
    }
}

/// Floating glass bar pinned to the bottom of a sheet.
struct SheetBottomBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        GlassEffectContainer(spacing: Tokens.space2) {
            HStack(spacing: Tokens.space2) {
                leading
                Spacer(minLength: Tokens.space3)
                trailing
            }
            .padding(.leading, Tokens.space4)
            .padding(.trailing, Tokens.space2)
            .padding(.vertical, Tokens.space2)
            .glassPanel(cornerRadius: 18)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Tokens.space3)
        .padding(.bottom, Tokens.space3)
        .padding(.top, Tokens.space1)
    }
}

// MARK: - Buttons

/// Borderless button with a soft hover wash and pressed dim, for icon buttons and list rows.
struct HoverButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = Tokens.radiusControl
    var padding: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        HoverButtonBody(configuration: configuration, cornerRadius: cornerRadius, padding: padding)
    }

    private struct HoverButtonBody: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let padding: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(padding)
                .contentShape(.rect(cornerRadius: cornerRadius))
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.primary.opacity(configuration.isPressed ? 0.12 : (hovering && isEnabled ? 0.07 : 0)))
                )
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
                .animation(Tokens.quick, value: hovering)
        }
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    static var hover: HoverButtonStyle { HoverButtonStyle() }
}

// MARK: - Rows

/// GroupRow that expands to reveal more controls. Header shows a one-line summary while collapsed.
struct ExpandableRow<Content: View>: View {
    var title: String
    var summary: String?
    var symbol: String
    @Binding var isExpanded: Bool
    var showsDivider = false
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : Tokens.motion) { isExpanded.toggle() }
            } label: {
                GroupRow(title: title, subtitle: isExpanded ? nil : summary, symbol: symbol, showsDivider: false) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(HoverButtonStyle(cornerRadius: 10, padding: 0))
            .padding(.horizontal, 4)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : (summary ?? "Collapsed"))
            .accessibilityHint(isExpanded ? "Hides these options" : "Shows these options")

            if isExpanded {
                VStack(spacing: 0) { content }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if showsDivider {
                Divider().padding(.leading, 44).padding(.trailing, 14)
            }
        }
        .clipped()
    }
}

/// Folder row with abbreviated path and a Choose… button that opens NSOpenPanel.
struct FolderRow: View {
    @Binding var path: String
    var showsDivider = true

    var body: some View {
        GroupRow(title: "Save to", subtitle: (path as NSString).abbreviatingWithTildeInPath, symbol: "folder",
                 showsDivider: showsDivider) {
            Button("Choose…", action: choose)
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityLabel("Choose save folder")
                .help(path)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where downloads are saved."
        panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

/// Picker for a saved site login; "None" is nil.
struct CredentialPicker: View {
    var credentials: [Credential]
    @Binding var selection: UUID?
    var title = "Login"
    var showsDivider = true

    var body: some View {
        GroupRow(title: title, subtitle: "Signs in to the site with a saved account.", symbol: "person.badge.key",
                 showsDivider: showsDivider) {
            Picker(title, selection: $selection) {
                Text("None").tag(UUID?.none)
                Divider()
                ForEach(credentials) { credential in
                    Text(credential.name).tag(Optional(credential.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(title)
        }
    }
}

// MARK: - Shared format controls

/// Video/Audio switch, file type, video quality and audio quality rows, shared by single and playlist flows.
/// Switching kind restores the file type last used for that kind.
struct FormatRows: View {
    @Binding var options: DownloadOptions
    var qualities: [VideoQuality]
    var onUserChange: () -> Void = {}

    @AppStorage("add.lastVideoFileType") private var lastVideoType = MediaFileType.mp4.rawValue
    @AppStorage("add.lastAudioFileType") private var lastAudioType = MediaFileType.mp3.rawValue

    private var isAudio: Bool { options.fileType.isAudio }

    private var kindBinding: Binding<Bool> {
        Binding {
            options.fileType.isAudio
        } set: { audio in
            guard audio != options.fileType.isAudio else { return }
            remember(options.fileType)
            let stored = MediaFileType(rawValue: audio ? lastAudioType : lastVideoType)
            let fallback: MediaFileType = audio ? .mp3 : .mp4
            options.fileType = stored.flatMap { $0.isAudio == audio ? $0 : nil } ?? fallback
            options.videoFormatID = nil
            onUserChange()
        }
    }

    private var typeBinding: Binding<MediaFileType> {
        Binding { options.fileType } set: {
            options.fileType = $0
            remember($0)
            onUserChange()
        }
    }

    private func tracked<Value>(_ keyPath: WritableKeyPath<DownloadOptions, Value>) -> Binding<Value> {
        Binding { options[keyPath: keyPath] } set: {
            options[keyPath: keyPath] = $0
            onUserChange()
        }
    }

    private func remember(_ type: MediaFileType) {
        if type.isAudio { lastAudioType = type.rawValue } else { lastVideoType = type.rawValue }
    }

    var body: some View {
        GroupRow(title: "Download as", symbol: isAudio ? "waveform" : "film") {
            Picker("Download as", selection: kindBinding) {
                Label("Video", systemImage: "film").tag(false)
                Label("Audio", systemImage: "waveform").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Download video or audio only")
        }
        GroupRow(title: "File type", symbol: "doc") {
            Picker("File type", selection: typeBinding) {
                ForEach(isAudio ? MediaFileType.audioTypes : MediaFileType.videoTypes) { type in
                    Text(type.label).tag(type)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("File type")
        }
        if !isAudio {
            GroupRow(title: "Quality", symbol: "sparkles.tv", showsDivider: false) {
                Picker("Video quality", selection: tracked(\.videoQuality)) {
                    ForEach(qualities) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Video quality")
            }
        } else if options.fileType != .originalAudio {
            GroupRow(title: "Audio quality", symbol: "dial.medium", showsDivider: false) {
                Picker("Audio quality", selection: tracked(\.audioQuality)) {
                    ForEach(AudioQuality.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Audio quality")
            }
        } else {
            GroupRow(title: "Audio quality", subtitle: "Kept exactly as the site serves it.", symbol: "dial.medium",
                     showsDivider: false) { EmptyView() }
        }
    }
}

// MARK: - Helpers

extension String {
    /// Human name for a subtitle code ("en" → "English", "en-orig" → "English (original)").
    var subtitleDisplayName: String {
        let isOriginal = hasSuffix("-orig")
        let code = isOriginal ? String(dropLast(5)) : self
        let name = Locale.current.localizedString(forIdentifier: code) ?? code
        return isOriginal ? "\(name) (original)" : name
    }
}
