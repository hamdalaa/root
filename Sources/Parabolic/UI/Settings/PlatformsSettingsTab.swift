import SwiftUI

/// Per-platform behaviour: smart audio, sidebar visibility, and a quick-download preset for every site.
struct PlatformsSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @State private var query = ""
    @State private var isConfirmingReset = false

    private var musicPlatformNames: String {
        ListFormatter.localizedString(byJoining: Platform.known.filter(\.prefersAudio).map(\.title))
    }

    private var filtered: [Platform] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return Platform.known }
        return Platform.known.filter { $0.title.localizedCaseInsensitiveContains(needle) || $0.rawValue.localizedCaseInsensitiveContains(needle) }
    }

    private var customizedCount: Int {
        Platform.known.filter { settings.prefs.platformPresets[$0.rawValue] != nil }.count
    }

    private var isAtDefaults: Bool {
        let defaults = Preferences()
        return settings.prefs.platformPresets.isEmpty
            && settings.prefs.smartAudioForMusicPlatforms == defaults.smartAudioForMusicPlatforms
            && settings.prefs.showPlatformsInSidebar == defaults.showPlatformsInSidebar
    }

    var body: some View {
        Form {
            Section {
                Toggle("Download music platforms as audio", isOn: settings.settingsBinding(\.smartAudioForMusicPlatforms))
                Toggle("Show platforms in the sidebar", isOn: settings.settingsBinding(\.showPlatformsInSidebar))
            } header: {
                Text("Recognition")
            } footer: {
                SettingsFooter("Quick downloads from \(musicPlatformNames) use your first audio preset unless you pick one below. The sidebar lists every platform you've downloaded from.")
            }

            Section {
                PlatformSearchField(text: $query)
                if filtered.isEmpty {
                    PlatformsNoMatch(query: query)
                } else {
                    ForEach(filtered) { platform in
                        PlatformPresetRow(platform: platform)
                    }
                }
            } header: {
                HStack {
                    Text("Quick-download preset per platform")
                    Spacer()
                    if customizedCount > 0 {
                        Text("\(customizedCount) customized")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                SettingsFooter("Copied links, the menu bar and the global shortcut use the platform's preset. Default follows your quick-download preset (or audio for music platforms).")
            }

            Section {
                LabeledContent {
                    Button("Reset Platform Defaults…") { isConfirmingReset = true }
                        .disabled(isAtDefaults)
                } label: {
                    Text("Reset")
                    Text("Clears every platform preset and restores the switches above.")
                }
            }
        }
        .confirmationDialog("Reset platform defaults?", isPresented: $isConfirmingReset) {
            Button("Reset", role: .destructive, action: resetDefaults)
        } message: {
            Text("Every platform goes back to the default preset. Your presets themselves are kept.")
        }
    }

    private func resetDefaults() {
        let defaults = Preferences()
        var prefs = settings.prefs
        prefs.platformPresets = defaults.platformPresets
        prefs.smartAudioForMusicPlatforms = defaults.smartAudioForMusicPlatforms
        prefs.showPlatformsInSidebar = defaults.showPlatformsInSidebar
        if prefs != settings.prefs { settings.prefs = prefs }
    }
}

/// One platform: brand mark, name, what "Default" resolves to, and a preset picker.
private struct PlatformPresetRow: View {
    @Environment(AppSettings.self) private var settings
    var platform: Platform

    /// Stale ids (a deleted custom preset) read as Default so the picker never shows a blank.
    private var selection: Binding<UUID?> {
        Binding(
            get: {
                guard let id = settings.prefs.platformPresets[platform.rawValue],
                      settings.prefs.allPresets.contains(where: { $0.id == id }) else { return nil }
                return id
            },
            set: { newValue in
                let current = settings.prefs.platformPresets[platform.rawValue]
                guard current != newValue else { return }
                var map = settings.prefs.platformPresets
                map[platform.rawValue] = newValue
                settings.prefs.platformPresets = map
            })
    }

    /// The preset a quick download would use if this platform stays on Default.
    private var defaultResolution: DownloadPreset {
        var prefs = settings.prefs
        prefs.platformPresets[platform.rawValue] = nil
        return prefs.preset(for: platform)
    }

    var body: some View {
        Picker(selection: selection) {
            Text("Default (\(defaultResolution.name))").tag(UUID?.none)
            Divider()
            ForEach(settings.prefs.allPresets) { preset in
                Label(preset.name, systemImage: preset.symbol).tag(Optional(preset.id))
            }
        } label: {
            HStack(spacing: Tokens.space3) {
                PlatformBadge(platform: platform, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(platform.title)
                    if platform.prefersAudio {
                        Text("Music & podcasts")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityLabel("\(platform.title) preset")
    }
}

/// Inline filter field styled like the System Settings search.
private struct PlatformSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Tokens.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Filter platforms", text: $text, prompt: Text("Filter platforms"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .focused($focused)
                .accessibilityLabel("Filter platforms")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Clear filter")
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, Tokens.space3)
        .padding(.vertical, 6)
        .background(.primary.opacity(focused ? 0.07 : 0.045), in: .capsule)
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .animation(Tokens.quick, value: focused)
    }
}

private struct PlatformsNoMatch: View {
    var query: String

    var body: some View {
        VStack(spacing: Tokens.space1) {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No platform matches “\(query)”")
                .font(.system(size: 13, weight: .medium))
            Text("Links from other sites still work. They use the default preset.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.space4)
        .accessibilityElement(children: .combine)
    }
}
