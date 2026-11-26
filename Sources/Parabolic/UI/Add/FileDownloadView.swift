import SwiftUI

/// Stage 4 for a plain file link (aria2): a file card instead of media options.
struct FileDownloadView: View {
    @Bindable var model: AddDownloadModel
    var info: MediaInfo
    var onClose: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var manager
    @Environment(ClipboardWatcher.self) private var clipboard
    @Environment(AppState.self) private var appState

    private var file: DirectFileInfo {
        info.directFile ?? DirectFileInfo(filename: info.meta.title, size: nil, contentType: nil, resumable: false)
    }

    private var trimmedName: String { model.options.filename.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// What the file will be called on disk: the typed name, else the server's.
    private var effectiveName: String { trimmedName.isEmpty ? file.filename : trimmedName }

    var body: some View {
        VStack(spacing: 0) {
            AdaptiveScroll(maxHeight: AddDownloadSheet.maxHeight - EngineSheetBar.height) {
                VStack(alignment: .leading, spacing: Tokens.space5) {
                    EngineHero(symbol: FileArtwork.symbol(forFilename: effectiveName),
                               caption: FileArtwork.extensionLabel(forFilename: effectiveName),
                               title: effectiveName, host: info.meta.uploader, onBack: model.backToInput) {
                        Chip(text: Format.bytes(file.size) == "—" ? "Size unknown" : Format.bytes(file.size), symbol: "internaldrive")
                        if let type = Self.shortType(file.contentType) {
                            Chip(text: type, symbol: "doc.text.magnifyingglass")
                                .help(file.contentType ?? "")
                        }
                        if file.resumable {
                            Chip(text: "Resumable", symbol: "arrow.clockwise", tint: .green)
                                .help("The server supports ranged requests, so a paused or interrupted download picks up where it stopped.")
                        }
                    }
                    DuplicateNoticeSlot(urls: [model.options.url, info.meta.webpageURL])
                    saveCard
                }
                .padding(.horizontal, Tokens.space5)
                .padding(.top, Tokens.space5)
                .padding(.bottom, Tokens.space4)
            }
            EngineSheetBar(title: "File size", value: file.size.map { Format.bytes($0) } ?? "Unknown",
                           startLater: model.startLater, onCancel: onClose, onDownload: download)
        }
    }

    private var saveCard: some View {
        GroupCard(title: "Save", footer: "Connections apply to every file download. Change the default in Browser settings.") {
            GroupRow(title: "Name", symbol: "character.cursor.ibeam") {
                TextField("Filename", text: $model.options.filename, prompt: Text(file.filename))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .accessibilityLabel("Filename")
            }
            FolderRow(path: $model.options.saveFolder)
            ConnectionsRow()
            ScheduleRows(startLater: $model.startLater, date: $model.scheduledAt)
        }
    }

    /// "application/zip; charset=…" → "application/zip".
    static func shortType(_ contentType: String?) -> String? {
        guard let base = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces), !base.isEmpty else { return nil }
        return base
    }

    private func download() {
        var options = model.options
        options.engine = .direct
        options.filename = ArgumentBuilder.sanitize(trimmedName)
        options.httpHeaders = appState.browserHeaders(for: options.url)
        var meta = info.meta
        meta.title = options.filename.isEmpty ? file.filename : options.filename
        meta.extractor = "File"
        manager.enqueue(options: options, meta: meta, scheduledAt: model.startLater ? model.scheduledAt : nil)
        clipboard.markSeen(options.url)
        clipboard.markSeen(model.urlText.trimmingCharacters(in: .whitespacesAndNewlines))
        onClose()
    }
}

/// Stage 4 for a magnet link or .torrent file.
struct TorrentDownloadView: View {
    @Bindable var model: AddDownloadModel
    var info: MediaInfo
    var onClose: () -> Void

    @Environment(DownloadManager.self) private var manager
    @Environment(ClipboardWatcher.self) private var clipboard

    private var isMagnet: Bool { model.options.url.lowercased().hasPrefix("magnet:") }

    /// Magnet `dn=` values often encode spaces as "+", which URLComponents leaves alone.
    private var name: String {
        isMagnet ? info.meta.title.replacingOccurrences(of: "+", with: " ") : info.meta.title
    }

