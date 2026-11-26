import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppCommands: Commands {
    let services: Services

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Set Up Root…") {
                NSApp.activate()
                services.appState.isSetupGuidePresented = true
            }
            Button("Force Quit Applications…") { ForceQuitWindowController.shared.show() }
                .keyboardShortcut(.escape, modifiers: [.command, .option, .control])
        }
        CommandGroup(replacing: .newItem) {
            Button("New Download…") { services.appState.presentAdd() }
                .keyboardShortcut("n")
            Button("Open Torrent File…") { openTorrentFiles() }
                .keyboardShortcut("o")
            Divider()
            Button("Download Link from Clipboard") {
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                services.appState.presentAdd(url: LinkScanner.firstLink(in: text) ?? "")
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Quick Download from Clipboard") {
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                if let url = LinkScanner.firstLink(in: text) { services.manager.quickDownload(url: url) }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Import Links…") { services.appState.presentBatchImport() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandMenu("Downloads") {
            Button("Pause All") { services.manager.pauseAll() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Resume All") { services.manager.resumeAll() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Stop All") { services.manager.stopAll() }
                .keyboardShortcut(".", modifiers: [.command, .option])
            Divider()
            Button("Retry Failed") { services.manager.retryFailed() }
            Button("Clear Finished") { services.manager.clearFinished() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Button("Show Inspector") { services.appState.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Open Downloads Folder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: services.settings.prefs.downloadFolder))
            }
        }
    }

    /// Picks one or more .torrent files and starts each straight away (aria2 reads them from disk).
    @MainActor
    private func openTorrentFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.prompt = "Download"
        panel.message = "Choose torrent files to download."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { services.manager.quickDownload(url: url.path) }
    }
}
