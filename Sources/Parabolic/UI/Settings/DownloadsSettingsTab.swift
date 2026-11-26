import SwiftUI

struct DownloadsSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ToolStore.self) private var tools

    var body: some View {
        Form {
            locationSection
            finishedFilesSection
            turboSection
            FilenameTemplateSection()

            Section("Queue") {
                SettingsStepper(title: "Simultaneous downloads", value: settings.settingsBinding(\.maxConcurrentDownloads), range: 1...10)
                Toggle("Overwrite existing files", isOn: settings.settingsBinding(\.overwriteExistingFiles))
                Toggle("Download to .part files until complete", isOn: settings.settingsBinding(\.usePartFiles))
            }

            speedSection
            bandwidthScheduleSection
            aria2Section
            SponsorBlockSection()
        }
    }

    // MARK: - Location

    private var locationSection: some View {
        return Section("Location") {
            LabeledContent("Download folder") {
                HStack(spacing: Tokens.space2) {
                    Label(SettingsSupport.abbreviated(settings.prefs.downloadFolder), systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .help(settings.prefs.downloadFolder)
                    Button("Choose…") {
                        if let path = SettingsSupport.choose(directory: true, startingAt: settings.prefs.downloadFolder) {
                            settings.setPref(\.downloadFolder, path)
                        }
                    }
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: settings.prefs.downloadFolder))
                    } label: {
                        Image(systemName: "arrow.right.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal download folder in Finder")
                }
            }
            Toggle("Organize into folders by uploader", isOn: settings.settingsBinding(\.organizeByUploader))
        }
    }

    // MARK: - Finished files

    private static let categoryFolders = ListFormatter.localizedString(byJoining: FileCategory.allCases.map(\.rawValue))

    private var finishedFilesSection: some View {
        Section {
            Toggle("Sort finished files into folders by type", isOn: settings.settingsBinding(\.organizeByType))
            Toggle("Unpack archives after download", isOn: settings.settingsBinding(\.autoExtractArchives))
        } header: {
            Text("Finished files")
        } footer: {
            SettingsFooter("Sorted files go into \(Self.categoryFolders) folders inside the download folder. Unpacking handles .zip and .tar archives from file downloads and keeps the archive.")
        }
    }

    // MARK: - Turbo

    private var turboSection: some View {
        Section {
            Toggle(isOn: settings.settingsBinding(\.turboMode)) {
                Label("Turbo mode", systemImage: "bolt.fill")
            }
        } footer: {
            SettingsFooter("Uses the maximum 16 connections per file and 16 fragments per stream, with a larger disk cache. Downloads finish sooner but use more bandwidth, and some servers slow down or block that many connections.")
        }
    }

    // MARK: - Speed & reliability

    private var speedLimitEnabled: Binding<Bool> {
        Binding(
            get: { settings.prefs.speedLimitKBps > 0 },
            set: { settings.setPref(\.speedLimitKBps, $0 ? max(settings.prefs.speedLimitKBps, 2048) : 0) })
    }

    private var speedSection: some View {
        return Section {
            Toggle("Limit download speed", isOn: speedLimitEnabled)
            if settings.prefs.speedLimitKBps > 0 {
                LabeledContent("Maximum speed") {
                    HStack(spacing: Tokens.space1) {
                        TextField("Maximum speed", value: settings.settingsBinding(\.speedLimitKBps), format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 90)
                        Text("KB/s").foregroundStyle(.secondary)
                    }
                }
            }
            SettingsStepper(title: "Retries", value: settings.settingsBinding(\.retries), range: 0...50)
            SettingsStepper(title: "Concurrent fragments", value: settings.settingsBinding(\.concurrentFragments), range: 1...16,
                            format: { settings.prefs.turboMode ? "16 (Turbo)" : "\($0)" })
                .disabled(settings.prefs.turboMode)
        } header: {
            Text("Speed and reliability")
        } footer: {
            SettingsFooter("Concurrent fragments speed up segmented streams such as YouTube DASH and HLS.")
        }
    }

    // MARK: - Bandwidth schedule

    private static let hourLabels: [Int: String] = Dictionary(uniqueKeysWithValues: (0..<24).map { hour in
        var parts = DateComponents()
        parts.hour = hour
        let date = Calendar.current.date(from: parts) ?? .now
        return (hour, date.formatted(date: .omitted, time: .shortened))
    })

    private func hourPicker(_ title: String, _ keyPath: WritableKeyPath<Preferences, Int>) -> some View {
        Picker(title, selection: settings.settingsBinding(keyPath)) {
            ForEach(0..<24, id: \.self) { hour in Text(Self.hourLabels[hour] ?? "\(hour):00").tag(hour) }
        }
    }

    var bandwidthScheduleSection: some View {
        Section {
            Toggle("Slow down downloads during set hours", isOn: settings.settingsBinding(\.bandwidthScheduleEnabled))
            if settings.prefs.bandwidthScheduleEnabled {
                hourPicker("From", \.bandwidthScheduleStartHour)
                hourPicker("Until", \.bandwidthScheduleEndHour)
                Toggle("Weekdays only", isOn: settings.settingsBinding(\.bandwidthScheduleWeekdaysOnly))
                LabeledContent("Maximum speed") {
                    HStack(spacing: Tokens.space1) {
                        TextField("Scheduled speed", value: settings.settingsBinding(\.bandwidthScheduleLimitKBps), format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 90)
                        Text("KB/s").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Right now") {
                    Text(settings.prefs.isInBandwidthWindow(at: .now) ? "Scheduled limit active" : "Normal speed")
                        .foregroundStyle(settings.prefs.isInBandwidthWindow(at: .now) ? Color.accentColor : .secondary)
                }
            }
        } header: {
            Text("Bandwidth schedule")
        } footer: {
            SettingsFooter("Downloads in progress switch speed automatically when the window starts or ends. A download’s own limit (right-click → Speed Limit) always wins.")
        }
    }

    // MARK: - aria2

    private var aria2Section: some View {
        let available = tools.paths.aria2c != nil
        return Section {
            Toggle("Use aria2c as the downloader", isOn: settings.settingsBinding(\.useAria2))
                .disabled(!available)
            if settings.prefs.useAria2, available {
                SettingsStepper(title: "Connections per file", value: settings.settingsBinding(\.aria2MaxConnections), range: 1...16)
            }
        } header: {
            Text("External downloader")
        } footer: {
            if available {
                SettingsFooter("aria2c opens several connections per file. Some sites throttle or block it.")
            } else {
                SettingsFooter("aria2c isn't installed. Install it with `brew install aria2`, then reopen Settings.")
            }
        }
    }
}

/// SponsorBlock toggle plus per-category selection.
private struct SponsorBlockSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Section {
            Toggle("Remove SponsorBlock segments", isOn: settings.settingsBinding(\.sponsorBlockEnabled))
            if settings.prefs.sponsorBlockEnabled {
                ForEach(SponsorBlockCategory.allCases) { category in
                    Toggle(category.label, isOn: settings.membership(category, in: \.sponsorBlockCategories))
                        .padding(.leading, Tokens.space4)
                }
            }
        } header: {
            Text("SponsorBlock")
        } footer: {
            SettingsFooter("Uses community-submitted timestamps to cut the selected segments from YouTube videos.")
        }
    }
}
