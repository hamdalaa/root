import AppKit
import SwiftUI

/// Main window toolbar: the URL capsule in the centre, add / quick download, layout switch and the inspector toggle.
struct MainToolbar: ToolbarContent {
    @Binding var urlText: String
    let manager: DownloadManager
    let settings: AppSettings
    let clipboard: ClipboardWatcher
    let appState: AppState
    @Binding var layout: DownloadsLayout

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            URLEntryField(text: $urlText, onSubmit: submit, onQuickSubmit: { quickDownload(preset: nil) })
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                appState.presentAdd(url: consumeFieldLink() ?? "")
            } label: {
                Label("New Download", systemImage: "plus")
            }
            .help("New Download (⌘N)")

            presetMenu
        }

        // Breathing room between the "add" group and the "view" group, like Apple's own toolbars.
        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            // Always present (disabled off the downloads screens): AppKit asserts when toolbar items
            // are inserted/removed on the fly, so the toolbar's item set must never change.
            Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) {
                        layout = layout == .list ? .grid : .list
                    }
                } label: {
                    Label(layout == .list ? "Show as Grid" : "Show as List",
                          systemImage: layout == .list ? "square.grid.2x2" : "list.bullet")
                        .contentTransition(.symbolEffect(.replace))
                }
            .help(layout == .list ? "Show as grid" : "Show as list")
            .disabled(!appState.sidebarSelection.showsDownloads)
            Button {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) { appState.showInspector.toggle() }
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(appState.showInspector ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
        }
    }

    private var presetMenu: some View {
        Menu {
            Section("Quick download the link in the field or clipboard") {
                ForEach(settings.prefs.allPresets) { preset in
                    Button { quickDownload(preset: preset) } label: {
                        Label(preset.id == settings.prefs.defaultPreset.id ? "\(preset.name) (Default)" : preset.name,
                              systemImage: preset.symbol)
                    }
                }
            }
        } label: {
            Label("Quick Download", systemImage: "bolt")
        }
        .help("Quick download with a preset")
    }

    // MARK: Actions

    /// Return: open the add sheet for whatever is typed.
    private func submit() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.presentAdd(url: LinkText.link(in: trimmed) ?? trimmed)
        urlText = ""
    }

    /// ⌥-Return and the preset menu: download immediately from the field, else the clipboard.
    /// With no explicit preset, the platform's own preset is used (`preset(for:)`).
    private func quickDownload(preset: DownloadPreset?) {
        guard let url = consumeFieldLink() ?? LinkText.clipboardLink else {
            NSSound.beep()
            return
        }
        manager.quickDownload(url: url, preset: preset ?? settings.prefs.preset(for: Platform.detect(url: url)))
        clipboard.markSeen(url)
        if clipboard.detectedURL == url { clipboard.dismiss() }
    }

    /// The link typed in the field, clearing the field when one is found.
    private func consumeFieldLink() -> String? {
        guard let link = LinkText.link(in: urlText) else { return nil }
        urlText = ""
        return link
    }
}
