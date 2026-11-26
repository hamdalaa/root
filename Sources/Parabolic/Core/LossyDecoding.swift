import Foundation

/// Decodes a JSON array element by element so one bad/old record can't wipe the whole store.
/// When anything is dropped, the original file is kept as `<name>.bak` before it can be overwritten.
enum LossyDecoding {
    static func decodeArray<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let all = try? decoder.decode([T].self, from: data) { return all }
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            backup(url)
            return []
        }
        let decoded: [T] = raw.compactMap { element in
            guard let elementData = try? JSONSerialization.data(withJSONObject: element) else { return nil }
            return try? decoder.decode(T.self, from: elementData)
        }
        if decoded.count != raw.count { backup(url) }
        return decoded
    }

    private static func backup(_ url: URL) {
        let backupURL = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.copyItem(at: url, to: backupURL)
    }
}
