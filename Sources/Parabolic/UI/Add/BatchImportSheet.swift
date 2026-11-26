import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Paste or open a list of links and queue them all with one preset.
struct BatchImportSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var text = ""
    @State private var presetID: UUID?
    @State private var fileError: String?
    @State private var didLoad = false
    @FocusState private var editorFocused: Bool

    private var links: [String] {
        var seen = Set<String>()
        return LinkScanner.allLinks(in: text).filter { seen.insert($0).inserted }
    }

    private var preset: DownloadPreset {
        settings.prefs.allPresets.first { $0.id == presetID } ?? settings.prefs.defaultPreset
    }

    var body: some View {
        let count = links.count
        VStack(alignment: .leading, spacing: Tokens.space4) {
            AddSheetHeader(title: "Import links",
                           subtitle: "Paste text with links in it. Each one is queued with the preset you choose.",
                           symbol: "list.bullet.rectangle")
            editor
            HStack(spacing: Tokens.space3) {
                Label {
                    Text(count == 1 ? "1 link found" : "\(count) links found")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                } icon: {
                    Image(systemName: count > 0 ? "link" : "link.badge.plus")
                }
                .font(.system(size: 12))
                .foregroundStyle(count > 0 ? .primary : .secondary)
                .accessibilityElement(children: .combine)
                if let fileError {
                    Text(fileError).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
                }
                Spacer()
                Button(action: openFile) {
                    Label("Open Text File…", systemImage: "doc.text")
                }
                .buttonStyle(.glass)
                .accessibilityHint("Adds the links from a text file")
            }
        }
        .padding(Tokens.space5)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar(count: count) }
        .frame(width: 560, height: 520, alignment: .top)
        .onAppear(perform: load)
        .animation(reduceMotion ? nil : Tokens.quick, value: count)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 12).monospaced())
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(Tokens.space2)
                .accessibilityLabel("Links to import")
            if text.isEmpty {
                emptyState.allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.primary.opacity(0.04), in: .rect(cornerRadius: Tokens.radiusRow))
        .overlay(RoundedRectangle(cornerRadius: Tokens.radiusRow).strokeBorder(.primary.opacity(editorFocused ? 0.18 : 0.08)))
    }

    private var emptyState: some View {
        VStack(spacing: Tokens.space2) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No links yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Paste a list, one link per line. Text around the links is ignored, so you can paste a whole email or note.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    private func bottomBar(count: Int) -> some View {
        SheetBottomBar {
            Picker(selection: Binding(get: { preset.id }, set: { presetID = $0 })) {
                ForEach(settings.prefs.allPresets) { preset in
                    Label(preset.name, systemImage: preset.symbol).tag(preset.id)
                }
            } label: {
                Text("Preset").foregroundStyle(.secondary)
            }
            .fixedSize()
            .accessibilityLabel("Preset for imported links")
        } trailing: {
            Button("Cancel", role: .cancel, action: close)
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Button(action: addAll) {
                Label(count == 1 ? "Add 1 Download" : "Add \(count) Downloads", systemImage: "arrow.down")
                    .monospacedDigit()
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(count == 0)
        }
        .controlSize(.large)
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        text = appState.batchImportText
        presetID = settings.prefs.defaultPreset.id
        editorFocused = true
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add Links"
        panel.message = "Choose text files that contain links."
        guard panel.runModal() == .OK else { return }
        var failed: [String] = []
        for url in panel.urls {
            do {
                let contents = try String(contentsOf: url, encoding: .utf8)
                if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
                text += contents
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        fileError = failed.isEmpty ? nil : "Couldn't read \(failed.joined(separator: ", "))."
    }

    private func addAll() {
        let chosen = preset
        for link in links { manager.quickDownload(url: link, preset: chosen) }
        close()
    }

    private func close() {
        appState.batchImportText = ""
        appState.isBatchImportPresented = false
        dismiss()
    }
}
