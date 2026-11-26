import AppKit
import SwiftUI

/// Trailing inspector for the single selected download, with placeholders for none / many.
struct DownloadInspector: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(AppState.self) private var appState
    @Environment(ConversionStore.self) private var conversions

    var body: some View {
        let selected = manager.items(appState.selectedItemIDs)
        let screen = appState.sidebarSelection
        Group {
            if !screen.showsDownloads {
                ContentUnavailableView(screen.title, systemImage: screen.symbol,
                                       description: Text("Pick a download from the Downloads lists to inspect it."))
            } else if selected.count == 1, let item = selected.first {
                InspectorDetail(item: item,
                                actions: DownloadActions(manager: manager, appState: appState, conversions: conversions),
                                isVisible: appState.showInspector)
                    .id(item.id)
            } else if selected.count > 1 {
                multiSelection(selected)
            } else {
                ContentUnavailableView("No Selection", systemImage: "sidebar.trailing",
                                       description: Text("Select a download to see its details, options and log."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func multiSelection(_ items: [DownloadItem]) -> some View {
        let total = items.compactMap(\.totalBytes).reduce(0, +)
        let active = items.filter { $0.status.isActive }.count
        var parts = ["\(Format.bytes(total)) in total"]
        if active > 0 { parts.append("\(active) active") }
        return ContentUnavailableView {
            Label("\(items.count) Downloads Selected", systemImage: "square.stack")
        } description: {
            Text(parts.joined(separator: " · ") + ". Right-click to act on all of them at once.")
        }
    }
}

/// The full inspector for one item.
struct InspectorDetail: View {
    let item: DownloadItem
    let actions: DownloadActions
    var isVisible = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.space5) {
                header
                InspectorStats(item: item)
                InspectorOptions(item: item)
                if let url = item.completedFileURL, InspectorChecksum.canHash(url) {
                    InspectorChecksum(path: url.path)
                }
                if let error = item.errorMessage, !error.isEmpty {
                    errorBox(error)
                }
                InspectorLogView(item: item)
            }
            .padding(Tokens.space4)
        }
        .scrollContentBackground(.hidden)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            media

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let uploader = item.meta.uploader, !uploader.isEmpty {
                    Text(uploader)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                platformChip
                Chip(text: item.status.label, symbol: item.status.symbol, tint: statusTint)
                if item.meta.isLive {
                    Chip(text: "Live", symbol: "dot.radiowaves.left.and.right", tint: .red)
                }
                Spacer(minLength: 0)
            }

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button { actions.openSourcePages([item]) } label: {
                        Label("Open Page", systemImage: "arrow.up.right")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.glass)
                    .help(item.sourceURL)
                    if item.completedFileURL != nil {
                        if isMediaFile { convertMenu }
                        Button { actions.reveal([item]) } label: {
                            Label("Show in Finder", systemImage: "folder")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.glass)
                        .help("Show in Finder")
                    }
                }
            }
        }
    }

    /// The built-in player for finished files on disk; artwork otherwise.
    @ViewBuilder private var media: some View {
        if isVisible, let url = item.completedFileURL, isMediaFile {
            InspectorPlayer(url: url, isAudio: item.options.fileType.isAudio || ConversionTarget.isAudioFile(url),
                            artworkURL: item.meta.thumbnailURL)
        } else {
            InspectorArtwork(item: item)
        }
    }

    /// Media always plays; plain files and torrents only when the result is audio or video.
    private var isMediaFile: Bool {
        guard item.engine != .media else { return true }
        return item.completedFileURL.map(FileArtwork.isPlayable) ?? false
    }

    private var platformChip: some View {
        HStack(spacing: 5) {
            if let symbol = item.engineSymbol, !item.showsPlatformBadge {
                Image(systemName: symbol).imageScale(.small)
            } else {
                PlatformGlyph(platform: item.platform, size: 12)
            }
            Text(item.showsPlatformBadge ? item.platform.title : item.kindTitle)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.primary.opacity(0.07), in: .capsule)
        .accessibilityElement(children: .combine)
    }

    private var convertMenu: some View {
        Menu {
            ForEach(ConversionTarget.allCases) { target in
                Button { actions.convert([item], to: target) } label: { Label(target.label, systemImage: target.symbol) }
            }
        } label: {
            Label("Convert…", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .help("Convert this file with ffmpeg")
    }

    private var statusTint: Color? {
        switch item.status {
        case .queued, .scheduled, .stopped: nil
        default: Color.status(item.status)
        }
    }

    private func errorBox(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Download failed")
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.space3)
        .glassPanel(cornerRadius: 12, tint: .red.opacity(0.14))
        .accessibilityElement(children: .combine)
    }
}

