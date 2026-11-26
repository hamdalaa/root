import AppKit
import Foundation

/// One thing to move to the Trash.
struct UninstallTrashItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// An app bundle: goes through NSWorkspace so admin-owned apps get a password prompt.
        case appBundle(bundleID: String?)
        /// A support file or folder, or a symlink (the link itself is moved, never its target).
        case supportItem
        /// A symlink in an Applications folder that pointed at a removed app.
        case alias
    }

    var id: String { url.path }
    let url: URL
    let title: String
    let kind: Kind
    let bytes: Int64?
    /// A LaunchAgent plist that should be unloaded before it's moved.
    var unloadsAgent = false
    /// For a symlink to moved support data: the data, trashed before the link.
    var linkedTarget: URL?
}

/// What happened, item by item.
struct UninstallTrashOutcome: Sendable, Equatable {
    struct Failure: Hashable, Sendable {
        let item: UninstallTrashItem
        let reason: String
    }

    var removed: [UninstallTrashItem] = []
    var failed: [Failure] = []
    /// Set when the whole operation stopped early (e.g. the app wouldn't quit).
    var stopReason: String?

    var removedBytes: Int64 { removed.reduce(0) { $0 + ($1.bytes ?? 0) } }
}

/// Moves items to the Trash. Only ever called from an explicit, confirmed user action.
@MainActor
enum UninstallTrasher {
    /// Quits the app if it's running. Returns nil on success, or why it couldn't.
    static func quit(_ app: UninstallApp, timeout: Duration = .seconds(10)) async -> String? {
        let running = runningInstances(of: app)
        guard !running.isEmpty else { return nil }
        running.forEach { _ = $0.terminate() }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if running.allSatisfy(\.isTerminated) { return nil }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return "\(app.name) didn’t quit. Save your work in it, quit it yourself, then try again."
    }

    static func runningInstances(of app: UninstallApp) -> [NSRunningApplication] {
        let paths = Set([app.url.path] + app.aliases.map(\.path))
        return NSWorkspace.shared.runningApplications.filter { running in
            if let url = running.bundleURL, paths.contains(url.path) || paths.contains(url.resolvingSymlinksInPath().path) {
                return true
            }
            return false
        }
    }

    /// Trashes app bundles first; if one fails, its support files are left alone so nothing is half-removed.
    static func trash(_ items: [UninstallTrashItem], library: URL) async -> UninstallTrashOutcome {
        var outcome = UninstallTrashOutcome()
        let apps = items.filter { if case .appBundle = $0.kind { true } else { false } }
        let rest = items.filter { if case .appBundle = $0.kind { false } else { true } }

        for app in apps {
            guard case .appBundle(let bundleID) = app.kind,
                  UninstallSafety.isRemovableApp(path: app.url.path, bundleID: bundleID) else {
                outcome.failed.append(.init(item: app, reason: "Root doesn’t remove this app."))
                outcome.stopReason = "Nothing else was removed."
                return outcome
            }
            do {
                _ = try await NSWorkspace.shared.recycle([app.url])
                outcome.removed.append(app)
            } catch {
                outcome.failed.append(.init(item: app, reason: reason(for: error)))
                outcome.stopReason = "The app stayed where it was, so its files were left alone too."
                return outcome
            }
        }

        for item in rest {
            let path = item.url.path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                outcome.failed.append(.init(item: item, reason: "It was already gone."))
                continue
            }
            let allowed = item.kind == .alias
                ? attributes[.type] as? FileAttributeType == .typeSymbolicLink && !UninstallSafety.isProtected(path: path)
                : UninstallSafety.isRemovableSupportItem(path: path, library: library.path)
            guard allowed else {
                outcome.failed.append(.init(item: item, reason: "This location is protected."))
                continue
            }
            if item.unloadsAgent { await LoginItemLaunchctl.unload(plistPath: path) }
            if let target = item.linkedTarget {
                // Re-check right before acting: the link must still point at exactly this moved data.
                guard UninstallLinks.resolve(item.url) == .supportTarget(target) else {
                    outcome.failed.append(.init(item: item, reason: "The link changed since it was checked, so it was left alone."))
                    continue
                }
                if let error = await trashOffMain(target) {
                    outcome.failed.append(.init(item: item, reason: "Its data on \(UninstallVolume.from(path: target.path).title) couldn’t be moved: \(error)"))
                    continue
                }
            }
            let error = await trashOffMain(item.url)
            if let error { outcome.failed.append(.init(item: item, reason: error)) } else { outcome.removed.append(item) }
        }
        return outcome
    }

    /// Moves one item to the Trash on a utility queue (never the main actor). Symlinks are moved, not followed.
    private static func trashOffMain(_ url: URL) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: reason(for: error))
                }
            }
        }
    }

    nonisolated static func reason(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSUserCancelledError: return "You cancelled the password prompt."
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return "You don’t have permission to move it."
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return "It was already gone."
            case NSFileWriteVolumeReadOnlyError: return "Its drive is read-only."
            default: break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
            return "macOS blocked access to it."
        }
        return nsError.localizedDescription
    }
}
