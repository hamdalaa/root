// Parabolic native-messaging host. Browsers start this with stdio; messages are
// 4-byte little-endian length + UTF-8 JSON in both directions (WebExtensions standard).
import AppKit
import Foundation

let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Parabolic", isDirectory: true)
let inbox = supportDir.appendingPathComponent("inbox", isDirectory: true)
let maxMessageBytes = 8 * 1024 * 1024

enum Incoming {
    case message([String: Any])
    /// Unreadable or oversized: answer with an error and keep serving instead of exiting.
    case rejected(String)
}

/// nil = stdin closed (the browser disconnected).
func readMessage() -> Incoming? {
    let header = FileHandle.standardInput.readData(ofLength: 4)
    guard header.count == 4 else { return nil }
    let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
    var body = Data()
    var remaining = length
    while remaining > 0 {
        let chunk = FileHandle.standardInput.readData(ofLength: min(remaining, 1 << 20))
        if chunk.isEmpty { return nil }
        remaining -= chunk.count
        if length <= maxMessageBytes { body.append(chunk) } // oversized bodies are drained, not kept
    }
    guard length > 0, length <= maxMessageBytes else { return .rejected("That request is too large.") }
    guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
        return .rejected("Unreadable request.")
    }
    return .message(object)
}

func send(_ object: [String: Any]) {
    guard let body = try? JSONSerialization.data(withJSONObject: object) else { return }
    var length = UInt32(body.count).littleEndian
    let header = Data(bytes: &length, count: 4)
    FileHandle.standardOutput.write(header + body)
}

/// Drops the request into the app's inbox and wakes the app with a URL it trusts only for UUID ids.
func handOff(_ message: [String: Any]) -> [String: Any] {
    let action = (message["action"] as? String) ?? "quick"
    guard ["quick", "add", "batch", "catch"].contains(action),
          let items = message["items"] as? [[String: Any]], !items.isEmpty else {
        return ["ok": false, "error": "Nothing to download."]
    }
    // Only http(s) and magnet links are accepted.
    let clean = items.compactMap { item -> [String: Any]? in
        guard let url = item["url"] as? String,
              url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("magnet:?") else { return nil }
        return item.filter { ["url", "pageURL", "referrer", "cookies", "userAgent", "filename", "title", "size", "mime"].contains($0.key) }
    }
    guard !clean.isEmpty else { return ["ok": false, "error": "No downloadable links."] }
    let id = UUID().uuidString
    var request: [String: Any] = ["action": action, "items": clean]
    if let preset = message["preset"] as? String { request["preset"] = preset }
    do {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: request)
        let file = inbox.appendingPathComponent("\(id).json")
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } catch {
        return ["ok": false, "error": "Couldn't reach Root (\(error.localizedDescription))."]
    }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = action != "quick" && action != "catch" // the catch window floats without stealing focus
    let semaphore = DispatchSemaphore(value: 0)
    var opened = false
    NSWorkspace.shared.open(URL(string: "parabolic://inbox?id=\(id)")!, configuration: config) { app, _ in
        opened = app != nil
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 10)
    // Never leave a cookie-bearing request behind if the app didn't take it.
    if !opened { try? FileManager.default.removeItem(at: inbox.appendingPathComponent("\(id).json")) }
    return opened ? ["ok": true, "count": clean.count] : ["ok": false, "error": "Root isn't installed."]
}

/// Live queue for the extension popup (titles, progress, status) — read from the app's saved queue.
func status() -> [String: Any] {
    // Prefer the app's live snapshot (progress + speed) when it's fresh.
    let live = supportDir.appendingPathComponent("live.json")
    if let data = try? Data(contentsOf: live),
       let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       let updated = object["updated"] as? Double, Date().timeIntervalSince1970 - updated < 30,
       let items = object["items"] as? [[String: Any]] {
        return ["ok": true, "live": true, "items": items]
    }
    let file = supportDir.appendingPathComponent("queue.json")
    guard let data = try? Data(contentsOf: file),
          let records = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
        return ["ok": true, "items": []]
    }
    let items = records.prefix(12).map { record -> [String: Any] in
        let meta = record["meta"] as? [String: Any] ?? [:]
        let options = record["options"] as? [String: Any] ?? [:]
        return ["title": meta["title"] ?? "", "status": record["status"] ?? "", "url": options["url"] ?? "",
                "thumbnail": meta["thumbnailURL"] ?? ""]
    }
    return ["ok": true, "items": items]
}

/// Catch rules the user set in Parabolic → Settings → Browser.
func settings() -> [String: Any] {
    let defaults = UserDefaults(suiteName: "com.hamad.parabolic")
    var prefs: [String: Any] = [:]
    if let data = defaults?.data(forKey: "preferences.v1"),
       let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { prefs = object }
    return [
        "ok": true,
        "catchDownloads": prefs["browserCatchDownloads"] as? Bool ?? true,
        "catchExtensions": prefs["browserCatchExtensions"] as? String
            ?? "zip rar 7z dmg pkg iso exe msi apk ipa tar gz tgz bz2 xz torrent mp4 mkv mov avi mp3 flac wav pdf epub",
        "minSizeMB": prefs["browserMinCatchSizeMB"] as? Int ?? 1,
        "skipHosts": prefs["browserSkipHosts"] as? String ?? "",
        "catchEverything": prefs["browserCatchEverything"] as? Bool ?? false,
        "showCatchWindow": prefs["browserShowCatchWindow"] as? Bool ?? true,
        "presets": ["Best Video", "1080p MP4", "MP3 320", "Lossless FLAC"]
            + ((prefs["customPresets"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []),
    ]
}

/// One line per browser connection (caller origin + time) so "not connected" can be diagnosed.
func logConnection(_ note: String) {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Parabolic", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("host.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(note)\n"
    if let handle = try? FileHandle(forWritingTo: file) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: file)
    }
}
logConnection("connected from \(CommandLine.arguments.dropFirst().first ?? "unknown")")

while let incoming = readMessage() {
    guard case .message(let message) = incoming else {
        if case .rejected(let reason) = incoming { send(["ok": false, "error": reason]) }
        continue
    }
    var reply: [String: Any]
    switch message["type"] as? String {
    case "handshake": reply = ["ok": true, "app": "Parabolic", "hostVersion": 1]
    case "download": reply = handOff(message)
    case "status": reply = status()
    case "settings": reply = settings()
    default: reply = ["ok": false, "error": "Unknown request."]
    }
    if let id = message["requestId"] { reply["requestId"] = id }
    if let type = message["type"] as? String, type != "status" { logConnection("\(type) → \(reply["ok"] as? Bool == true ? "ok" : "\(reply["error"] ?? "error")")") }
    send(reply)
}
