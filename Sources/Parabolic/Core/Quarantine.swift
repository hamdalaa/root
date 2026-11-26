import Foundation

/// Marks finished files as downloaded from the internet, so Gatekeeper checks apps and installers
/// before they first open (the same "mark of the web" browsers apply).
enum Quarantine {
    /// Marks a torrent's whole top-level folder (multi-file torrents), staying inside the save folder.
    static func markTree(_ path: String, within folder: String) {
        let base = (folder as NSString).standardizingPath
        let relative = (path as NSString).standardizingPath.replacingOccurrences(of: base + "/", with: "")
        guard let top = relative.split(separator: "/").first else { return mark(path) }
        let root = (base as NSString).appendingPathComponent(String(top))
        mark(root)
        if let walker = FileManager.default.enumerator(atPath: root) {
            for case let child as String in walker { mark((root as NSString).appendingPathComponent(child)) }
        }
    }

    static func mark(_ path: String) {
        let value = String(format: "0081;%08x;Parabolic;", Int(Date().timeIntervalSince1970))
        _ = value.withCString { setxattr(path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    }
}
