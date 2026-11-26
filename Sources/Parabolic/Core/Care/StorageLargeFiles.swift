import Darwin
import Foundation

// MARK: - Kinds

/// What a large file is, for filtering and icons.
enum StorageFileKind: String, CaseIterable, Identifiable, Sendable {
    case video, audio, image, archive, diskImage, app, installer, virtualMachine, document, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Images"
        case .archive: "Archives"
        case .diskImage: "Disk images"
        case .app: "Apps"
        case .installer: "Installers"
        case .virtualMachine: "Virtual machines"
        case .document: "Documents"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        case .archive: "doc.zipper"
        case .diskImage: "opticaldiscdrive"
        case .app: "app.dashed"
        case .installer: "shippingbox"
        case .virtualMachine: "pc"
        case .document: "doc.richtext"
        case .other: "doc"
        }
    }

    private static let byExtension: [String: StorageFileKind] = {
        var map: [String: StorageFileKind] = [:]
        func add(_ kind: StorageFileKind, _ list: String) { for ext in list.split(separator: " ") { map[String(ext)] = kind } }
        add(.video, "mp4 m4v mov mkv avi webm wmv flv mpg mpeg ts m2ts mts 3gp vob prores braw r3d")
        add(.audio, "mp3 m4a m4b aac wav aiff aif flac ogg opus alac caf wma")
        add(.image, "jpg jpeg png heic heif tif tiff psd psb cr2 cr3 nef arw dng raf orf gif webp exr")
        add(.archive, "zip gz tgz bz2 tbz xz txz 7z rar tar zst lz4 lzma cpio xip aar")
        add(.diskImage, "dmg iso img sparseimage sparsebundle toast cdr udif")
        add(.app, "app")
        add(.installer, "pkg mpkg ipa apk aab exe msi deb rpm appimage")
        add(.virtualMachine, "vmdk vdi qcow2 qcow vhd vhdx utm pvm vmwarevm hdd vmem nvram ova ovf")
        add(.document, "pdf doc docx key pages numbers ppt pptx xls xlsx epub csv sqlite db")
        return map
    }()

    /// Classifies by file extension first, then by Spotlight's content type tree when the extension is unknown.
    static func classify(path: String, contentTypes: [String] = []) -> StorageFileKind {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "docker.raw" || name.hasSuffix(".vmwarevm") { return .virtualMachine }
        let ext = (name as NSString).pathExtension
        if let kind = byExtension[ext] { return kind }
        let types = Set(contentTypes)
        if types.contains("com.apple.application-bundle") || types.contains("com.apple.application") { return .app }
        if types.contains("public.movie") || types.contains("public.video") { return .video }
        if types.contains("public.audio") { return .audio }
        if types.contains("public.image") { return .image }
        if types.contains("public.disk-image") { return .diskImage }
        if types.contains("public.archive") || types.contains("public.zip-archive") { return .archive }
        if types.contains("public.composite-content") || types.contains("public.text") { return .document }
        return .other
    }
}

// MARK: - Model

/// A file (or app bundle) above the size threshold.
struct StorageLargeFile: Identifiable, Hashable, Sendable {
    let url: URL
    /// The file's size as Spotlight / stat report it.
    let size: Int64
    /// Space it actually takes on disk; smaller than `size` for sparse files such as VM disks.
    let allocated: Int64?
    let lastUsed: Date?
    let kind: StorageFileKind
    let protectionReason: String?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    /// What moving it to the Trash and emptying it would free.
    var diskBytes: Int64 { allocated ?? size }
    var isSparse: Bool { (allocated ?? size) < size / 10 * 9 }
    var canTrash: Bool { protectionReason == nil }

    /// Parent folder with the home folder shortened to "~".
    var location: String {
        StorageLargeFileSearch.abbreviate(url.deletingLastPathComponent().path)
    }
}

/// The size thresholds offered in Large Files.
enum StorageThreshold: Int64, CaseIterable, Identifiable, Sendable {
    case mb100 = 100_000_000
    case mb500 = 500_000_000
    case gb1 = 1_000_000_000
    case gb5 = 5_000_000_000

    var id: Int64 { rawValue }
    var title: String {
        switch self {
        case .mb100: "100 MB"
        case .mb500: "500 MB"
        case .gb1: "1 GB"
        case .gb5: "5 GB"
        }
    }
}

// MARK: - Search

enum StorageLargeFileSearch {
    /// Where Large Files looks: your home folder plus every other local, browsable volume.
    static func scopes(volumes: [StorageVolume], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [home] + volumes.filter { !$0.isRoot && $0.isLocal }.map(\.url)
    }

    /// Reads `mdutil -s` output. True when indexed, false when Spotlight is off for the volume, nil when it can't tell.
    static func parseIndexingStatus(_ output: String) -> Bool? {
        let text = output.lowercased()
        if text.contains("indexing disabled") || text.contains("server is disabled") || text.contains("no index") { return false }
        if text.contains("indexing enabled") || text.contains("read-only") { return true }
        return nil
    }

