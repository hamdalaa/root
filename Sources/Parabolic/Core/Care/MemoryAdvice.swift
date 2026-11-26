import Foundation

// MARK: - Formatting

enum MemoryFormat {
    /// Binary units, matching Activity Monitor ("36 GB" for 36 GiB).
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }
}

// MARK: - Quit policy

enum MemoryQuitPolicy {
    /// Apps whose loss breaks the desktop session. Root itself is added at runtime.
    static let protectedBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.Spotlight",
        "com.apple.WindowManager", "com.apple.WindowServer", "com.apple.coreservices.uiagent",
        "com.apple.SecurityAgent", "com.apple.universalcontrol",
    ]

    /// Whether the screen may offer Quit / Force Quit for an app bundle.
    static func canQuit(bundleID: String?, bundlePath: String, ownBundleID: String?, ownBundlePath: String?) -> Bool {
        if let ownBundlePath, bundlePath == ownBundlePath { return false }
        if let bundleID {
            if bundleID == ownBundleID || protectedBundleIDs.contains(bundleID) { return false }
        }
        // CoreServices, private frameworks and other OS internals.
        if bundlePath.hasPrefix("/System/Library/") || bundlePath.hasPrefix("/Library/Apple/") { return false }
        return true
    }
}

// MARK: - Verdict

/// The biggest app the user could quit, measured.
struct MemoryCandidate: Equatable, Sendable {
    let name: String
    let footprint: UInt64
}

/// A plain-language reading of the current memory state.
struct MemoryVerdict: Equatable, Sendable {
    enum Severity: Equatable, Sendable { case ok, warning, critical, unknown }

    let severity: Severity
    let headline: String
    let detail: String

    /// Below this, quitting an app isn't worth suggesting.
    static let worthwhileFootprint: UInt64 = 256 << 20
    /// Swap smaller than this isn't worth mentioning.
    static let notableSwap: UInt64 = 1 << 30

    static func make(pressure: MemoryPressureLevel?, breakdown: MemoryBreakdown, swap: MemorySwap?,
                     candidate: MemoryCandidate?) -> MemoryVerdict {
        let candidate = candidate.flatMap { $0.footprint >= worthwhileFootprint ? $0 : nil }
        let swapUsed = swap?.used ?? 0
        switch pressure {
        case nil:
            return MemoryVerdict(
                severity: .unknown,
                headline: "Memory pressure isn’t available",
                detail: "macOS didn’t report a pressure level, so Root can’t judge how tight memory is. The figures below are still live.")
        case .normal:
            var detail = "\(MemoryFormat.bytes(breakdown.available)) is free or held as file cache that macOS hands back instantly when apps need it."
            if swapUsed >= notableSwap {
                detail += " \(MemoryFormat.bytes(swapUsed)) is still in swap from earlier, heavier use."
            }
            // Normal pressure with little left over is fine, but "plenty" would overstate it.
            let roomy = breakdown.available * 4 >= breakdown.used + breakdown.available
            let headline = roomy ? "Plenty of memory free" : "Memory is busy, but macOS is keeping up"
            return MemoryVerdict(severity: .ok, headline: headline, detail: detail)
        case .warning:
            let headline = candidate.map { "Memory is tight — \(relief(for: $0, used: breakdown.used))" } ?? "Memory is tight"
            var detail = "macOS is compressing memory to keep up: \(MemoryFormat.bytes(breakdown.compressed)) is compressed"
            detail += swapUsed > 0 ? " and \(MemoryFormat.bytes(swapUsed)) has moved to disk." : "."
            if candidate == nil { detail += " Close windows or tabs you aren’t using." }
            return MemoryVerdict(severity: .warning, headline: headline, detail: detail)
        case .critical:
            let headline = candidate.map { "Memory is critically low — \(relief(for: $0, used: breakdown.used))" }
                ?? "Memory is critically low"
            var detail = "Apps will slow down and macOS may pause some until memory is freed."
            if swapUsed > 0 { detail += " \(MemoryFormat.bytes(swapUsed)) is in swap." }
            if candidate == nil { detail += " Quit apps you aren’t using." }
            return MemoryVerdict(severity: .critical, headline: headline, detail: detail)
        }
    }

    /// "quitting Chrome would free about 3.1 GB". A footprint counts compressed and swapped memory too, so when it's
    /// bigger than all memory in use, promising to "free" it would overstate the gain; say what the app uses instead.
    private static func relief(for candidate: MemoryCandidate, used: UInt64) -> String {
        let amount = MemoryFormat.bytes(candidate.footprint)
        return candidate.footprint <= used
            ? "quitting \(candidate.name) would free about \(amount)"
            : "\(candidate.name) is using \(amount), counting what’s compressed or in swap"
    }
}

// MARK: - Purge

/// Measured effect of running `purge`.
struct MemoryPurgeResult: Equatable, Sendable {
    let freeBefore: UInt64
    let freeAfter: UInt64
    let cachedBefore: UInt64
    let cachedAfter: UInt64

    static let meaningfulGain: Int64 = 512 << 20

    var freeGain: Int64 { Int64(clamping: freeAfter) - Int64(clamping: freeBefore) }
    var cacheDrop: Int64 { Int64(clamping: cachedBefore) - Int64(clamping: cachedAfter) }

    var headline: String {
        freeGain > 0 ? "Free memory up \(MemoryFormat.bytes(freeGain))" : "Free memory didn’t go up"
    }

    var summary: String {
        let range = "\(MemoryFormat.bytes(freeBefore)) before, \(MemoryFormat.bytes(freeAfter)) after."
        if freeGain >= Self.meaningfulGain {
            return "\(range) Most of it was file cache, which macOS refills as you open files again."
        }
        if freeGain > 0 {
            return "\(range) That’s small: macOS was already reclaiming cache on its own."
        }
        return "\(range) Apps took the space back straight away, which is normal. Purging rarely helps on a busy Mac."
    }
}

// MARK: - Suggestions

enum MemorySuggestions {
    /// Quittable apps that aren't in front, with footprints worth freeing, largest first.
    /// Terminals and editors are never suggested: by bundle id, or because they launched command-line tools.
    static func pick(_ groups: [MemoryGroup], apps: [String: MemoryAppInfo], limit: Int = 3) -> [MemoryGroup] {
        let hosts = MemoryGrouping.hostPaths(in: groups)
        return groups
            .filter { group in
                guard group.kind == .app, let path = group.bundlePath, let info = apps[path] else { return false }
                return info.canQuit && !info.isActive && !info.isHost && !hosts.contains(path)
                    && group.footprint >= MemoryVerdict.worthwhileFootprint
            }
            .sorted { $0.footprint > $1.footprint }
            .prefix(limit)
            .map { $0 }
    }
}
