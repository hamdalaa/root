import Darwin
import Foundation

enum ProcessRunnerError: LocalizedError {
    case spawnFailed(Int32)
    case nonZeroExit(Int32, String)

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let code): "Couldn't launch process (\(String(cString: strerror(code))))."
        case .nonZeroExit(let code, let stderr): stderr.isEmpty ? "Process exited with code \(code)." : stderr
        }
    }
}

/// A child process spawned into its own process group, so pause/resume/cancel reach
/// yt-dlp *and* the ffmpeg / aria2c children it launches.
final class ProcessRunner: @unchecked Sendable {
    let pid: pid_t
    private let outputHandle: FileHandle
    private let exitSource: DispatchSourceProcess
    private var buffer = Data()
    private let lock = NSLock()

    /// - Parameters:
    ///   - onLine: called on a background queue for each stdout/stderr line (CR and LF both end a line).
    ///   - onExit: called once with the exit status after all output has been delivered.
    init(executable: String, arguments: [String], environment: [String: String],
         onLine: @escaping @Sendable (String) -> Void,
         onExit: @escaping @Sendable (Int32) -> Void) throws {
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { throw ProcessRunnerError.spawnFailed(errno) }
        let readFD = pipeFDs[0], writeFD = pipeFDs[1]

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&fileActions, writeFD, 2)
        posix_spawn_file_actions_addclose(&fileActions, readFD)
        posix_spawn_file_actions_addclose(&fileActions, writeFD)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        // POSIX_SPAWN_CLOEXEC_DEFAULT closes everything not explicitly inherited; keep 0/1/2.
        posix_spawn_file_actions_addinherit_np(&fileActions, 0)
        posix_spawn_file_actions_addinherit_np(&fileActions, 1)
        posix_spawn_file_actions_addinherit_np(&fileActions, 2)

        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var childPID: pid_t = 0
        let status = posix_spawn(&childPID, executable, &fileActions, &attributes, argv, envp)
        close(writeFD)
        guard status == 0 else {
            close(readFD)
            throw ProcessRunnerError.spawnFailed(status)
        }
        pid = childPID
        outputHandle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)

        let queue = DispatchQueue(label: "parabolic.process.\(childPID)")
        exitSource = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: queue)

        let outputDone = DispatchSemaphore(value: 0)
        outputHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.flush(final: true, onLine: onLine)
                outputDone.signal()
            } else {
                self.append(chunk, onLine: onLine)
            }
        }

        exitSource.setEventHandler { [exitSource] in
            var raw: Int32 = 0
            waitpid(childPID, &raw, 0)
            // Wait (bounded) for the pipe to drain so the final lines arrive before onExit.
            _ = outputDone.wait(timeout: .now() + 2)
            let code: Int32 = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : -(raw & 0x7f)
            exitSource.cancel()
            onExit(code)
        }
        exitSource.resume()
    }

    private func append(_ chunk: Data, onLine: (String) -> Void) {
        lock.lock()
        buffer.append(chunk)
        var lines: [String] = []
        while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { lines.append(line) }
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    private func flush(final: Bool, onLine: (String) -> Void) {
        lock.lock()
        let rest = buffer
        buffer.removeAll()
        lock.unlock()
        if let line = String(data: rest, encoding: .utf8), !line.isEmpty { onLine(line) }
    }

    func suspend() { killpg(pid, SIGSTOP) }
    func resume() { killpg(pid, SIGCONT) }

    func terminate() {
        killpg(pid, SIGCONT)
        killpg(pid, SIGTERM)
        let pid = pid
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { killpg(pid, SIGKILL) }
    }

    // MARK: - One-shot capture

    struct Output: Sendable {
        var stdout: String
        var stderr: String
        var status: Int32
    }

    /// Runs a command to completion with stdout and stderr captured separately.
    /// Cancelling the calling task terminates the process.
    static func capture(executable: String, arguments: [String], environment: [String: String] = [:]) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        env["PYTHONIOENCODING"] = "utf-8"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let group = DispatchGroup()
                let box = CaptureBox()
                group.enter()
                group.enter()
                process.terminationHandler = { proc in
                    group.notify(queue: .global()) {
                        continuation.resume(returning: Output(
                            stdout: String(decoding: box.out, as: UTF8.self),
                            stderr: String(decoding: box.err, as: UTF8.self),
                            status: proc.terminationStatus))
                    }
                }
                do {
                    try process.run()
                } catch {
                    group.leave()
                    group.leave()
                    continuation.resume(throwing: error)
                    return
                }
                // Drain both pipes concurrently so large JSON never fills a pipe and deadlocks.
                DispatchQueue.global().async { box.out = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                DispatchQueue.global().async { box.err = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

private final class CaptureBox: @unchecked Sendable {
    var out = Data()
    var err = Data()
}
