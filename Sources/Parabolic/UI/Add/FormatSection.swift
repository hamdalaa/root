import SwiftUI

/// Format card for a single item: type, quality and the advanced exact-format pickers.
struct FormatSection: View {
    @Bindable var model: AddDownloadModel
    var info: MediaInfo

    private var hasExactFormats: Bool { !info.videoFormats.isEmpty || !info.audioOnlyFormats.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space2) {
            SmartDefaultNote(model: model)
            card
        }
    }

    private var card: some View {
        GroupCard(title: "Format", footer: footer) {
            FormatRows(options: $model.options, qualities: model.availableQualities, onUserChange: model.markFormatTouched)
            if hasExactFormats {
                Divider().padding(.horizontal, 14)
                ExpandableRow(title: "Advanced format selection", summary: advancedSummary,
                              symbol: "slider.horizontal.3", isExpanded: $model.showAdvancedFormats) {
                    advancedRows
                }
            }
        }
    }

    private var footer: String? {
        if let id = model.options.videoFormatID, !model.isAudio, info.videoFormats.contains(where: { $0.id == id }) {
            return "Exact format \(id) overrides the quality setting."
        }
        if info.availableHeights.isEmpty, !model.isAudio {
            return "This site didn't list its resolutions, so every quality is shown."
        }
        return nil
    }

    private var advancedSummary: String {
        var parts: [String] = []
        if !model.isAudio, let id = model.options.videoFormatID { parts.append("Video \(id)") }
        if let id = model.options.audioFormatID { parts.append("Audio \(id)") }
        return parts.isEmpty ? "Automatic" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var advancedRows: some View {
        if !model.isAudio, !info.videoFormats.isEmpty {
            GroupRow(title: "Video format", subtitle: "\(info.videoFormats.count) available", symbol: "film.stack") {
                Picker("Video format", selection: $model.options.videoFormatID) {
                    Text("Automatic").tag(String?.none)
                    Divider()
                    ForEach(info.videoFormats) { format in
                        Text(Self.title(for: format)).tag(Optional(format.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 300)
                .accessibilityLabel("Exact video format")
            }
        }
        if !info.audioOnlyFormats.isEmpty {
            GroupRow(title: "Audio format", subtitle: "\(info.audioOnlyFormats.count) available", symbol: "waveform.badge.magnifyingglass",
                     showsDivider: false) {
                Picker("Audio format", selection: $model.options.audioFormatID) {
                    Text("Automatic").tag(String?.none)
                    Divider()
                    ForEach(info.audioOnlyFormats) { format in
                        Text(Self.title(for: format)).tag(Optional(format.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 300)
                .accessibilityLabel("Exact audio format")
            }
        }
    }

    static func title(for format: MediaFormat) -> String {
        guard let size = format.filesize, size > 0 else { return format.summary }
        return "\(format.summary) — \(Format.bytes(size))"
    }
}

/// Quiet notice when the format was chosen for the user, with Undo.
struct SmartDefaultNote: View {
    @Bindable var model: AddDownloadModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let note = model.smartDefaultNote {
                HStack(spacing: Tokens.space2) {
                    PlatformGlyph(platform: model.platform, size: 13)
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: Tokens.space2)
                    Button("Undo") {
                        withAnimation(reduceMotion ? nil : Tokens.quick) { model.undoSmartDefault() }
                    }
                    .buttonStyle(.hover)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.parabolicAccent)
                    .accessibilityHint("Goes back to your usual format")
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 3)
                .background(.primary.opacity(0.04), in: .rect(cornerRadius: Tokens.radiusControl + 2))
                .overlay(RoundedRectangle(cornerRadius: Tokens.radiusControl + 2).strokeBorder(.primary.opacity(0.06)))
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(reduceMotion ? nil : Tokens.quick, value: model.smartDefaultNote)
    }
}

/// Subtitle card: searchable multi-select over the languages the site offers.
struct SubtitlesSection: View {
    @Bindable var model: AddDownloadModel
    var info: MediaInfo

    @State private var expanded = false
    @State private var query = ""

    private var choices: [String] {
        let all = model.subtitleChoices(includeAuto: model.options.includeAutoSubtitles)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(trimmed) || $0.subtitleDisplayName.localizedCaseInsensitiveContains(trimmed) }
    }

    private var summary: String {
        let picked = model.options.subtitleLanguages
        if picked.isEmpty { return "None" }
        let names = picked.prefix(3).map(\.subtitleDisplayName).joined(separator: ", ")
        return picked.count > 3 ? "\(names) and \(picked.count - 3) more" : names
    }

    var body: some View {
        GroupCard(title: "Subtitles") {
            ExpandableRow(title: "Languages", summary: summary, symbol: "captions.bubble", isExpanded: $expanded) {
                VStack(spacing: Tokens.space2) {
                    searchField
                    languageList
                }
                .padding(.horizontal, 14)
                .padding(.bottom, Tokens.space2)
                if !info.autoCaptionLanguages.isEmpty {
                    Divider().padding(.leading, 44).padding(.trailing, 14)
                }
            }
            if !info.autoCaptionLanguages.isEmpty {
                if !expanded { Divider().padding(.leading, 44).padding(.trailing, 14) }
                GroupRow(title: "Include auto-generated", subtitle: "Adds machine captions to the list.",
                         symbol: "wand.and.sparkles", showsDivider: false) {
                    Toggle("Include auto-generated", isOn: $model.options.includeAutoSubtitles)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
            }
        }
        .onChange(of: model.options.includeAutoSubtitles) { _, includeAuto in
            guard !includeAuto else { return }
            let allowed = Set(info.subtitleLanguages)
            model.options.subtitleLanguages.removeAll { !allowed.contains($0) }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary).accessibilityHidden(true)
            TextField("Search languages", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search subtitle languages")
            if !model.options.subtitleLanguages.isEmpty {
                Button("Clear") { model.options.subtitleLanguages.removeAll() }
                    .buttonStyle(.hover)
                    .font(.system(size: 11))
                    .accessibilityLabel("Clear selected subtitle languages")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: Tokens.radiusControl))
    }

    private var languageList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                if choices.isEmpty {
                    Text(query.isEmpty ? "Only auto-generated captions are available. Turn them on below." : "No languages match “\(query)”.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, Tokens.space3)
                }
                ForEach(choices, id: \.self) { code in
                    LanguageRow(code: code, isAuto: !info.subtitleLanguages.contains(code),
                                isSelected: model.options.subtitleLanguages.contains(code)) {
                        model.toggleSubtitle(code)
                    }
                }
            }
        }
        .frame(height: min(CGFloat(max(choices.count, 1)) * 28 + 4, 196))
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct LanguageRow: View {
    var code: String
    var isAuto: Bool
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.space2) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.parabolicAccent : Color.secondary.opacity(0.6))
                    .font(.system(size: 13))
                Text(code.subtitleDisplayName).font(.system(size: 12))
                if isAuto {
                    Text("Auto").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                }
                Spacer()
                Text(code).font(.system(size: 11).monospaced()).foregroundStyle(.tertiary)
            }
            .frame(height: 20)
            .contentShape(.rect)
        }
        .buttonStyle(HoverButtonStyle(cornerRadius: 6, padding: 4))
        .accessibilityLabel(code.subtitleDisplayName + (isAuto ? ", auto-generated" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
