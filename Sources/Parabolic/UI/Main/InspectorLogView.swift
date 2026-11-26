import AppKit
import SwiftUI

/// yt-dlp output for one item: monospaced, follows new lines, copyable.
struct InspectorLogView: View {
    let item: DownloadItem

    @Environment(\.colorScheme) private var colorScheme
    @State private var didCopy = false

    /// Rendering thousands of lines in one Text is slow; show the tail, copy everything.
    private static let visibleLines = 600

    var body: some View {
        let full = item.logText
        let shown = tail(of: full)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Log")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    LinkText.copy([full])
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        didCopy = false
                    }
                } label: {
                    Label(didCopy ? "Copied" : "Copy Log", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(full.isEmpty)
            }
            .padding(.leading, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(shown.isEmpty ? "No output yet." : shown)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(shown.isEmpty ? .tertiary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                }
                .frame(height: 240)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.primary.opacity(0.07))
                )
                .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                .onChange(of: shown) { _, _ in proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Log")
    }

    private static let bottomID = "log-bottom"

    private func tail(of text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > Self.visibleLines else { return text }
        return "… \(lines.count - Self.visibleLines) earlier lines (Copy Log for everything)\n"
            + lines.suffix(Self.visibleLines).joined(separator: "\n")
    }
}
