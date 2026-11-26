import Foundation

/// IDM/FDM-style categories used to sort finished files into subfolders.
enum FileCategory: String, CaseIterable, Sendable {
    case video = "Video", music = "Music", documents = "Documents", archives = "Archives",
         apps = "Apps", images = "Images", torrents = "Torrents", other = "Other"

    static func of(filename: String, engine: DownloadEngine, fileType: MediaFileType) -> FileCategory {
        if engine == .torrent { return .torrents }
        if engine == .media { return fileType.isAudio ? .music : .video }
        switch (filename as NSString).pathExtension.lowercased() {
        case "mp4", "mkv", "mov", "avi", "webm", "m4v", "flv", "wmv": return .video
        case "mp3", "flac", "wav", "m4a", "aac", "ogg", "opus", "aiff": return .music
        case "pdf", "epub", "mobi", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv", "rtf", "pages", "numbers", "key": return .documents
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst": return .archives
        case "dmg", "pkg", "app", "exe", "msi", "apk", "ipa", "deb", "rpm", "appimage", "xapk": return .apps
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "tiff", "bmp", "psd": return .images
        default: return .other
        }
    }
}

/// Unpacks finished archives next to themselves (zip via ditto, tarballs via tar).
enum ArchiveExtractor {
    static func canExtract(_ path: String) -> Bool {
        let lower = path.lowercased()
        return [".zip", ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tar.xz"].contains { lower.hasSuffix($0) }
    }

    /// Extracts into a sibling folder named after the archive. Returns the folder on success.
    static func extract(_ path: String) async -> String? {
        let url = URL(fileURLWithPath: path)
        var base = url.deletingPathExtension()
        if base.pathExtension.lowercased() == "tar" { base = base.deletingPathExtension() }
        var destination = base
        var n = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = URL(fileURLWithPath: base.path + " \(n)")
            n += 1
        }
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let (tool, args): (String, [String]) = path.lowercased().hasSuffix(".zip")
            ? ("/usr/bin/ditto", ["-x", "-k", path, destination.path])
            : ("/usr/bin/tar", ["-xf", path, "-C", destination.path])
        let result = try? await ProcessRunner.capture(executable: tool, arguments: args)
        guard result?.status == 0 else {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
        return destination.path
    }
}
