import CryptoKit
import Foundation

/// Streams a file through SHA-256 (1 MB chunks) off the main thread.
enum Checksum {
    static func sha256(of path: String) async -> String? {
        await Task.detached(priority: .utility) {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    /// Accepts an expected hash pasted in any case / with spaces.
    static func matches(_ actual: String, expected: String) -> Bool {
        let clean = expected.lowercased().filter(\.isHexDigit)
        return !clean.isEmpty && clean == actual.lowercased()
    }
}