    /// The 40-character info-hash of a magnet link, shortened for display.
    private var shortHash: String? {
        let items = URLComponents(string: model.options.url)?.queryItems ?? []
        guard let xt = items.first(where: { $0.name == "xt" })?.value, let hash = xt.split(separator: ":").last else { return nil }
        return String(hash.prefix(8)).lowercased()
    }

    var body: some View {
        VStack(spacing: 0) {
            AdaptiveScroll(maxHeight: AddDownloadSheet.maxHeight - EngineSheetBar.height) {
                VStack(alignment: .leading, spacing: Tokens.space5) {
                    EngineHero(symbol: FileArtwork.torrentSymbol, caption: nil, title: name,
                               host: isMagnet ? "Magnet link" : "Torrent file", hostSymbol: isMagnet ? "link" : "doc",
                               onBack: model.backToInput) {
                        Chip(text: "Torrent", symbol: "arrow.down.circle")
                        if let shortHash {
                            Chip(text: shortHash, symbol: "number")
                                .help("Info-hash")
                        }
                    }
                    DuplicateNoticeSlot(urls: [model.options.url])
                    GroupCard(title: "Save", footer: "Root downloads the torrent's files and stops sharing as soon as they finish.") {
                        FolderRow(path: $model.options.saveFolder)
                        ConnectionsRow()
                        ScheduleRows(startLater: $model.startLater, date: $model.scheduledAt)
                    }
                }
                .padding(.horizontal, Tokens.space5)
                .padding(.top, Tokens.space5)
                .padding(.bottom, Tokens.space4)
            }
            EngineSheetBar(title: "Size", value: "Known once peers connect",
                           startLater: model.startLater, onCancel: onClose, onDownload: download)
        }
    }

    private func download() {
        var options = model.options
        options.engine = .torrent
        options.filename = ""
        var meta = info.meta
        meta.title = name
        meta.extractor = "Torrent"
        manager.enqueue(options: options, meta: meta, scheduledAt: model.startLater ? model.scheduledAt : nil)
        clipboard.markSeen(options.url)
        clipboard.markSeen(model.urlText.trimmingCharacters(in: .whitespacesAndNewlines))
        onClose()
    }
}

// MARK: - Shared pieces

/// Big symbol tile beside the name, the source and a row of chips.
struct EngineHero<Chips: View>: View {
    var symbol: String
    var caption: String?
    var title: String
    var host: String?
    var hostSymbol = "globe"
    var onBack: () -> Void
    @ViewBuilder var chips: Chips

    private var tile: CGSize { CGSize(width: 120, height: 120) }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.space4) {
            EngineArtworkTile(symbol: symbol, caption: caption, size: tile, cornerRadius: 24)
                .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                .contentTransition(.symbolEffect(.replace))
                .animation(Tokens.motion, value: symbol)

            VStack(alignment: .leading, spacing: Tokens.space2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                if let host {
                    Label(host, systemImage: hostSymbol)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    chips
                    Spacer(minLength: 0)
                    Button(action: onBack) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.hover)
                    .help("Use a different link")
                    .accessibilityLabel("Use a different link")
                }
            }
            .frame(maxWidth: .infinity, minHeight: tile.height, maxHeight: tile.height, alignment: .topLeading)
        }
    }
}

/// Connections per file, stored in preferences (the aria2 split count).
struct ConnectionsRow: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let connections = settings.settingsBinding(\.directConnections)
        GroupRow(title: "Connections", subtitle: "More connections finish large files faster.",
                 symbol: "point.3.filled.connected.trianglepath.dotted") {
            Stepper(value: connections, in: 1...16) {
                Text("\(connections.wrappedValue)")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .fixedSize()
            .accessibilityLabel("Connections per file")
            .accessibilityValue("\(connections.wrappedValue)")
        }
    }
}

/// Bottom bar for the file and torrent cards: one fact on the left, Cancel and Download on the right.
struct EngineSheetBar: View {
    static let height: CGFloat = 72

    var title: String
    var value: String
    var startLater: Bool
    var onCancel: () -> Void
    var onDownload: () -> Void

    var body: some View {
        SheetBottomBar {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 13, weight: .medium).monospacedDigit())
            }
            .accessibilityElement(children: .combine)
        } trailing: {
            Button("Cancel", role: .cancel, action: onCancel)
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Button(action: onDownload) {
                Label(startLater ? "Schedule" : "Download", systemImage: startLater ? "calendar.badge.clock" : "arrow.down")
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(startLater ? "Adds the download to the queue for later" : "Starts the download")
        }
        .controlSize(.large)
    }
}
