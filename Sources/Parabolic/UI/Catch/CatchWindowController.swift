import AppKit
import SwiftUI

/// FDM-style popups for caught downloads: floating glass panels in the top-right corner that appear over the
/// browser without activating Root's main window, and stack under each other if several arrive together.
@MainActor
final class CatchWindowController {
    static let shared = CatchWindowController()
    private var panels: [UUID: NSPanel] = [:]
    /// Download history for "you downloaded this before" notes. Read from the shared services on first use,
    /// so the browser-request call site doesn't need another parameter.
    private(set) lazy var history: HistoryStore = Services.shared.history

    func present(_ item: BrowserItem, manager: DownloadManager, settings: AppSettings) {
        let prefs = settings.prefs
        let model = CatchModel(source: item, folder: CatchFlow.startFolder(prefs: prefs), startPaused: prefs.catchStartPaused,
                               preset: prefs.preset(for: Platform.detect(url: item.url)))
        // Borderless: no titlebar, so the panel is exactly as tall as its content (a hidden titlebar still
        // reserves its height). Cancel / Esc close it.
        let panel = CatchPanel(contentRect: NSRect(x: 0, y: 0, width: CatchView.width, height: 260),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let id = model.id
        let services = Services.shared
        let root = CatchView(model: model, manager: manager, settings: settings, history: history, tools: services.tools.paths,
                             lastSpeedTest: services.speedTest.history.first) { [weak self] in self?.dismiss(id) }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak self] height in
                self?.resize(id, toHeight: height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .windowGlass()
            .overlay(RoundedRectangle(cornerRadius: Tokens.radiusWindowCard, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        let host = NSHostingController(rootView: root)
        // The panel is sized by `resize` below, never by the hosting controller: letting SwiftUI resize the
        // window inside AppKit's layout pass crashed when «More details» animated open (constraint-pass loop).
        host.sizingOptions = []
        panel.contentViewController = host
        // Root's window-card radius; the layer mask also clips the behind-window glass.
        host.view.wantsLayer = true
        host.view.layer?.cornerRadius = Tokens.radiusWindowCard
        host.view.layer?.cornerCurve = .continuous
        host.view.layer?.masksToBounds = true
        let initial = host.sizeThatFits(in: CGSize(width: CatchView.width, height: 2_000))
        panel.setContentSize(NSSize(width: CatchView.width, height: ceil(initial.height)))

        position(panel)
        panels[id] = panel
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panels[id] = nil }
        }
        panel.alphaValue = 0
        // From a browser: key but non-activating (like Spotlight), so Return = Download and Esc = Cancel work at
        // once while the browser stays the active app and gets the keyboard back when the popup closes.
        // From any other app: shown without the keyboard (a click makes it key), so typing there never lands here.
        if CatchFocus.takesKeyboardNow() {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.becomesKeyOnlyIfNeeded = true
            panel.orderFrontRegardless()
        }
        // Nothing focused at first: typed keys must never replace the file name by accident (click it to edit).
        DispatchQueue.main.async { panel.makeFirstResponder(nil) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    /// Grows or shrinks the panel to the content, keeping its top edge where it is (it hangs from the corner).
    /// Runs on the next turn of the run loop, outside AppKit's layout pass.
    private func resize(_ id: UUID, toHeight height: CGFloat) {
        DispatchQueue.main.async { [weak self] in
            guard let panel = self?.panels[id] else { return }
            let target = ceil(height)
            guard abs(panel.frame.height - target) >= 1 else { return }
            var frame = panel.frame
            frame.origin.y = frame.maxY - target
            frame.size.height = target
            panel.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            panel.invalidateShadow()
        }
    }

    private func dismiss(_ id: UUID) {
        guard let panel = panels[id] else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.close() }
        })
    }

    /// Top-right of the screen the user is on, under the popups already showing.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { panel.center(); return }
        let occupied = panels.values.filter(\.isVisible).map(\.frame)
        panel.setFrameOrigin(CatchPanelLayout.origin(for: panel.frame.size, occupied: occupied, in: screen.visibleFrame))
    }
}

/// A borderless panel can't become key by default; this one can, so Return / Esc and the name field work.
final class CatchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
