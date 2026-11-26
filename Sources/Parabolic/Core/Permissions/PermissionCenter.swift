import AppKit
import ApplicationServices
import Foundation
import Observation
import UserNotifications

/// The macOS permissions Root uses, with a live status and the System Settings pane that grants each one.
enum RootPermission: String, CaseIterable, Identifiable, Sendable {
    case fullDiskAccess, downloadsFolder, automation, notifications, accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullDiskAccess: "Full Disk Access"
        case .downloadsFolder: "Downloads folder"
        case .automation: "Automation (System Events)"
        case .notifications: "Notifications"
        case .accessibility: "Accessibility (optional)"
        }
    }

    /// Optional permissions improve a feature but never make the setup guide open by itself.
    var isOptional: Bool { self == .accessibility }

    /// Why Root needs it, in one line.
    var reason: String {
        switch self {
        case .fullDiskAccess: "Save to any folder or drive, and let Storage, Cleanup and Uninstaller see every file."
        case .downloadsFolder: "Save downloads to your download folder."
        case .automation: "Read the apps that open at login (Login Items)."
        case .notifications: "Tell you when a download finishes or fails."
        case .accessibility: "Force Quit spots apps that stopped responding right away, even before the beach ball."
        }
    }

    var symbol: String {
        switch self {
        case .fullDiskAccess: "externaldrive.badge.checkmark"
        case .downloadsFolder: "arrow.down.circle"
        case .automation: "gearshape.2"
        case .notifications: "bell.badge"
        case .accessibility: "accessibility"
        }
    }

    var settingsURL: URL {
        let base = "x-apple.systempreferences:"
        switch self {
        case .fullDiskAccess: return URL(string: base + "com.apple.preference.security?Privacy_AllFiles")!
        case .downloadsFolder: return URL(string: base + "com.apple.preference.security?Privacy_FilesAndFolders")!
        case .automation: return URL(string: base + "com.apple.preference.security?Privacy_Automation")!
        case .notifications: return URL(string: base + "com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "com.hamad.parabolic")")!
        case .accessibility: return URL(string: base + "com.apple.preference.security?Privacy_Accessibility")!
        }
    }

    /// True when macOS can show its own prompt (otherwise the only way is System Settings).
    var canPrompt: Bool { self != .fullDiskAccess }
}

enum PermissionStatus: Equatable, Sendable {
    case granted, denied, notAsked

    var label: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Not allowed"
        case .notAsked: "Not set"
        }
    }
}

/// Reads permission states. Polled while the permissions sheet is open, so a switch flipped in
/// System Settings shows up within a couple of seconds.
@MainActor
@Observable
final class PermissionCenter {
    static let shared = PermissionCenter()

    private(set) var statuses: [RootPermission: PermissionStatus] = [:]
    private(set) var isChecking = false

    func status(_ permission: RootPermission) -> PermissionStatus { statuses[permission] ?? .notAsked }

    /// Required permissions that aren't granted (optional ones never count).
    var missing: [RootPermission] { RootPermission.allCases.filter { !$0.isOptional && status($0) != .granted } }

    /// Re-checks every permission. Never shows a macOS prompt.
    func refresh(downloadFolder: String) async {
        isChecking = true
        defer { isChecking = false }
        let folder = downloadFolder
        let (fda, downloads) = await Task.detached(priority: .userInitiated) {
            (Self.probeFullDiskAccess(), Self.probeFolder(folder))
        }.value
        var next: [RootPermission: PermissionStatus] = [:]
        next[.fullDiskAccess] = fda
        // Full Disk Access covers every folder, Downloads included.
        next[.downloadsFolder] = fda == .granted ? .granted : downloads
        next[.automation] = Self.automationStatus(LoginItemSystemEvents.currentAccess(),
                                                  rememberedGrant: LoginItemSystemEvents.wasGranted)
        next[.notifications] = await Self.notificationStatus()
        next[.accessibility] = AXIsProcessTrusted() ? .granted : .notAsked
        if next != statuses { statuses = next }
    }

    /// Asks macOS for the permission (its own prompt), or opens the right System Settings pane.
    func request(_ permission: RootPermission, downloadFolder: String) async {
        switch permission {
        case .fullDiskAccess:
            open(permission)
        case .downloadsFolder:
            // Touching the folder makes macOS show "Root would like to access files in your Downloads folder".
            let folder = downloadFolder
            let result = await Task.detached { Self.probeFolder(folder) }.value
            if result == .denied { open(permission) }
        case .automation:
            if LoginItemSystemEvents.currentAccess() == .denied {
                open(permission)
            } else {
                await launchSystemEvents()
                _ = await LoginItemSystemEvents.read() // shows the Automation prompt the first time
            }
        case .accessibility:
            // Adds Root to the Accessibility list and shows macOS's "open System Settings" prompt.
            let prompt = "AXTrustedCheckOptionPrompt" as CFString
            if !AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) { open(permission) }
        case .notifications:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .denied {
                open(permission)
            } else {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            }
        }
        await refresh(downloadFolder: downloadFolder)
    }

    func open(_ permission: RootPermission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    /// Shows Root.app in Finder, to drag into the Full Disk Access list.
    func revealApp() {
        FinderReveal.reveal([Bundle.main.bundleURL])
    }

    // MARK: Probes

    /// Files only readable with Full Disk Access. Reading them never prompts.
    nonisolated static let protectedProbes: [String] = [
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
        NSHomeDirectory() + "/Library/Safari/CloudTabs.db",
        NSHomeDirectory() + "/Library/Containers/com.apple.stocks",
    ]

    nonisolated static func probeFullDiskAccess(paths: [String] = protectedProbes) -> PermissionStatus {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return .notAsked }
        for path in existing {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                if (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil { return .granted }
            } else if let handle = FileHandle(forReadingAtPath: path) {
                try? handle.close()
                return .granted
            }
        }
        return .denied
    }

    /// Lists the folder: allowed, or "Operation not permitted" when macOS blocks it.
    nonisolated static func probeFolder(_ path: String) -> PermissionStatus {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: (path as NSString).expandingTildeInPath)
            return .granted
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            return .denied
        } catch {
            let posix = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            return posix?.code == Int(EPERM) || posix?.code == Int(EACCES) ? .denied : .notAsked
        }
    }

    /// When System Events isn't running macOS can't answer, so the last real answer stands.
    nonisolated static func automationStatus(_ access: LoginItemSystemEvents.Access, rememberedGrant: Bool) -> PermissionStatus {
        switch access {
        case .granted: .granted
        case .denied: .denied
        case .notDetermined: .notAsked
        case .unknown: rememberedGrant ? .granted : .notAsked
        }
    }

    private static func notificationStatus() async -> PermissionStatus {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        case .notDetermined: .notAsked
        @unknown default: .notAsked
        }
    }

    private func launchSystemEvents() async {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: LoginItemSystemEvents.bundleID).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: LoginItemSystemEvents.bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        try? await Task.sleep(for: .milliseconds(600))
    }
}
