import AppKit
import SwiftUI

/// Real behind-window glass: the desktop and other windows blur through the whole window.
struct WindowGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Makes the hosting NSWindow non-opaque so `WindowGlass` can show what's behind it.
struct TransparentWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window, window.isOpaque else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
    }
}

extension View {
    /// Full-window Apple glass background.
    func windowGlass(_ material: NSVisualEffectView.Material = .sidebar) -> some View {
        background {
            ZStack {
                TransparentWindow()
                WindowGlass(material: material)
            }
            .ignoresSafeArea()
        }
        .containerBackground(.clear, for: .window)
    }
}
