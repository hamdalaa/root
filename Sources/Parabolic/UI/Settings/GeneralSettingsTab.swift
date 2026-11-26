import AppKit
import SwiftUI

struct GeneralSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(HistoryStore.self) private var history
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(AppState.self) private var appState

    /// Check intervals offered for subscriptions, in minutes.
    private static let checkIntervals = [15, 30, 60, 180, 360, 720, 1440]

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: settings.settingsBinding(\.appearance)) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Show in menu bar", isOn: settings.settingsBinding(\.showMenuBarExtra))
                Toggle("Show progress in Dock", isOn: settings.settingsBinding(\.showDockProgress))
            }

            Section {
                Toggle("Watch clipboard for links", isOn: settings.settingsBinding(\.watchClipboard))
                Toggle("Start downloads from copied links automatically", isOn: settings.settingsBinding(\.autoStartFromClipboard))
                    .disabled(!settings.prefs.watchClipboard)
            } header: {
                Text("Clipboard")
            } footer: {
                SettingsFooter("When you copy a link anywhere on your Mac, Root offers it in the main window and menu bar. Automatic start downloads it straight away with your default quick-download preset.")
            }

            Section {
                Toggle(isOn: settings.settingsBinding(\.globalHotKeyEnabled)) {
                    HStack(spacing: Tokens.space3) {
                        Text("Quick-download the copied link from any app")
                        Spacer(minLength: Tokens.space2)
                        KeycapsView(shortcut: GlobalHotKey.displayString)
                            .opacity(settings.prefs.globalHotKeyEnabled ? 1 : 0.45)
                    }
                }
                Toggle(isOn: settings.settingsBinding(\.forceQuitHotKeyEnabled)) {
                    HStack(spacing: Tokens.space3) {
                        Text("Open Force Quit Applications from any app")
                        Spacer(minLength: Tokens.space2)
                        KeycapsView(shortcut: GlobalHotKey.forceQuitDisplayString)
                            .opacity(settings.prefs.forceQuitHotKeyEnabled ? 1 : 0.45)
                    }
                }
            } header: {
                Text("Global shortcuts")
            } footer: {
                SettingsFooter("Copy a link, press ⌃⌥⌘D anywhere on your Mac, and Root starts the download with that platform's preset. ⌃⌥⌘⎋ lists running apps by memory so you can end the one that’s stuck.")
            }

            Section {
                LabeledContent("Permissions and download catching") {
                    Button("Set Up Root…") {
                        NSApp.activate()
                        appState.isSetupGuidePresented = true
                        NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
                    }
                }
            } header: {
                Text("Setup")
            } footer: {
                SettingsFooter("Shows what Root is allowed to do (Full Disk Access, Downloads, Automation, notifications) and whether it catches your browser’s downloads, with a button to fix each one.")
            }

            Section("Quick download") {
                Picker("Default preset", selection: settings.settingsBinding(\.defaultPresetID)) {
                    ForEach(settings.prefs.allPresets) { preset in
                        Label(preset.name, systemImage: preset.symbol).tag(Optional(preset.id))
                    }
                }
            }

            Section {
                Toggle("Check subscriptions for new uploads", isOn: settings.settingsBinding(\.subscriptionsEnabled))
                Picker("Check every", selection: settings.settingsBinding(\.subscriptionCheckMinutes)) {
                    ForEach(intervalOptions, id: \.self) { Text(Self.intervalLabel($0)).tag($0) }
                }
                .disabled(!settings.prefs.subscriptionsEnabled)
                LabeledContent("Following") {
                    HStack(spacing: Tokens.space2) {
                        if subscriptions.isChecking {
                            ProgressView().controlSize(.small)
                        }
                        Text(followingText)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Check Now") { subscriptions.checkAll() }
                            .disabled(subscriptions.subscriptions.isEmpty || subscriptions.isChecking)
                    }
                }
            } header: {
                Text("Subscriptions")
            } footer: {
                SettingsFooter("While Root is open it checks the channels and playlists you follow, then downloads new uploads with each subscription's preset.")
            }

            Section {
                Toggle("Show notifications", isOn: settings.settingsBinding(\.showNotifications))
                Toggle("Prevent sleep while downloading", isOn: settings.settingsBinding(\.preventSleep))
                Picker("When downloads finish", selection: settings.settingsBinding(\.completionAction)) {
                    ForEach(CompletionAction.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Confirm before quitting with active downloads", isOn: settings.settingsBinding(\.confirmQuitWithActiveDownloads))
            } header: {
                Text("While downloading")
            } footer: {
                SettingsFooter("The finish action runs once the whole queue is empty, not after each file.")
            }

            Section {
                Picker("Keep history", selection: settings.settingsBinding(\.historyRetention)) {
                    ForEach(HistoryRetention.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Stored items") {
                    HStack(spacing: Tokens.space2) {
                        Text("\(history.entries.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Clear History") { history.clear() }
                            .disabled(history.entries.isEmpty)
                    }
                }
            } header: {
                Text("History")
            } footer: {
                SettingsFooter("Shortening retention removes older entries right away. Downloaded files are never deleted.")
            }
        }
        .onChange(of: settings.prefs.historyRetention) { _, retention in
            history.prune(retention: retention)
        }
    }

    /// The standard intervals, plus the stored one if it was set elsewhere, so the picker never shows a blank.
    private var intervalOptions: [Int] {
        let current = settings.prefs.subscriptionCheckMinutes
        return Self.checkIntervals.contains(current) ? Self.checkIntervals : (Self.checkIntervals + [current]).sorted()
    }

    private var followingText: String {
        let count = subscriptions.subscriptions.count
        if subscriptions.isChecking { return "Checking…" }
        return count == 0 ? "Nothing yet" : "\(count) \(count == 1 ? "channel" : "channels")"
    }

    static func intervalLabel(_ minutes: Int) -> String {
        switch minutes {
        case 1440: return "Day"
        case 60: return "Hour"
        case let m where m % 60 == 0: return "\(m / 60) hours"
        default: return "\(minutes) minutes"
        }
    }
}
