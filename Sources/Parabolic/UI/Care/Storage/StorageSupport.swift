import AppKit
import SwiftUI

/// Finder icons for paths, cached for the session so long lists don't hit NSWorkspace on every redraw.
@MainActor
enum StorageIcons {
    private static var cache: [String: NSImage] = [:]

    static func image(for url: URL) -> Image {
        let path = url.path
        if let cached = cache[path] { return Image(nsImage: cached) }
        let icon = NSWorkspace.shared.icon(forFile: path)
        if cache.count > 3000 { cache.removeAll(keepingCapacity: true) }
        cache[path] = icon
        return Image(nsImage: icon)
    }

    static func forget(_ url: URL) { cache[url.path] = nil }
}

/// Small Finder-ish actions shared by the explorer and Large Files.
@MainActor
enum StorageFinder {
    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        FinderReveal.reveal(urls)
    }

    static func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// Asks for a folder to explore.
    static func chooseFolder(startingAt directory: URL?, completion: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Explore"
        panel.message = "Choose a folder or disk to see what’s using its space."
        panel.directoryURL = directory
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { completion(url) }
        }
    }
}

/// What a pending Move to Trash will do, phrased for the confirmation dialog.
struct StorageTrashRequest: Identifiable {
    let urls: [URL]
    let bytes: Int64
    let fileCount: Int
    /// Protected items in the selection that won't be moved.
    var skipped = 0
    var id: [URL] { urls }

    var title: String {
        urls.count == 1 ? "Move “\(urls[0].lastPathComponent)” to the Trash?" : "Move \(urls.count) items to the Trash?"
    }

    var message: String {
        let size = Format.bytes(bytes)
        let contents = fileCount > 1 ? " (\(fileCount.formatted()) files)" : ""
        var text = "This frees \(size)\(contents) once you empty the Trash. Until then you can put \(urls.count == 1 ? "it" : "them") back from the Trash."
        if skipped > 0 { text += " \(skipped) protected item\(skipped == 1 ? " is" : "s are") left where \(skipped == 1 ? "it is" : "they are")." }
        return text
    }
}

/// Inline notice for folders Root couldn't read, with the way to fix it.
struct StoragePermissionNotice: View {
    let unreadable: Int
    var samples: [String] = []
    let hasFullDiskAccess: Bool

    @State private var showsPaths = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.system(size: 12, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !samples.isEmpty {
                    Button(showsPaths ? "Hide" : "Show") { showsPaths.toggle() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .accessibilityLabel(showsPaths ? "Hide unreadable folders" : "Show unreadable folders")
                }
                if !hasFullDiskAccess {
                    Button("Open Full Disk Access Settings") { StorageSafety.openFullDiskAccessSettings() }
                        .controlSize(.small)
                        .buttonStyle(.glass)
                }
            }
            if showsPaths {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(samples, id: \.self) { path in
                        Text(StorageLargeFileSearch.abbreviate(path))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    if unreadable > samples.count {
                        Text("and \(unreadable - samples.count) more")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 26)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.yellow.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.yellow.opacity(0.22)))
        .accessibilityElement(children: .contain)
    }

    private var headline: String {
        "\(unreadable.formatted()) folder\(unreadable == 1 ? "" : "s") couldn’t be read"
    }

    private var detail: String {
        hasFullDiskAccess
            ? "They’re protected even with Full Disk Access, so the sizes here leave them out."
            : "Sizes here leave them out. Give Root Full Disk Access to measure everything."
    }
}

/// A full-pane state (empty, error, first run) with a symbol, copy and actions.
struct StorageStateView<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = .secondary
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) { actions }
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Percent with one decimal below 10 %, whole numbers above, "<0.1 %" for slivers.
enum StoragePercent {
    static func text(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0, part > 0 else { return "0%" }
        let value = Double(part) / Double(whole) * 100
        if value < 0.1 { return "<0.1%" }
        if value < 10 { return value.formatted(.number.precision(.fractionLength(1))) + "%" }
        return "\(Int(value.rounded()))%"
    }
}
