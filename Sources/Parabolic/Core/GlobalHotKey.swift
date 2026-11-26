import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut. ⌃⌥⌘D quick-downloads the link on the clipboard; ⌃⌥⌘⎋ opens Force Quit.
/// Every instance installs its own application-level handler, so each one checks the hot-key id and passes
/// other ids on (`eventNotHandledErr`) instead of firing for every shortcut.
@MainActor
final class GlobalHotKey {
    static let displayString = "⌃⌥⌘D"
    static let forceQuitDisplayString = "⌃⌥⌘⎋"

    private static let signature = OSType(0x5042_444C) // "PBDL"

    private let keyCode: UInt32
    private let modifiers: UInt32
    private let hotKeyID: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    init(keyCode: Int = kVK_ANSI_D, modifiers: Int = cmdKey | optionKey | controlKey, id: UInt32 = 1) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        self.hotKeyID = id
    }

    /// ⌃⌥⌘⎋ (the system's own Force Quit window is ⌥⌘⎋).
    static func forceQuit() -> GlobalHotKey {
        GlobalHotKey(keyCode: kVK_Escape, modifiers: cmdKey | optionKey | controlKey, id: 2)
    }

    func setEnabled(_ enabled: Bool, action: @escaping () -> Void) {
        unregister()
        guard enabled else { return }
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            guard status == noErr, pressed.signature == GlobalHotKey.signature, pressed.id == hotKey.hotKeyID else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { hotKey.action?() } }
            return noErr
        }, 1, &eventType, context, &handlerRef)
        let id = EventHotKeyID(signature: Self.signature, id: hotKeyID)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
