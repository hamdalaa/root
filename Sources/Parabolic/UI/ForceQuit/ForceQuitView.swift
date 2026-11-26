import AppKit
import SwiftUI

/// The ⌃⌥⌘⎋ / menu-bar Force Quit panel: the same list as Mac Care → Force Quit, in a small floating window that
/// works with every Root window closed.
struct ForceQuitView: View {
    private var monitor: ForceQuitMonitor { .shared }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Tokens.space4)
                .padding(.top, 2)
                .padding(.bottom, Tokens.space1)
            ForceQuitList()
        }
        .frame(minWidth: 540, minHeight: 420)
        .task { await monitor.run() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Force Quit Applications")
                    .font(.system(size: 17, weight: .bold))
                Text(ForceQuitSummary.subtitle(monitor))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            ForceQuitShortcutHint()
        }
    }
}

/// "16 apps using 25.3 GB · 1 not responding".
enum ForceQuitSummary {
    @MainActor static func subtitle(_ monitor: ForceQuitMonitor) -> String {
        guard monitor.hasSampled else { return "Reading running apps…" }
        var parts = ["\(monitor.apps.count) apps using \(MemoryFormat.bytes(totalMemory(monitor)))"]
        let hung = monitor.notRespondingCount
        if hung > 0 { parts.append(hung == 1 ? "1 not responding" : "\(hung) not responding") }
        return parts.joined(separator: " · ")
    }

    @MainActor static func totalMemory(_ monitor: ForceQuitMonitor) -> UInt64 {
        monitor.apps.reduce(UInt64(0)) { $0 + $1.memory }
    }
}

/// ⌃⌥⌘⎋ keycap: the shortcut that opens Force Quit from any app.
struct ForceQuitShortcutHint: View {
    var body: some View {
        Text(GlobalHotKey.forceQuitDisplayString)
            .font(.system(size: 11, weight: .medium).monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 6))
            .help("Opens Force Quit from any app")
            .accessibilityLabel("Shortcut Control Option Command Escape")
    }
}

/// The Force Quit window: one floating panel, reused. Opens from the menu bar, the app menu and ⌃⌥⌘⎋.
/// Its content is removed on close, so the list stops sampling while the panel is hidden.
@MainActor
final class ForceQuitWindowController: NSObject, NSWindowDelegate {
    static let shared = ForceQuitWindowController()
    private var panel: NSPanel?

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.contentViewController == nil {
            // Setting a content controller resizes the window to the controller's view: keep the saved frame.
            let frame = panel.frame
            panel.contentViewController = makeContent()
            panel.setFrame(frame, display: false)
        }
        if !panel.isVisible { panel.center() }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Ends the list's `.task`, so sampling stops (the Mac Care page keeps its own).
        panel?.contentViewController = nil
    }

    private func makeContent() -> NSViewController {
        let host = NSHostingController(rootView: ForceQuitView()
            .windowGlass(.popover)
            .preferredColorScheme(Services.shared.settings.prefs.appearance.colorScheme))
        host.sizingOptions = []
        return host
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "Force Quit Applications"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentMinSize = NSSize(width: 540, height: 420)
        panel.contentViewController = makeContent()
        panel.setContentSize(NSSize(width: 600, height: 540))
        panel.setFrameAutosaveName("ForceQuitPanel")
        return panel
    }
}
