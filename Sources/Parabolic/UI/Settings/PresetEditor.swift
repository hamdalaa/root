import SwiftUI

struct SettingsPresetDraft: Identifiable {
    var preset: DownloadPreset
    var isNew: Bool
    var id: UUID { preset.id }
}

/// Sheet for creating or editing a custom preset.
struct SettingsPresetEditor: View {
    static let symbols = [
        "play.rectangle.fill", "film", "tv.fill", "sparkles.tv",
        "music.note", "waveform", "headphones", "mic.fill",
        "music.note.list", "radio", "airpodsmax", "hifispeaker.fill",
        "star.fill", "bolt.fill", "leaf.fill", "archivebox.fill",
    ]

    @State var draft: SettingsPresetDraft
    var onSave: (SettingsPresetDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var languagesText = ""

    private var canSave: Bool { !draft.preset.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.preset.name, prompt: Text("e.g. Podcast archive"))
                    LabeledContent("Symbol") {
                        SymbolGrid(selection: $draft.preset.symbol, symbols: Self.symbols)
                    }
                } header: {
                    Text(draft.isNew ? "New preset" : "Edit preset")
                }

                Section("Format") {
                    Picker("File type", selection: $draft.preset.fileType) {
                        Section("Video") {
                            ForEach(MediaFileType.videoTypes) { Text($0.label).tag($0) }
                        }
                        Section("Audio") {
                            ForEach(MediaFileType.audioTypes) { Text($0.label).tag($0) }
                        }
                    }
                    Picker("Video quality", selection: $draft.preset.videoQuality) {
                        ForEach(VideoQuality.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(draft.preset.fileType.isAudio)
                    Picker("Audio quality", selection: $draft.preset.audioQuality) {
                        ForEach(AudioQuality.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section {
                    TextField("Subtitle languages", text: $languagesText, prompt: Text("en, ar, ja"))
                        .autocorrectionDisabled()
                    Toggle("Split by chapters", isOn: $draft.preset.splitChapters)
                } footer: {
                    SettingsFooter("Comma-separated language codes. Leave empty for no subtitles.")
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add Preset" : "Save") {
                    var result = draft
                    result.preset.subtitleLanguages = Self.parseLanguages(languagesText)
                    onSave(result)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding([.horizontal, .bottom], Tokens.space5)
        }
        .frame(width: 480, height: 600)
        .onAppear { languagesText = draft.preset.subtitleLanguages.joined(separator: ", ") }
    }

    static func parseLanguages(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Compact symbol picker: 8 × 2 grid of selectable SF Symbols.
private struct SymbolGrid: View {
    @Binding var selection: String
    var symbols: [String]

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 6), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(symbols, id: \.self) { symbol in
                SymbolCell(symbol: symbol, isSelected: symbol == selection) { selection = symbol }
            }
        }
        .fixedSize()
    }
}

private struct SymbolCell: View {
    var symbol: String
    var isSelected: Bool
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : .primary)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.radiusControl)
                        .fill(isSelected ? Color.parabolicAccent : Color.primary.opacity(isHovered ? 0.1 : 0.04))
                }
                .contentShape(.rect(cornerRadius: Tokens.radiusControl))
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Tokens.quick) { isHovered = hovering } }
        .accessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
