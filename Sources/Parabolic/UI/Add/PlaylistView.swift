import SwiftUI

/// Stage 5: a playlist or channel. Pick entries, set shared options, queue them all (now or later),
/// or follow it so new uploads arrive on their own.
struct PlaylistView: View {
    @Bindable var model: AddDownloadModel
    var info: MediaInfo
    var onClose: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var manager
    @Environment(ClipboardWatcher.self) private var clipboard
    @Environment(AppState.self) private var appState
    /// Handoff to AddSubscriptionSheet, which reads and clears it on appear.
    @AppStorage("pendingSubscriptionURL") private var pendingSubscriptionURL = ""

    private static let barHeight: CGFloat = 72
    /// Lets this sheet finish dismissing before the subscription sheet is presented.
    private static let sheetHandoffDelay: Duration = .milliseconds(450)
    private var selectedCount: Int { model.selectedEntryIDs.count }

    var body: some View {
        VStack(spacing: 0) {
            AdaptiveScroll(maxHeight: AddDownloadSheet.maxHeight - Self.barHeight) {
                VStack(alignment: .leading, spacing: Tokens.space5) {
                    PlaylistHeader(meta: info.meta, platform: model.platform, count: info.entries.count,
                                   onFollow: follow) { model.backToInput() }
                    PlaylistEntriesCard(model: model, info: info)
                    VStack(alignment: .leading, spacing: Tokens.space2) {
                        SmartDefaultNote(model: model)
                        GroupCard(title: "Format") {
                            FormatRows(options: $model.options, qualities: VideoQuality.allCases,
                                       onUserChange: model.markFormatTouched)
                        }
                    }
                    PlaylistSubtitlesCard(model: model)
                    PlaylistSaveCard(model: model, credentials: settings.prefs.credentials)
                }
                .padding(.horizontal, Tokens.space5)
                .padding(.top, Tokens.space5)
                .padding(.bottom, Tokens.space4)
            }
            bottomBar
        }
    }

    private var bottomBar: some View {
        SheetBottomBar {
            Text("\(selectedCount) of \(info.entries.count) selected")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        } trailing: {
            Button("Cancel", role: .cancel, action: onClose)
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Button(action: download) {
                Label(primaryTitle, systemImage: model.startLater ? "calendar.badge.clock" : "arrow.down")
                    .monospacedDigit()
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedCount == 0)
            .accessibilityHint(model.startLater ? "Queues every selected video to start later" : "Adds every selected video to the queue")
        }
        .controlSize(.large)
    }

    private var primaryTitle: String {
        let noun = selectedCount == 1 ? "1 item" : "\(selectedCount) items"
        return model.startLater ? "Schedule \(noun)" : "Download \(noun)"
    }

    private func download() {
        let entries = model.selectedEntries
        guard !entries.isEmpty else { return }
        let total = info.entries.map(\.index).max() ?? entries.count
        let startAt = model.startLater ? model.scheduledAt : nil
        let headers = model.normalizedURL.flatMap { appState.browserHeaders(for: $0) }
        // The manager starts the oldest queued item first, so enqueue in playlist order.
        for entry in entries {
            var options = model.options(for: entry, playlistTitle: info.meta.title, totalCount: total)
            options.httpHeaders = headers
            let meta = MediaMeta(title: entry.title, uploader: entry.uploader ?? info.meta.uploader, duration: entry.duration,
                                 thumbnailURL: entry.thumbnailURL, webpageURL: entry.sourceURL ?? entry.url, extractor: info.meta.extractor)
            manager.enqueue(options: options, meta: meta, scheduledAt: startAt)
        }
        settings.prefs.lastUsedFileType = model.options.fileType
        settings.prefs.lastUsedVideoQuality = model.options.videoQuality
        settings.prefs.lastUsedAudioQuality = model.options.audioQuality
        if let url = model.normalizedURL { clipboard.markSeen(url) }
        clipboard.markSeen(model.urlText.trimmingCharacters(in: .whitespacesAndNewlines))
        onClose()
    }

    private func follow() {
        pendingSubscriptionURL = model.normalizedURL ?? model.urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = appState
        onClose()
        Task { @MainActor in
            try? await Task.sleep(for: Self.sheetHandoffDelay)
            state.isAddSubscriptionPresented = true
        }
    }
}

// MARK: - Header

private struct PlaylistHeader: View {
    var meta: MediaMeta
    var platform: Platform
    var count: Int
    var onFollow: () -> Void
    var onBack: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.space4) {
            ThumbnailView(url: meta.thumbnailURL, size: CGSize(width: 192, height: 108), symbol: "rectangle.stack")
                .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(meta.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: Tokens.space2)
                    Button(action: onBack) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.hover)
                    .help("Use a different link")
                    .accessibilityLabel("Use a different link")
                }
                if let uploader = meta.uploader {
                    Text(uploader).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    HeroPlatformChip(platform: platform, fallback: meta.extractor)
                    Chip(text: count == 1 ? "1 video" : "\(count) videos", symbol: "rectangle.stack")
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Button(action: onFollow) {
                        Label("Follow", systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.glass)
                    .help("Follow this channel and download new uploads automatically")
                    .accessibilityLabel("Follow this channel")
                    .accessibilityHint("Opens subscription options for this link")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 108, maxHeight: 108, alignment: .topLeading)
        }
    }
}

// MARK: - Shared option cards

private struct PlaylistSubtitlesCard: View {
    @Bindable var model: AddDownloadModel

    var body: some View {
        GroupCard(title: "Subtitles", footer: "Language codes separated by commas, like en, ar, fr. Leave empty for none.") {
            GroupRow(title: "Languages", symbol: "captions.bubble") {
                TextField("Languages", text: $model.playlistSubtitleText, prompt: Text("None"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13).monospaced())
                    .frame(width: 200)
                    .accessibilityLabel("Subtitle languages, comma separated")
            }
            GroupRow(title: "Include auto-generated", subtitle: "Starts from your choice in Settings.",
                     symbol: "wand.and.sparkles", showsDivider: false) {
                Toggle("Include auto-generated", isOn: $model.options.includeAutoSubtitles)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
    }
}

private struct PlaylistSaveCard: View {
    @Bindable var model: AddDownloadModel
    var credentials: [Credential]

    var body: some View {
        GroupCard(title: "Save") {
            FolderRow(path: $model.options.saveFolder)
            GroupRow(title: "Put in a subfolder named after the playlist", symbol: "folder.badge.plus") {
                Toggle("Put in a subfolder named after the playlist", isOn: $model.playlistSubfolder)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            GroupRow(title: "Number files by playlist position", subtitle: "Names files like “01 - Title”.",
                     symbol: "list.number") {
                Toggle("Number files by playlist position", isOn: $model.numberFiles)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            if !credentials.isEmpty {
                CredentialPicker(credentials: credentials, selection: $model.credentialID)
            }
            ScheduleRows(startLater: $model.startLater, date: $model.scheduledAt)
        }
    }
}
