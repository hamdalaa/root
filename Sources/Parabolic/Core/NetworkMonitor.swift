import Darwin
import Foundation
import Observation

/// Live system-wide network throughput (all apps), sampled once a second from interface counters.
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var downloadBytesPerSecond: Double = 0
    private(set) var uploadBytesPerSecond: Double = 0
    /// Last 60 samples (bytes/s) for graphs.
    private(set) var downloadHistory: [Double] = []
    private(set) var uploadHistory: [Double] = []

    @ObservationIgnored private var last: (rx: UInt64, tx: UInt64, time: Date)?
    @ObservationIgnored private var timer: Timer?

    init() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    private func sample() {
        let now = Date()
        let (rx, tx) = Self.counters()
        if let last {
            let dt = max(0.2, now.timeIntervalSince(last.time))
            // 32-bit interface counters can wrap; ignore negative deltas.
            downloadBytesPerSecond = rx >= last.rx ? Double(rx - last.rx) / dt : 0
            uploadBytesPerSecond = tx >= last.tx ? Double(tx - last.tx) / dt : 0
            downloadHistory = Array((downloadHistory + [downloadBytesPerSecond]).suffix(60))
            uploadHistory = Array((uploadHistory + [uploadBytesPerSecond]).suffix(60))
        }
        last = (rx, tx, now)
    }

    /// Sums bytes in/out over active, non-loopback interfaces.
    nonisolated static func counters() -> (UInt64, UInt64) {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return (0, 0) }
        defer { freeifaddrs(pointer) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            rx += UInt64(data.pointee.ifi_ibytes)
            tx += UInt64(data.pointee.ifi_obytes)
        }
        return (rx, tx)
    }
}

/// Internet speed test against Cloudflare's public speed endpoints: latency, jitter, download, upload.
@MainActor
@Observable
final class SpeedTest {
    enum Phase: Equatable { case idle, latency, download, upload, done, failed(String) }

    struct Result: Codable, Hashable, Identifiable, Sendable {
        var id = UUID()
        var date: Date
        var pingMs: Double
        var jitterMs: Double
        var downloadMbps: Double
        var uploadMbps: Double
    }

    private(set) var phase: Phase = .idle
    /// Live value for the gauge while a phase runs (Mbps or ms).
    private(set) var liveMbps: Double = 0
    private(set) var pingMs: Double?
    private(set) var jitterMs: Double?
    private(set) var downloadMbps: Double?
    private(set) var uploadMbps: Double?
    private(set) var history: [Result] = []

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let historyURL = ToolStore.supportDirectory.appendingPathComponent("speedtests.json")
    nonisolated private static let base = "https://speed.cloudflare.com"

    init() {
        history = LossyDecoding.decodeArray(Result.self, from: historyURL, decoder: .iso)
    }

    var isRunning: Bool { [.latency, .download, .upload].contains(phase) }

    func start() {
        guard !isRunning else { return }
        task?.cancel()
        pingMs = nil; jitterMs = nil; downloadMbps = nil; uploadMbps = nil; liveMbps = 0
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
        phase = .idle
    }

    private func run() async {
        let session = URLSession(configuration: .ephemeral)
        do {
            phase = .latency
            var samples: [Double] = []
            for _ in 0..<8 {
                try Task.checkCancellation()
                let start = Date()
                _ = try await session.data(from: URL(string: "\(Self.base)/__down?bytes=0")!)
                samples.append(Date().timeIntervalSince(start) * 1000)
            }
            let sorted = samples.sorted()
            pingMs = sorted[sorted.count / 2]
            jitterMs = zip(samples, samples.dropFirst()).map { abs($0 - $1) }.reduce(0, +) / Double(max(1, samples.count - 1))

            phase = .download
            downloadMbps = try await measure(seconds: 8) { group, counter in
                for _ in 0..<6 {
                    group.addTask {
                        // Repeated 10 MB pulls per stream (byte-by-byte async iteration is too CPU-heavy).
                        while !Task.isCancelled {
                            let (data, _) = try await session.data(from: URL(string: "\(Self.base)/__down?bytes=10000000")!)
                            await counter.add(data.count)
                        }
                    }
                }
            }

            phase = .upload
            let payload = Data(count: 8_000_000)
            uploadMbps = try await measure(seconds: 8) { group, counter in
                for _ in 0..<4 {
                    group.addTask {
                        while !Task.isCancelled {
                            var request = URLRequest(url: URL(string: "\(Self.base)/__up")!)
                            request.httpMethod = "POST"
                            _ = try await session.upload(for: request, from: payload)
                            await counter.add(payload.count)
                        }
                    }
                }
            }

            phase = .done
            let result = Result(date: Date(), pingMs: pingMs ?? 0, jitterMs: jitterMs ?? 0,
                                downloadMbps: downloadMbps ?? 0, uploadMbps: uploadMbps ?? 0)
            history = Array(([result] + history).prefix(30))
            if let data = try? JSONEncoder.iso.encode(history) { try? data.write(to: historyURL, options: .atomic) }
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
        session.invalidateAndCancel()
    }

    /// Runs the workers for a fixed time, updating `liveMbps`, and returns the average Mbps.
    private func measure(seconds: Double,
                         _ workers: @escaping (inout ThrowingTaskGroup<Void, Error>, ByteCounter) -> Void) async throws -> Double {
        let counter = ByteCounter()
        let start = Date()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                let elapsed = max(0.25, Date().timeIntervalSince(start))
                self.liveMbps = Double(await counter.total) * 8 / elapsed / 1_000_000
            }
        }
        defer { ticker.cancel() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            workers(&group, counter)
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw CancellationError() }
            // The timer task ends the phase; workers loop until cancelled.
            do { while try await group.next() != nil {} } catch is CancellationError { }
            group.cancelAll()
        }
        let elapsed = max(0.5, Date().timeIntervalSince(start))
        return Double(await counter.total) * 8 / elapsed / 1_000_000
    }
}

actor ByteCounter {
    private(set) var total = 0
    func add(_ count: Int) { total += count }
}
