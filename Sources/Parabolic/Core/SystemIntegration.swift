import AppKit
import UserNotifications

/// Dock badge/progress, sleep prevention, notifications and the "when done" action.
@MainActor
final class SystemIntegration: NSObject, UNUserNotificationCenterDelegate {
    private let settings: AppSettings
    private var sleepActivity: NSObjectProtocol?
    private let dockView = DockProgressView()
    private var lastDockSignature = ""
    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        if notificationsAvailable {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    func update(manager: DownloadManager) {
        let prefs = settings.prefs
        let active = manager.activeItems.count
        let busy = manager.runningCount > 0

        // Sleep prevention while anything is transferring or converting.
        if busy, prefs.preventSleep, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                                 reason: "Downloading media")
        } else if (!busy || !prefs.preventSleep), let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }

        // Dock tile: badge with the active count, thin progress bar under the icon.
        guard NSApp != nil else { return }
        let progress = prefs.showDockProgress ? manager.overallProgress : nil
        let signature = "\(active)-\(progress.map { Int($0 * 100) } ?? -1)"
        guard signature != lastDockSignature else { return }
        lastDockSignature = signature
        NSApp.dockTile.badgeLabel = active > 0 ? "\(active)" : nil
        dockView.progress = progress
        NSApp.dockTile.contentView = progress == nil ? nil : dockView
        NSApp.dockTile.display()
    }

    // MARK: - Notifications

    func notifyCompleted(_ item: DownloadItem) {
        post(title: "Download complete", body: item.title, path: item.filePath)
    }

    func notifyFailed(_ item: DownloadItem) {
        post(title: "Download failed", body: "\(item.title)\n\(item.errorMessage ?? "")", path: nil)
    }

    private func post(title: String, body: String, path: String?) {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        if let path { content.userInfo = ["path": path] }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo["path"] as? String else { return }
        await MainActor.run { _ = FinderReveal.reveal([URL(fileURLWithPath: path)]) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    // MARK: - When the queue drains

    func runCompletionAction(_ action: CompletionAction) {
        switch action {
        case .nothing:
            break
        case .notify:
            NSSound(named: "Glass")?.play()
        case .quit:
            NSApp.terminate(nil)
        case .sleep:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["sleepnow"]
            try? process.run()
        }
    }
}

/// App icon with a slim glass progress capsule along the bottom edge.
private final class DockProgressView: NSView {
    var progress: Double? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        guard let progress else { return }
        let inset = bounds.width * 0.14
        let height = bounds.height * 0.085
        let track = NSRect(x: inset, y: bounds.height * 0.1, width: bounds.width - inset * 2, height: height)
        let trackPath = NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2)
        NSColor.black.withAlphaComponent(0.55).setFill()
        trackPath.fill()
        let fillRect = NSRect(x: track.minX + 2, y: track.minY + 2,
                              width: max(height - 4, (track.width - 4) * CGFloat(min(1, max(0, progress)))), height: height - 4)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: (height - 4) / 2, yRadius: (height - 4) / 2)
        NSColor.white.setFill()
        fill.fill()
    }
}
