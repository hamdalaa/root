import AppKit
import SwiftUI

/// Settings → Browser, top: "Root = default download manager" and the live facts behind it.
struct DefaultManagerSection: View {
    @Environment(AppSettings.self) private var settings
    var statuses: [BrowserStatus]
    var onChange: () -> Void

    @State private var magnetApp: URL?
    @State private var torrentApp: URL?
    @State private var claimError: String?

    private var ownsLinks: Bool { DefaultDownloadManager.isRoot(magnetApp) && DefaultDownloadManager.isRoot(torrentApp) }

    var body: some View {
        Section {
            Toggle("Make Root the default download manager", isOn: Binding(
                get: { settings.prefs.isDefaultDownloadManager },
                set: { newValue in
                    guard settings.prefs.isDefaultDownloadManager != newValue else { return }
                    settings.prefs.isDefaultDownloadManager = newValue
                    if newValue { claim() }
                }))
            LabeledContent("Magnet links and .torrent files") {
                HStack(spacing: 6) {
                    SettingsStatusDot(isOn: ownsLinks)
                    Text(ownsLinks ? "Open in Root" : "Open in \(DefaultDownloadManager.name(of: magnetApp) ?? "another app")")
                        .foregroundStyle(ownsLinks ? Color.green : .secondary)
                    if !ownsLinks {
                        Button("Use Root") { claim() }.controlSize(.small)
                    }
                }
                .font(.system(size: 12))
            }
            ForEach(statuses.filter { !$0.rivals.isEmpty }) { status in
                Label {
                    Text("\(ListFormatter.localizedString(byJoining: status.rivals)) is also catching downloads in \(status.browser.name). Turn its extension off in chrome://extensions, or click “Turn It Off” in Root’s extension menu.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                }
                .font(.system(size: 12))
            }
            if let claimError {
                Text(claimError).font(.system(size: 12)).foregroundStyle(.red)
            }
        } header: {
            Text("Default download manager")
        } footer: {
            SettingsFooter("Root opens magnet links and .torrent files, and its browser extension takes over web downloads. Root never claims http links themselves: macOS gives those to your web browser.")
        }
        .task(id: settings.prefs.isDefaultDownloadManager) { readHandlers() }
    }

    private func claim() {
        Task {
            claimError = await DefaultDownloadManager.claim()
            readHandlers()
            onChange()
        }
    }

    private func readHandlers() {
        magnetApp = DefaultDownloadManager.magnetHandler
        torrentApp = DefaultDownloadManager.torrentHandler
    }
}
