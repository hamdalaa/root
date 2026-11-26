import SwiftUI

/// The "New download" sheet: paste a link, inspect what's behind it, pick options, queue it.
struct AddDownloadSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var settings
    @Environment(ToolStore.self) private var tools
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model = AddDownloadModel()

    static let width: CGFloat = 640
    static let maxHeight: CGFloat = 720

    var body: some View {
        stageView
            .frame(width: Self.width)
            .animation(reduceMotion ? nil : Tokens.motion, value: model.stage.key)
            .onAppear(perform: start)
            .onDisappear { model.cancelDiscovery() }
            // Neutral glass: only the prominent action carries the system accent.
            .tint(nil)
    }

    @ViewBuilder
    private var stageView: some View {
        switch model.stage {
        case .input:
            AddInputStage(model: model, onContinue: discover, onCancel: close)
                .transition(.opacity)
        case .discovering(let host):
            AddDiscoveringStage(host: host) { model.cancelDiscovery() }
                .transition(.opacity)
        case .failed(let message):
            AddErrorStage(model: model, message: message, onRetry: discover, onCancel: close)
                .transition(.opacity)
        case .single:
            if let info = model.info {
                switch info.engine {
                case .direct:
                    FileDownloadView(model: model, info: info, onClose: close)
                        .transition(.opacity)
                case .torrent:
                    TorrentDownloadView(model: model, info: info, onClose: close)
                        .transition(.opacity)
                case .media:
                    SingleMediaView(model: model, info: info, onClose: close)
                        .transition(.opacity)
                }
            }
        case .playlist:
            if let info = model.info {
                PlaylistView(model: model, info: info, onClose: close)
                    .transition(.opacity)
            }
        }
    }

    private func start() {
        let preset = appState.addSheetURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preset.isEmpty, model.stage == .input, model.urlText.isEmpty else { return }
        model.urlText = preset
        // Tool paths resolve asynchronously at launch (Services refreshes the ToolStore in a Task).
        // Give that a moment so a link opened at launch doesn't fail with "yt-dlp isn't installed".
        Task {
            for _ in 0..<Self.toolWaitSteps where !tools.isReady {
                try? await Task.sleep(for: .milliseconds(100))
            }
            discover()
        }
    }

    private static let toolWaitSteps = 30

    private func discover() {
        let headers = Discovery.normalizeURL(model.urlText).flatMap { appState.browserHeaders(for: $0) }
        model.startDiscovery(prefs: settings.prefs, tools: tools.paths, headers: headers)
    }

    private func close() {
        model.cancelDiscovery()
        appState.addSheetURL = ""
        appState.isAddSheetPresented = false
        dismiss()
    }
}

// MARK: - Sheet header

/// Title block used at the top of the input and error stages.
struct AddSheetHeader: View {
    var title: String
    var subtitle: String
    var symbol: String
    var tint: Color = .parabolicAccent

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.space3) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.tint(tint.opacity(0.18)), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

extension AppState {
    /// Browser headers (cookies, referrer) for `url`, only when it is the link the extension handed over,
    /// never for a different link typed into the sheet afterwards.
    func browserHeaders(for url: String) -> [String: String]? {
        guard let headers = addSheetHeaders, !headers.isEmpty,
              let handedOver = Discovery.normalizeURL(addSheetURL), handedOver == Discovery.normalizeURL(url) else { return nil }
        return headers
    }
}
