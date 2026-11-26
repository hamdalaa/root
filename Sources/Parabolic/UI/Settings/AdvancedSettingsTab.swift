import AppKit
import SwiftUI

struct AdvancedSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(HistoryStore.self) private var history
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                argumentsField("Download arguments", text: settings.settingsBinding(\.extraDownloadArguments),
                               prompt: "--embed-info-json --no-mtime")
                argumentsField("Discovery arguments", text: settings.settingsBinding(\.extraDiscoveryArguments),
                               prompt: "--extractor-args youtube:player_client=web")
            } header: {
                Text("Extra yt-dlp arguments")
            } footer: {
                Label("Passed to yt-dlp as-is, after Root's own options. Conflicting flags can break downloads or progress reporting.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Maintenance") {
                LabeledContent("Support folder") {
                    Button("Open in Finder") { NSWorkspace.shared.open(ToolStore.supportDirectory) }
                }
                LabeledContent("Settings") {
                    Button("Reset All Settings…", role: .destructive) { confirmReset = true }
                        .foregroundStyle(.red)
                }
            }

            Section {
                AboutBlock()
            }
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset All Settings", role: .destructive, action: resetAll)
        } message: {
            Text("Every preference returns to its default. Your custom presets, saved logins, downloads and history are kept.")
        }
    }

    /// Resets preferences but keeps user-created data (presets and Keychain-backed logins).
    private func resetAll() {
        let kept = settings.prefs
        settings.reset()
        var fresh = settings.prefs
        fresh.customPresets = kept.customPresets
        fresh.credentials = kept.credentials
        if let id = kept.defaultPresetID, kept.customPresets.contains(where: { $0.id == id }) {
            fresh.defaultPresetID = id
        }
        settings.prefs = fresh
        history.prune(retention: fresh.historyRetention)
    }

    private func argumentsField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            TextField(title, text: text, prompt: Text(prompt), axis: .vertical)
                .labelsHidden()
                .lineLimit(2...4)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct AboutBlock: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short) (development build)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.space4) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Root")
                    .font(.system(size: 17, weight: .semibold))
                Text(version)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("Inspired by Nickvision Parabolic · Powered by yt-dlp")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                HStack(spacing: Tokens.space3) {
                    Link("yt-dlp", destination: URL(string: "https://github.com/yt-dlp/yt-dlp")!)
                    Link("Supported sites", destination: URL(string: "https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md")!)
                    Link("Nickvision Parabolic", destination: URL(string: "https://github.com/NickvisionApps/Parabolic")!)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(.vertical, Tokens.space1)
    }
}
