import AppKit
import Observation

/// Notices links copied anywhere on the Mac so the UI can offer to download them.
@MainActor
@Observable
final class ClipboardWatcher {
    /// The most recent unseen copied link; UI clears it via `dismiss()`.
    private(set) var detectedURL: String?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChangeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var seen = Set<String>()

    func setEnabled(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled else { detectedURL = nil; return }
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func dismiss() {
        if let detectedURL { seen.insert(detectedURL) }
        detectedURL = nil
    }

    /// Marks a URL as handled so copying it again doesn't re-prompt.
    func markSeen(_ url: String) { seen.insert(url) }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string),
              let url = Self.firstURL(in: text), !seen.contains(url) else { return }
        detectedURL = url
    }

    /// First http(s) link in arbitrary text.
    nonisolated static func firstURL(in text: String) -> String? {
        allURLs(in: text).first
    }

    nonisolated static func allURLs(in text: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return url.absoluteString
        }
    }
}
