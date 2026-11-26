import AppKit
import SwiftUI

/// Browser extension: native-messaging connections, install steps, and what gets caught.
struct BrowserSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    /// Bumped after connect / disconnect so the file-based status re-reads.
    @State private var statusRevision = 0
    @State private var message: String?
    /// Extension and rival state per browser, read from the browsers' preference files off the main thread.
    @State private var statuses: [BrowserStatus] = []

    private var installed: [BrowserBridge.Browser] {
        _ = statusRevision
        return BrowserBridge.browsers.filter(\.isInstalled)
    }

    var body: some View {
        Form {
            DefaultManagerSection(statuses: statuses) { statusRevision += 1 }
            browsersSection
            ExtensionInstallSections()
            catchingSection
            fileDownloadsSection
        }
        .onAppear { statusRevision += 1 }
        .task(id: statusRevision) {
            statuses = await Task.detached(priority: .utility) { BrowserStatus.readAll() }.value
        }
    }

    // MARK: - Browsers

    private var browsersSection: some View {
        let browsers = installed
        let canConnect = BrowserBridge.hostExecutablePath != nil
        return Section {
            if browsers.isEmpty {
                Text("No supported browsers found.")
                    .foregroundStyle(.secondary)
            }
            ForEach(browsers) { browser in
                BrowserConnectionRow(browser: browser,
                                     extensionState: statuses.first { $0.id == browser.id }?.rootExtension,
                                     canConnect: canConnect,
                                     onConnect: connectAll, onDisconnect: { disconnect(browser) })
            }
            if let message {
                Label(message, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        } header: {
            HStack {
                Text("Browsers")
                Spacer()
                if browsers.count > 1 {
                    Button("Connect All", action: connectAll)
                        .buttonStyle(.borderless)
                        .disabled(!canConnect || browsers.allSatisfy(\.isConnected))
                    Button("Disconnect All", action: disconnectAll)
                        .buttonStyle(.borderless)
                        .disabled(!browsers.contains(where: \.isConnected))
                }
            }
        } footer: {
            if canConnect {
                SettingsFooter("Connecting lets the Root extension in that browser talk to the app. It adds a small manifest file to the browser's support folder; nothing else changes.")
            } else {
                SettingsFooter("Connecting needs the helper inside Root.app. Run the bundled app to connect browsers.")
            }
        }
    }

    private func connectAll() {
        let connected = BrowserBridge.installHosts()
        message = connected.isEmpty
            ? "Couldn't connect. Make sure Root is running from its app bundle."
            : "Connected \(ListFormatter.localizedString(byJoining: connected)). Restart the browser if the extension was already open."
        statusRevision += 1
    }

    private func disconnect(_ browser: BrowserBridge.Browser) {
        do {
            try FileManager.default.removeItem(atPath: browser.manifestPath)
            message = "Disconnected \(browser.name)."
        } catch {
            message = "Couldn't disconnect \(browser.name): \(error.localizedDescription)"
        }
        statusRevision += 1
    }

    private func disconnectAll() {
        BrowserBridge.uninstallHosts()
        message = "Disconnected every browser."
        statusRevision += 1
    }

    // MARK: - Catching

    private var catchingSection: some View {
        Section {
            Toggle("Catch downloads from the browser", isOn: settings.settingsBinding(\.browserCatchDownloads))
            Toggle("Catch every download (images and small files too)", isOn: settings.settingsBinding(\.browserCatchEverything))
                .disabled(!settings.prefs.browserCatchDownloads)
            Toggle("Show a download popup for each caught file", isOn: settings.settingsBinding(\.browserShowCatchWindow))
                .disabled(!settings.prefs.browserCatchDownloads)
            if !settings.prefs.catchSkipTypes.isEmpty {
                LabeledContent("Start without asking") {
                    HStack(spacing: 10) {
                        Text(settings.prefs.catchSkipTypes.map { $0.uppercased() }.joined(separator: ", "))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Button("Ask Again") { settings.prefs.catchSkipTypes = [] }
                            .controlSize(.small)
                    }
                }
                .disabled(!settings.prefs.browserShowCatchWindow)
            }
            Group {
                LabeledContent("File types") {
                    TextField("File types", text: settings.settingsBinding(\.browserCatchExtensions),
                              prompt: Text("zip dmg pdf"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(1...3)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: 340)
                }
                .disabled(settings.prefs.browserCatchEverything)
                SettingsStepper(title: "Only files larger than", value: settings.settingsBinding(\.browserMinCatchSizeMB),
                                range: 0...2048, format: { $0 == 0 ? "Any size" : "\($0) MB" })
                    .disabled(settings.prefs.browserCatchEverything)
                LabeledContent("Never catch from") {
                    TextField("Never catch from", text: settings.settingsBinding(\.browserSkipHosts),
                              prompt: Text("example.com, intranet.local"))
                        .labelsHidden()
                        .frame(maxWidth: 340)
                }
            }
            .disabled(!settings.prefs.browserCatchDownloads)
        } header: {
            Text("Catching downloads")
        } footer: {
            SettingsFooter("When the browser starts a download of one of these file types, Root takes it over with the browser's cookies so signed-in downloads still work. Separate extensions with spaces and sites with commas.")
        }
    }

    // MARK: - File downloads

    private var fileDownloadsSection: some View {
        Section {
            SettingsStepper(title: "Connections per file", value: settings.settingsBinding(\.directConnections), range: 1...16)
            SettingsStepper(title: "Retry failed downloads", value: settings.settingsBinding(\.autoRetryAttempts), range: 0...5,
                            format: { $0 == 0 ? "Off" : ($0 == 1 ? "Once" : "\($0) times") })
            Toggle("Mark downloaded files as from the internet", isOn: settings.settingsBinding(\.quarantineDownloads))
        } header: {
            Text("File downloads")
        } footer: {
            SettingsFooter("macOS checks downloaded apps and installers with Gatekeeper before they open for the first time. Turn this off only for files you trust.")
        }
    }
}

/// One installed browser: name, connection status and its action.
private struct BrowserConnectionRow: View {
    var browser: BrowserBridge.Browser
    /// Root's extension in this browser; nil for Firefox or before the first read.
    var extensionState: BrowserExtensionState?
    var canConnect: Bool
    var onConnect: () -> Void
    var onDisconnect: () -> Void

    var body: some View {
        let connected = browser.isConnected
        HStack(spacing: Tokens.space3) {
            Image(systemName: browser.isFirefox ? "flame" : "globe")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(browser.name)
                if let extensionState {
                    Text(extensionText(extensionState))
                        .font(.system(size: 11))
                        .foregroundStyle(extensionState == .enabled ? Color.secondary : Color.red)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                SettingsStatusDot(isOn: connected)
                Text(connected ? "Connected" : "Not connected")
                    .font(.system(size: 12))
                    .foregroundStyle(connected ? Color.green : .secondary)
            }
            .animation(Tokens.quick, value: connected)
            if connected {
                Button("Disconnect", action: onDisconnect)
            } else {
                Button("Connect", action: onConnect)
                    .disabled(!canConnect)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(browser.name), \(connected ? "connected" : "not connected")")
    }

    private func extensionText(_ state: BrowserExtensionState) -> String {
        switch state {
        case .enabled: "Root extension on"
        case .disabled: "Root extension turned off"
        case .notInstalled: "Root extension not installed"
        }
    }
}
