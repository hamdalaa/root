import SwiftUI

struct ConverterSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Form {
            Section {
                Picker("Video codec", selection: settings.settingsBinding(\.preferredVideoCodec)) {
                    ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
                }
                Picker("Audio codec", selection: settings.settingsBinding(\.preferredAudioCodec)) {
                    ForEach(AudioCodec.allCases) { Text($0.label).tag($0) }
                }
                Picker("Frame rate", selection: settings.settingsBinding(\.preferredFrameRate)) {
                    ForEach(FrameRate.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Preferred formats")
            } footer: {
                SettingsFooter("Preferences rank the available streams; Root falls back to the best match when a site doesn't offer them. H.264 plays everywhere on Apple devices.")
            }

            Section {
                Toggle("Embed metadata", isOn: settings.settingsBinding(\.embedMetadata))
                Toggle("Remove source data", isOn: settings.settingsBinding(\.removeSourceData))
                    .disabled(!settings.prefs.embedMetadata)
                Toggle("Embed chapters", isOn: settings.settingsBinding(\.embedChapters))
                Toggle("Embed thumbnail", isOn: settings.settingsBinding(\.embedThumbnail))
                Toggle("Crop audio thumbnails to a square", isOn: settings.settingsBinding(\.cropAudioThumbnails))
                    .disabled(!settings.prefs.embedThumbnail)
            } header: {
                Text("Metadata")
            } footer: {
                SettingsFooter("Removing source data strips the comment, description and source URL from embedded tags.")
            }

            Section("Subtitles") {
                Toggle("Embed subtitles", isOn: settings.settingsBinding(\.embedSubtitles))
                Picker("Subtitle format", selection: settings.settingsBinding(\.subtitleFormat)) {
                    ForEach(SubtitleFormat.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Include auto-generated subtitles by default", isOn: settings.settingsBinding(\.includeAutoSubtitlesByDefault))
            }

            Section {
                SettingsStepper(title: "Post-processing threads", value: settings.settingsBinding(\.postprocessingThreads), range: 0...16) {
                    $0 == 0 ? "Automatic" : "\($0)"
                }
            } header: {
                Text("Performance")
            } footer: {
                SettingsFooter("Threads ffmpeg may use when converting and merging. Automatic lets ffmpeg decide.")
            }
        }
    }
}