/// Two-column grid of live numbers.
struct InspectorStats: View {
    let item: DownloadItem

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Tokens.space4, verticalSpacing: Tokens.space3) {
            GridRow {
                cell("Size", item.sizeDescription ?? "—")
                cell("Speed", item.status == .running ? Format.speed(item.speed) : "—")
            }
            GridRow {
                cell("Time left", eta)
                cell("Attempts", "\(item.attempts)")
            }
            GridRow {
                cell("Added", LinkText.finished(item.addedAt))
                cell("Finished", item.finishedAt.map(LinkText.finished) ?? "—")
            }
        }
        .padding(Tokens.space3 + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: Tokens.radiusRow)
    }

    private var eta: String {
        let text = Format.eta(item.eta)
        return text.isEmpty ? "—" : text.replacingOccurrences(of: " left", with: "")
    }

    private func cell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// What was asked for: type, quality, subtitles, time frame and where it goes.
struct InspectorOptions: View {
    let item: DownloadItem
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let options = item.options
        GroupCard(title: "Options") {
            GroupRow(title: "Engine", symbol: engineSymbol) { value(engineName) }
            if item.engine == .media {
                GroupRow(title: "Type", symbol: options.fileType.symbol) { value(options.fileType.label) }
                GroupRow(title: "Quality", symbol: "dial.medium") { value(quality) }
                GroupRow(title: "Subtitles", symbol: "captions.bubble") { value(subtitles) }
                GroupRow(title: "Time frame", symbol: "timeline.selection") { value(timeFrame) }
            } else {
                GroupRow(title: "Connections", symbol: "point.3.filled.connected.trianglepath.dotted") {
                    value("\(settings.prefs.directConnections)")
                }
                GroupRow(title: "Browser session", symbol: "globe") { value(browserSession) }
            }
            GroupRow(title: "Folder", symbol: "folder") {
                HStack(spacing: 4) {
                    value((options.saveFolder as NSString).lastPathComponent)
                        .help(options.saveFolder)
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: options.saveFolder, isDirectory: true))
                    } label: {
                        Image(systemName: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open folder in Finder")
                    .accessibilityLabel("Open folder in Finder")
                }
            }
            GroupRow(title: "File", symbol: "doc", showsDivider: false) {
                value(item.filePath.map { ($0 as NSString).lastPathComponent } ?? "Not saved yet")
                    .help(item.filePath ?? "")
                    .textSelection(.enabled)
            }
        }
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var engineSymbol: String {
        switch item.engine {
        case .media: "play.rectangle"
        case .direct: "arrow.down.doc"
        case .torrent: FileArtwork.torrentSymbol
        }
    }

    private var engineName: String {
        switch item.engine {
        case .media: "Media (yt-dlp)"
        case .direct: "File (aria2, segmented)"
        case .torrent: "Torrent (aria2)"
        }
    }

    /// Whether the browser's referrer / user agent travel with the request (cookies are never stored).
    private var browserSession: String {
        guard let headers = item.options.httpHeaders, !headers.isEmpty else { return "None" }
        return headers["Cookie"] != nil ? "Cookies, referrer" : "Referrer, user agent"
    }

    private var quality: String {
        let options = item.options
        if options.fileType.isAudio {
            return options.audioFormatID.map { "Format \($0)" } ?? options.audioQuality.label
        }
        return options.videoFormatID.map { "Format \($0)" } ?? options.videoQuality.label
    }

    private var subtitles: String {
        var parts = item.options.subtitleLanguages.map { $0.uppercased() }
        if item.options.includeAutoSubtitles { parts.append("auto") }
        return parts.isEmpty ? "None" : parts.joined(separator: ", ")
    }

    private var timeFrame: String {
        guard let frame = item.options.timeFrame else { return "Full length" }
        let start = Format.duration(frame.start) ?? "0:00"
        let end = Format.duration(frame.end) ?? "0:00"
        return "\(start) – \(end)"
    }
}
