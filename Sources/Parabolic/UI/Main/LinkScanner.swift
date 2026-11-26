import Foundation

/// Finds download links in free text: web links plus `magnet:?` links, which NSDataDetector skips.
enum LinkScanner {
    private static let magnetPattern = try? NSRegularExpression(pattern: #"magnet:\?[^\s"'<>]+"#, options: [.caseInsensitive])

    /// Every magnet link in the text, in order.
    static func magnets(in text: String) -> [String] {
        guard let magnetPattern else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return magnetPattern.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    /// Magnets first, then web links, without duplicates.
    static func allLinks(in text: String) -> [String] {
        var seen = Set<String>()
        // Strip magnets before running the URL detector so their tracker URLs aren't picked up as separate links.
        var remainder = text
        let found = magnets(in: text)
        for magnet in found { remainder = remainder.replacingOccurrences(of: magnet, with: " ") }
        return (found + ClipboardWatcher.allURLs(in: remainder)).filter { seen.insert($0).inserted }
    }

    /// The first magnet or web link in the text.
    static func firstLink(in text: String) -> String? {
        magnets(in: text).first ?? ClipboardWatcher.firstURL(in: text)
    }
}