    /// Asks Spotlight whether `volume` is indexed. Nil when mdutil can't say.
    static func isIndexed(_ volume: URL) async -> Bool? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
            process.arguments = ["-s", volume.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parseIndexingStatus(String(decoding: data, as: UTF8.self))
        }.value
    }

    /// Files at or above `minimum`, optionally of one kind, largest first.
    static func filter(_ files: [StorageLargeFile], minimum: Int64, kind: StorageFileKind? = nil) -> [StorageLargeFile] {
        files.filter { $0.size >= minimum && (kind == nil || $0.kind == kind) }
            .sorted { $0.diskBytes != $1.diskBytes ? $0.diskBytes > $1.diskBytes : $0.name < $1.name }
    }

    /// Paths Large Files never lists: inside app or library bundles, the Trash, and Spotlight / system bookkeeping.
    static func isExcluded(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        if parts.first == "System" { return true }
        for part in parts.dropLast() {
            if skippedFolderNames.contains(String(part)) { return true }
            if let ext = part.split(separator: ".").last, part.contains("."),
               bundleExtensions.contains(ext.lowercased()) { return true }
        }
        return false
    }

    static func abbreviate(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static let skippedFolderNames: Set<String> = [".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd",
                                                  ".DocumentRevisions-V100", ".TemporaryItems", ".MobileBackups"]
    private static let bundleExtensions: Set<String> = ["app", "framework", "bundle", "plugin", "kext", "xpc", "appex",
                                                        "photoslibrary", "musiclibrary", "tvlibrary", "sparsebundle",
                                                        "utm", "pvm", "vmwarevm", "xcarchive", "lproj", "dext"]
    private static let reportedBundleExtensions: Set<String> = ["app", "utm", "pvm", "vmwarevm", "sparsebundle",
                                                                "photoslibrary", "musiclibrary", "tvlibrary", "xcarchive"]

    /// Builds a result from a path and size, measuring what it takes on disk. Nil if the file is gone or excluded.
    static func makeFile(path: String, size: Int64?, lastUsed: Date?, contentTypes: [String]) -> StorageLargeFile? {
        guard !isExcluded(path) else { return nil }
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT != S_IFLNK else { return nil }
        let url = URL(fileURLWithPath: path)
        let isDirectory = st.st_mode & S_IFMT == S_IFDIR
        let allocated: Int64 = isDirectory
            ? StorageScanner.walk(url, recordDepth: -1).bytes
            : StorageScanner.allocated(st)
        let logical = isDirectory ? max(size ?? 0, allocated) : Int64(st.st_size)
        return StorageLargeFile(url: url, size: logical, allocated: allocated, lastUsed: lastUsed,
                                kind: StorageFileKind.classify(path: path, contentTypes: contentTypes),
                                protectionReason: StorageSafety.protectionReason(for: url))
    }

    // MARK: Filesystem fallback

    /// Walks `root` (without Spotlight) for files of at least `minimum` bytes. App bundles count as one item.
    /// `progress` gets the number of entries checked a few times a second.
    static func walk(_ root: URL, minimum: Int64, progress: ((Int) -> Void)? = nil) -> (files: [StorageLargeFile], unreadable: Int) {
        guard let cPath = strdup(root.path) else { return ([], 0) }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return ([], 1) }
        defer { fts_close(fts) }

        var files: [StorageLargeFile] = []
        var unreadable = 0
        var visited = 0
        var lastReport = DispatchTime.now().uptimeNanoseconds

        while let entry = fts_read(fts) {
            visited += 1
            if visited & 1023 == 0 {
                if Task.isCancelled { break }
                let now = DispatchTime.now().uptimeNanoseconds
                if now - lastReport > 200_000_000 { lastReport = now; progress?(visited) }
            }
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_D:
                guard entry.pointee.fts_level > 0 else { continue }
                let path = String(cString: entry.pointee.fts_path)
                let name = (path as NSString).lastPathComponent
                if skippedFolderNames.contains(name) || (entry.pointee.fts_level == 1 && name == "System") {
                    fts_set(fts, entry, FTS_SKIP)
                    continue
                }
                let ext = (name as NSString).pathExtension.lowercased()
                guard bundleExtensions.contains(ext) else { continue }
                fts_set(fts, entry, FTS_SKIP)
                // Apps, VMs, sparse bundles and media libraries count as one item, measured whole; other bundles are skipped.
                guard reportedBundleExtensions.contains(ext) else { continue }
                let bytes = StorageScanner.walk(URL(fileURLWithPath: path, isDirectory: true), recordDepth: -1).bytes
                if bytes >= minimum {
                    let url = URL(fileURLWithPath: path)
                    files.append(StorageLargeFile(url: url, size: bytes, allocated: bytes, lastUsed: nil,
                                                  kind: StorageFileKind.classify(path: path),
                                                  protectionReason: StorageSafety.protectionReason(for: url)))
                }
            case FTS_F:
                let st = entry.pointee.fts_statp.pointee
                guard Int64(st.st_size) >= minimum else { continue }
                let path = String(cString: entry.pointee.fts_path)
                let url = URL(fileURLWithPath: path)
                files.append(StorageLargeFile(url: url, size: Int64(st.st_size), allocated: StorageScanner.allocated(st),
                                              lastUsed: nil, kind: StorageFileKind.classify(path: path),
                                              protectionReason: StorageSafety.protectionReason(for: url)))
            case FTS_DNR, FTS_ERR:
                unreadable += 1
            default:
                break
            }
        }
        return (files, unreadable)
    }
}
