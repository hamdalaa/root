import Foundation

/// Limits how many async jobs run at once (e.g. yt-dlp lookups for a 300-link batch import).
actor AsyncGate {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func run<T: Sendable>(_ job: @Sendable () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await job()
    }

    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
