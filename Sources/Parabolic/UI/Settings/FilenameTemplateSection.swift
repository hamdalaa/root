import SwiftUI

/// Filename template field with insertable token chips and a live example.
struct FilenameTemplateSection: View {
    @Environment(AppSettings.self) private var settings

    private struct Token: Identifiable {
        let value: String
        let label: String
        let sample: String
        var id: String { value }
    }

    private static let tokens: [Token] = [
        Token(value: "%(title)s", label: "Title", sample: "Northern Lights Timelapse"),
        Token(value: "%(uploader)s", label: "Uploader", sample: "Aurora Studio"),
        Token(value: "%(upload_date)s", label: "Upload date", sample: "20250314"),
        Token(value: "%(id)s", label: "Media ID", sample: "dQw4w9WgXcQ"),
        Token(value: "%(playlist_index)s", label: "Playlist index", sample: "03"),
    ]

    var body: some View {
        Section {
            LabeledContent("Template") {
                TextField("Template", text: settings.settingsBinding(\.filenameTemplate), prompt: Text("%(title)s"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 12, design: .monospaced))
                    .autocorrectionDisabled()
            }

            VStack(alignment: .leading, spacing: Tokens.space2) {
                Text("Insert")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                FlowRow(spacing: 6) {
                    ForEach(Self.tokens) { token in
                        TokenChip(label: token.label) { insert(token.value) }
                    }
                }
            }
            .padding(.vertical, 2)

            LabeledContent("Example") {
                Text(example)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }

            Toggle("Restrict filenames to ASCII characters", isOn: settings.settingsBinding(\.limitFilenameCharacters))
            Toggle("Include media ID in filename", isOn: settings.settingsBinding(\.includeMediaIDInTitle))
        } header: {
            Text("File names")
        } footer: {
            SettingsFooter("Tokens are yt-dlp output template fields. Restricting characters swaps spaces and symbols for underscores, which helps with older file systems and scripts.")
        }
    }

    private func insert(_ token: String) {
        let current = settings.prefs.filenameTemplate
        let separator = current.isEmpty || current.hasSuffix(" ") || current.hasSuffix("-") ? "" : " - "
        settings.setPref(\.filenameTemplate, current + separator + token)
    }

    private var example: String {
        let prefs = settings.prefs
        var name = prefs.filenameTemplate.isEmpty ? "%(title)s" : prefs.filenameTemplate
        if prefs.includeMediaIDInTitle, !name.contains("%(id)s") { name += " [%(id)s]" }
        for token in Self.tokens { name = name.replacingOccurrences(of: token.value, with: token.sample) }
        if prefs.limitFilenameCharacters {
            name = String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.[]".contains($0)) ? $0 : "_" })
        }
        let ext = prefs.lastUsedFileType.fileExtension ?? "mp4"
        let folder = prefs.organizeByUploader ? "Aurora Studio/" : ""
        return folder + name + "." + ext
    }
}

/// Small tappable capsule that inserts a template token.
private struct TokenChip: View {
    var label: String
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                Text(label)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isHovered ? Color.parabolicAccent : .primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(isHovered ? 0.1 : 0.06), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Tokens.quick) { isHovered = hovering } }
        .accessibilityLabel("Insert \(label) token")
    }
}

/// Minimal wrapping row layout for chips.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows.removeLast()
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows.append(row)
        }
        return rows
    }
}
