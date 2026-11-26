import SwiftUI

/// yt-dlp and helper tools: status, channel, and the managed copy.
struct EngineSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ToolStore.self) private var tools

    private enum Action { case install, update, remove, refresh }
    @State private var running: Action?

    private var isBusy: Bool { running != nil || tools.isUpdating }
    private var hasManagedCopy: Bool { FileManager.default.isExecutableFile(atPath: ToolStore.managedYtdlpPath) }

    var body: some View {
        Form {
            Section {
                ToolStatusRow(name: "yt-dlp", path: tools.paths.ytdlp, version: tools.ytdlpVersion,
                              note: tools.usingManagedCopy ? "Managed by Root" : nil)
                ToolStatusRow(name: "ffmpeg", path: tools.paths.ffmpeg, version: tools.ffmpegVersion,
                              note: "Needed to merge, convert and embed")
                ToolStatusRow(name: "deno", path: tools.paths.deno, version: nil,
                              note: "Solves YouTube's JavaScript challenges")
                ToolStatusRow(name: "aria2", path: tools.paths.aria2c, version: nil,
                              note: "Files & torrents")
            } header: {
                HStack {
                    Text("Tools")
                    Spacer()
                    Button {
                        run(.refresh) { await tools.refresh(channel: settings.prefs.ytdlpChannel) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isBusy)
                    .help("Search for tools again")
                    .accessibilityLabel("Search for tools again")
                }
            } footer: {
                SettingsFooter("Missing something? Install the helpers with `brew install ffmpeg deno`. yt-dlp can be installed below without Homebrew.")
            }

            Section {
                Picker("Use", selection: settings.settingsBinding(\.ytdlpChannel)) {
                    ForEach(YtdlpChannel.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Use nightly builds", isOn: settings.settingsBinding(\.useNightlyBuilds))
            } header: {
                Text("yt-dlp")
            } footer: {
                SettingsFooter("Sites change often. Nightly builds get extractor fixes days before stable releases.")
            }

            Section {
                HStack(spacing: Tokens.space2) {
                    actionButton("Install Managed Copy", action: .install) {
                        await tools.installManagedYtdlp(nightly: settings.prefs.useNightlyBuilds)
                    }
                    actionButton("Check for Updates", action: .update) {
                        await tools.updateYtdlp(nightly: settings.prefs.useNightlyBuilds, channel: settings.prefs.ytdlpChannel)
                    }
                    .disabled(!tools.isReady)
                    Spacer(minLength: 0)
                    actionButton("Remove Managed Copy", action: .remove, role: .destructive) {
                        await tools.removeManagedYtdlp(channel: settings.prefs.ytdlpChannel)
                    }
                    .disabled(!hasManagedCopy)
                }
                if let message = tools.lastMessage {
                    Label(message, systemImage: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Managed copy")
            } footer: {
                SettingsFooter("The managed copy is the official standalone build, kept in Root's support folder and updated in place.")
            }
        }
        .onChange(of: settings.prefs.ytdlpChannel) { _, channel in
            run(.refresh) { await tools.refresh(channel: channel) }
        }
    }

    private func actionButton(_ title: String, action: Action, role: ButtonRole? = nil,
                              perform: @escaping @MainActor () async -> Void) -> some View {
        Button(role: role) {
            run(action, perform)
        } label: {
            HStack(spacing: 6) {
                if running == action {
                    ProgressView().controlSize(.small)
                }
                Text(title)
            }
        }
        .disabled(isBusy)
    }

    private func run(_ action: Action, _ work: @escaping @MainActor () async -> Void) {
        guard running == nil else { return }
        running = action
        Task {
            await work()
            running = nil
        }
    }
}

private struct ToolStatusRow: View {
    var name: String
    var path: String?
    var version: String?
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.space3) {
            SettingsStatusDot(isOn: path != nil)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 13, weight: .medium, design: .monospaced))
                    if let version {
                        Text(version)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(path.map(SettingsSupport.abbreviated) ?? "Not found")
                    .font(.system(size: 11))
                    .foregroundStyle(path == nil ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(path ?? "")
            }
            Spacer()
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(path == nil ? "not found" : "found")\(version.map { ", version \($0)" } ?? "")")
    }
}
