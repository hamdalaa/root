import SwiftUI

/// "Follow a channel" sheet. Presented by the main window via `appState.isAddSubscriptionPresented`.
/// Pre-fills from `@AppStorage("pendingSubscriptionURL")`, which the add-download sheet sets.
struct AddSubscriptionSheet: View {
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(AppSettings.self) private var settings
    @Environment(ToolStore.self) private var tools
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("pendingSubscriptionURL") private var pendingURL = ""

    @State private var url = ""
    @State private var presetID: UUID?
    @State private var autoDownload = true
    @State private var downloadLatest = 0
    @State private var isAdding = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    static let width: CGFloat = 520
    private static let latestRange = 0...10

    private var platform: Platform { Platform.detect(url: url) }
    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Tokens.space5) {
                header
                VStack(alignment: .leading, spacing: Tokens.space2) {
                    PlatformLinkField(text: $url, prompt: "youtube.com/@channel", hasError: error != nil, onSubmit: add)
                        .disabled(isAdding)
                        .onChange(of: url) { error = nil }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, Tokens.space4)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .accessibilityLabel("Error: \(error)")
                    }
                }
                .animation(reduceMotion ? nil : Tokens.quick, value: error)
                options
                    .disabled(isAdding)
            }
            .padding(Tokens.space5)
            bottomBar
        }
        .frame(width: Self.width)
        .onAppear(perform: prefill)
        .onDisappear { task?.cancel() }
        // Neutral glass: only the prominent action carries the system accent.
        .tint(nil)
    }

    private var header: some View {
        HStack(spacing: Tokens.space3) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Color.parabolicAccent)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.tint(Color.parabolicAccent.opacity(0.18)), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Follow a channel")
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Paste a channel, playlist or profile link. New uploads arrive on their own.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var options: some View {
        GroupCard {
            GroupRow(title: "Preset", subtitle: "Format used for new uploads.", symbol: "slider.horizontal.3") {
                Picker("Preset", selection: $presetID) {
                    Text("Platform default (\(settings.prefs.preset(for: platform).name))").tag(UUID?.none)
                    Divider()
                    ForEach(settings.prefs.allPresets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Preset")
            }
            GroupRow(title: "Download new uploads automatically",
                     subtitle: autoDownload ? nil : "New uploads are counted so you can pick them yourself.",
                     symbol: "arrow.down.circle") {
                Toggle("Download new uploads automatically", isOn: $autoDownload)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            GroupRow(title: "Also download the latest",
                     subtitle: downloadLatest == 0 ? "Only uploads from now on." : (downloadLatest == 1 ? "The newest upload, right away." : "The \(downloadLatest) newest uploads, right away."),
                     symbol: "clock.arrow.circlepath", showsDivider: false) {
                Stepper(value: $downloadLatest, in: Self.latestRange) {
                    Text("\(downloadLatest)")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .frame(minWidth: 18, alignment: .trailing)
                        .contentTransition(.numericText())
                }
                .accessibilityLabel("Also download the latest")
                .accessibilityValue("\(downloadLatest) uploads")
            }
        }
    }

    private var bottomBar: some View {
        SheetBottomBar {
            if isAdding {
                HStack(spacing: Tokens.space2) {
                    ProgressView().controlSize(.small)
                    Text("Reading \(platform == .other ? "the channel" : platform.title)…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else if !tools.isReady {
                Label("Install yt-dlp in Settings first.", systemImage: "shippingbox")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } trailing: {
            Button("Cancel", role: .cancel, action: close)
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Button(action: add) {
                Label("Follow", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(trimmedURL.isEmpty || isAdding || !tools.isReady)
        }
        .controlSize(.large)
    }

    // MARK: Actions

    private func prefill() {
        guard !pendingURL.isEmpty else { return }
        url = pendingURL
        pendingURL = ""
    }

    private func add() {
        guard !isAdding, !trimmedURL.isEmpty else { return }
        guard let normalized = Discovery.normalizeURL(trimmedURL) else {
            error = "That doesn't look like a link. Try something like youtube.com/@channel."
            return
        }
        let feed = SubscriptionStore.channelFeedURL(normalized)
        if subscriptions.subscriptions.contains(where: { $0.url == feed }) {
            error = "You already follow this."
            return
        }
        error = nil
        isAdding = true
        let (preset, auto, latest) = (presetID, autoDownload, downloadLatest)
        task = Task {
            do {
                try await subscriptions.add(url: normalized, presetID: preset, autoDownload: auto, downloadLatest: latest)
                guard !Task.isCancelled else { return }
                isAdding = false
                close()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                isAdding = false
                self.error = error.localizedDescription
            }
        }
    }

    private func close() {
        task?.cancel()
        appState.isAddSubscriptionPresented = false
        dismiss()
    }
}
