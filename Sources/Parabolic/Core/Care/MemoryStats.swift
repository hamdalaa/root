import Darwin
import Foundation

// MARK: - Raw counts

/// The subset of `vm_statistics64` the memory screen needs, as plain numbers so tests can build one by hand.
struct MemoryVMCounts: Equatable, Sendable {
    var pageSize: UInt64
    var free: UInt64 = 0
    var active: UInt64 = 0
    var inactive: UInt64 = 0
    var speculative: UInt64 = 0
    var wired: UInt64 = 0
    var purgeable: UInt64 = 0
    /// Anonymous pages (app heaps, stacks).
    var internalPages: UInt64 = 0
    /// File-backed pages (the file cache).
    var externalPages: UInt64 = 0
    /// Physical pages the compressor occupies.
    var compressorPages: UInt64 = 0
    /// Pages of data the compressor is holding, before compression.
    var uncompressedInCompressor: UInt64 = 0
    var pageins: UInt64 = 0
    var pageouts: UInt64 = 0
    var swapins: UInt64 = 0
    var swapouts: UInt64 = 0
}

// MARK: - Activity Monitor breakdown

/// Activity Monitor's memory categories, in bytes.
struct MemoryBreakdown: Equatable, Sendable {
    let total: UInt64
    /// Anonymous memory apps are actively holding (internal − purgeable).
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    /// File cache plus purgeable memory: macOS gives this back instantly when apps need it.
    let cached: UInt64
    let free: UInt64
    /// How much data the compressor holds before compression.
    let compressedOriginal: UInt64

    init(counts c: MemoryVMCounts, total: UInt64) {
        let page = c.pageSize
        let appPages = c.internalPages > c.purgeable ? c.internalPages - c.purgeable : 0
        self.total = total
        app = appPages * page
        wired = c.wired * page
        compressed = c.compressorPages * page
        cached = (c.externalPages + c.purgeable) * page
        free = c.free * page
        compressedOriginal = c.uncompressedInCompressor * page
    }

    /// "Memory Used" in Activity Monitor.
    var used: UInt64 { app + wired + compressed }

    /// Free memory plus memory macOS can reclaim without asking any app.
    var available: UInt64 { cached + free }

    /// Installed RAM the VM counters don't account for (firmware and hardware reservations). Never negative.
    var other: UInt64 {
        let counted = used + cached + free
        return total > counted ? total - counted : 0
    }

    /// How many bytes of data each byte of compressed memory holds (e.g. 2.4). Nil when nothing is compressed.
    var compressionRatio: Double? {
        guard compressed > 0, compressedOriginal > 0 else { return nil }
        return Double(compressedOriginal) / Double(compressed)
    }

    func fraction(_ bytes: UInt64) -> Double {
        total > 0 ? Double(bytes) / Double(total) : 0
    }
}

// MARK: - Pressure

/// The kernel's own memory-pressure state (`kern.memorystatus_vm_pressure_level`).
enum MemoryPressureLevel: Int, Sendable, Comparable {
    case normal = 1
    case warning = 2
    case critical = 4

    init?(sysctlValue: Int32) {
        switch sysctlValue {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: return nil
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }
}

struct MemorySwap: Equatable, Sendable {
    let total: UInt64
    let used: UInt64
}

// MARK: - Snapshot

/// One reading of everything the hero and charts show.
struct MemorySnapshot: Sendable {
    let date: Date
    let counts: MemoryVMCounts
    let breakdown: MemoryBreakdown
    let pressure: MemoryPressureLevel?
    /// 0–100. Derived from `kern.memorystatus_level` (the share macOS considers free); nil if unreadable.
    let pressurePercent: Double?
    let swap: MemorySwap?
}

enum MemorySamplerError: LocalizedError {
    case hostStatistics(kern_return_t)
    case physicalMemory

    var errorDescription: String? {
        switch self {
        case .hostStatistics(let code): "macOS refused to report memory statistics (Mach error \(code))."
        case .physicalMemory: "Couldn’t read the amount of installed memory."
        }
    }
}

/// Reads the live counters. Every call is cheap (a few syscalls) and safe from any thread.
enum MemorySampler {
    private static let host = mach_host_self()

    static func read(now: Date = Date()) throws -> MemorySnapshot {
        let counts = try vmCounts()
        guard let total: UInt64 = sysctlValue("hw.memsize"), total > 0 else { throw MemorySamplerError.physicalMemory }
        let level: Int32? = sysctlValue("kern.memorystatus_vm_pressure_level")
        let freeLevel: Int32? = sysctlValue("kern.memorystatus_level")
        let percent = freeLevel.flatMap { (0...100).contains($0) ? Double(100 - $0) : nil }
        return MemorySnapshot(date: now, counts: counts, breakdown: MemoryBreakdown(counts: counts, total: total),
                              pressure: level.flatMap(MemoryPressureLevel.init(sysctlValue:)),
                              pressurePercent: percent, swap: swapUsage())
    }

    private static func vmCounts() throws -> MemoryVMCounts {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw MemorySamplerError.hostStatistics(result) }
        var pageSize: vm_size_t = 0
        if host_page_size(host, &pageSize) != KERN_SUCCESS || pageSize == 0 { pageSize = vm_size_t(getpagesize()) }
        return MemoryVMCounts(
            pageSize: UInt64(pageSize),
            free: UInt64(stats.free_count),
            active: UInt64(stats.active_count),
            inactive: UInt64(stats.inactive_count),
            speculative: UInt64(stats.speculative_count),
            wired: UInt64(stats.wire_count),
            purgeable: UInt64(stats.purgeable_count),
            internalPages: UInt64(stats.internal_page_count),
            externalPages: UInt64(stats.external_page_count),
            compressorPages: UInt64(stats.compressor_page_count),
            uncompressedInCompressor: UInt64(stats.total_uncompressed_pages_in_compressor),
            pageins: UInt64(stats.pageins),
            pageouts: UInt64(stats.pageouts),
            swapins: UInt64(stats.swapins),
            swapouts: UInt64(stats.swapouts))
    }

    private static func swapUsage() -> MemorySwap? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return MemorySwap(total: usage.xsu_total, used: usage.xsu_used)
    }

    private static func sysctlValue<T: FixedWidthInteger>(_ name: String) -> T? {
        var value: T = 0
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
