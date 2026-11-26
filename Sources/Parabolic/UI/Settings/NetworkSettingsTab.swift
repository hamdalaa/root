import SwiftUI

struct NetworkSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Form {
            Section {
                TextField("Proxy", text: settings.settingsBinding(\.proxyURL), prompt: Text("socks5://127.0.0.1:1080"))
                    .autocorrectionDisabled()
                Toggle("Force IPv4", isOn: settings.settingsBinding(\.forceIPv4))
                SettingsStepper(title: "Pause between requests", value: settings.settingsBinding(\.sleepBetweenRequests), range: 0...60) {
                    $0 == 0 ? "Off" : "\($0) s"
                }
            } header: {
                Text("Connection")
            } footer: {
                SettingsFooter("Leave the proxy empty to connect directly. A short pause between requests helps avoid rate limits on large playlists.")
            }

            Section {
                Picker("Use cookies from", selection: settings.settingsBinding(\.cookieBrowser)) {
                    ForEach(CookieBrowser.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Cookies file") {
                    HStack(spacing: Tokens.space2) {
                        Text(settings.prefs.cookiesFilePath.isEmpty ? "None" : SettingsSupport.abbreviated(settings.prefs.cookiesFilePath))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(settings.prefs.cookiesFilePath)
                        Button("Choose…") {
                            if let path = SettingsSupport.choose(directory: false, startingAt: settings.prefs.cookiesFilePath) {
                                settings.setPref(\.cookiesFilePath, path)
                            }
                        }
                        if !settings.prefs.cookiesFilePath.isEmpty {
                            Button {
                                settings.setPref(\.cookiesFilePath, "")
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Clear cookies file")
                            .accessibilityLabel("Clear cookies file")
                        }
                    }
                }
            } header: {
                Text("Cookies")
            } footer: {
                SettingsFooter("Cookies let yt-dlp access age-restricted, members-only or private media you can already see in your browser. Safari needs Full Disk Access for Root in System Settings › Privacy & Security. A Netscape-format cookies file is used when set.")
            }

            Section {
                TextField("User agent", text: settings.settingsBinding(\.userAgent), prompt: Text("Default"))
                    .autocorrectionDisabled()
                TextField("Metadata language", text: settings.settingsBinding(\.metadataLanguage), prompt: Text("e.g. en, ar, ja"))
                    .autocorrectionDisabled()
            } header: {
                Text("Identity")
            } footer: {
                SettingsFooter("The metadata language asks YouTube for titles and descriptions in that language code when translations exist.")
            }
        }
    }
}
