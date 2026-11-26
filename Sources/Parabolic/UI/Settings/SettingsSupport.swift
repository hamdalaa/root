import AppKit
import SwiftUI

/// Small building blocks shared by the settings panes.
enum SettingsSupport {
    /// Shows an NSOpenPanel and returns the chosen path, or nil when cancelled.
    @MainActor
    static func choose(directory: Bool, startingAt path: String?, prompt: String = "Choose") -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.canCreateDirectories = directory
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        if let path, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            panel.directoryURL = directory ? url : url.deletingLastPathComponent()
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    @MainActor static func reveal(_ path: String) {
        FinderReveal.reveal(paths: [path])
    }

    /// "~/Downloads" instead of "/Users/name/Downloads".
    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// Footer text in the native grouped-form style.
struct SettingsFooter: View {
    var text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Stepper row that shows its value as trailing monospaced text, like System Settings.
struct SettingsStepper: View {
    var title: String
    @Binding var value: Int
    var range: ClosedRange<Int>
    var step = 1
    var format: (Int) -> String = { "\($0)" }

    var body: some View {
        Stepper(value: $value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityValue(format(value))
    }
}

/// A keyboard shortcut drawn as individual keycaps, e.g. ⌃ ⌥ ⌘ D.
struct KeycapsView: View {
    var shortcut: String

    private static let spoken: [Character: String] = ["⌃": "Control", "⌥": "Option", "⌘": "Command", "⇧": "Shift", "⎋": "Escape"]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(shortcut.enumerated()), id: \.offset) { _, key in
                Text(String(key))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 22, minHeight: 22)
                    .background(.background.opacity(0.9), in: .rect(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.map { Self.spoken[$0] ?? String($0) }.joined(separator: " "))
    }
}

/// Coloured status dot used for tool availability.
struct SettingsStatusDot: View {
    var isOn: Bool

    var body: some View {
        Circle()
            .fill(isOn ? Color.green : Color.secondary.opacity(0.5))
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

extension AppSettings {
    /// Binding into one preference that writes only when the value actually changes.
    /// Assigning an unchanged value to the @Observable `prefs` still notifies observers and can loop the scene graph.
    func settingsBinding<Value: Equatable>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { self.prefs[keyPath: keyPath] },
            set: { self.setPref(keyPath, $0) })
    }

    /// Writes one preference, skipping no-op writes.
    func setPref<Value: Equatable>(_ keyPath: WritableKeyPath<Preferences, Value>, _ value: Value) {
        guard prefs[keyPath: keyPath] != value else { return }
        prefs[keyPath: keyPath] = value
    }

    /// Binding into a set-like array stored in preferences (used for SponsorBlock categories).
    func membership<Element: Equatable>(_ element: Element, in keyPath: WritableKeyPath<Preferences, [Element]>) -> Binding<Bool> {
        Binding(
            get: { self.prefs[keyPath: keyPath].contains(element) },
            set: { isOn in
                let current = self.prefs[keyPath: keyPath]
                let without = current.filter { $0 != element }
                self.setPref(keyPath, isOn ? without + [element] : without)
            })
    }
}
