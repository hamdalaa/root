import AppKit
import SwiftUI

/// Quiet inline note when a link was downloaded before: "You downloaded this on 12 Oct", with a way to the file.
struct DuplicateNotice: View {
    let entry: HistoryEntry
    var compact = false

    private var existingFile: URL? {
        guard let path = entry.filePath, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private var dateText: String {
        let sameYear = Calendar.current.isDate(entry.date, equalTo: .now, toGranularity: .year)
        return sameYear ? entry.date.formatted(.dateTime.day().month(.wide))
                        : entry.date.formatted(.dateTime.day().month(.wide).year())
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("You downloaded this on \(dateText)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                if existingFile == nil, entry.filePath != nil {
                    Text("The file is no longer where it was saved.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            if let file = existingFile {
                Button("Show existing file") {
                    FinderReveal.reveal([file])
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help(file.path)
            }
        }
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, compact ? 7 : 9)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.06)))
        .accessibilityElement(children: .contain)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// Shows a `DuplicateNotice` when any of these links is already in the download history.
struct DuplicateNoticeSlot: View {
    @Environment(HistoryStore.self) private var history
    let urls: [String?]

    var body: some View {
        if let entry = urls.compactMap({ $0 }).filter({ !$0.isEmpty }).lazy.compactMap(history.previous(for:)).first {
            DuplicateNotice(entry: entry)
        }
    }
}
