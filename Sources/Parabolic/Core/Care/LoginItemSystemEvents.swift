import AppKit
import CoreServices
import Foundation

/// An app listed under System Settings → General → Login Items → "Open at Login".
struct LoginItemLoginApp: Identifiable, Sendable, Equatable {
    var id: String { (path ?? "") + "|" + name }
    let name: String
    let path: String?
    let isHidden: Bool
}

/// Reads "Open at Login" apps through System Events. Needs the Automation permission.
enum LoginItemSystemEvents {
    enum Access: Equatable, Sendable {
        case granted
        /// Never asked: macOS would show its prompt.
        case notDetermined
        case denied
        /// System Events isn't running (it quits when idle), so macOS can't say.
        case unknown
    }

    enum Failure: Error, Equatable, Sendable {
        case denied
        case other(String)
    }

    static let bundleID = "com.apple.systemevents"
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
    static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    /// Checks the Automation permission without showing a prompt.
    static func currentAccess() -> Access {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .unknown
        default: return .notDetermined // -1744: macOS would ask
        }
    }

    private static let grantedKey = "loginItems.systemEventsGranted"

    /// The last real answer from System Events, kept for when it isn't running.
    static var wasGranted: Bool {
        get { UserDefaults.standard.bool(forKey: grantedKey) }
        set { UserDefaults.standard.set(newValue, forKey: grantedKey) }
    }

    private static let queue = DispatchQueue(label: "scoop.loginitems.systemevents")

    /// Asks System Events for the list. May show the macOS Automation prompt the first time.
    static func read() async -> Result<[LoginItemLoginApp], Failure> {
        await withCheckedContinuation { continuation in
            queue.async {
                let source = "tell application \"System Events\" to get {name, path, hidden} of every login item"
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: .failure(.other("Couldn’t prepare the request.")))
                    return
                }
                let result = script.executeAndReturnError(&error)
                if let error {
                    let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
                    if code == Int(errAEEventNotPermitted) || code == -1744 {
                        wasGranted = false
                        continuation.resume(returning: .failure(.denied))
                    } else {
                        let message = (error[NSAppleScript.errorMessage] as? String) ?? "System Events didn’t answer (\(code))."
                        continuation.resume(returning: .failure(.other(message)))
                    }
                    return
                }
                wasGranted = true
                continuation.resume(returning: .success(parse(result)))
            }
        }
    }

    /// `{{names…}, {paths…}, {hidden…}}` → apps.
    static func parse(_ descriptor: NSAppleEventDescriptor) -> [LoginItemLoginApp] {
        guard descriptor.numberOfItems >= 1 else { return [] }
        func column(_ index: Int) -> [NSAppleEventDescriptor] {
            guard index <= descriptor.numberOfItems, let list = descriptor.atIndex(index) else { return [] }
            return (0..<list.numberOfItems).compactMap { list.atIndex($0 + 1) }
        }
        let names = column(1), paths = column(2), hidden = column(3)
        return names.enumerated().map { index, name in
            let path = index < paths.count ? paths[index].stringValue : nil
            return LoginItemLoginApp(name: name.stringValue ?? "Unknown app",
                                     path: path.flatMap { $0.isEmpty ? nil : $0 },
                                     isHidden: index < hidden.count ? hidden[index].booleanValue : false)
        }
    }
}
