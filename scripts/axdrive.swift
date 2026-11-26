// UI smoke driver: presses Parabolic's own buttons by title through Accessibility.
// Never moves the mouse or types, so it is safe to run while you use the Mac.
// Usage: swift scripts/axdrive.swift <rounds> <title> [title…]
import ApplicationServices
import AppKit
let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.hamad.parabolic").first!
let root = AXUIElementCreateApplication(app.processIdentifier)
func children(_ e: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v); return (v as? [AXUIElement]) ?? []
}
func attr(_ e: AXUIElement, _ a: String) -> String? {
    var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, a as CFString, &v); return v as? String
}
func find(_ e: AXUIElement, _ title: String, depth: Int = 0) -> AXUIElement? {
    if depth > 25 { return nil }
    if attr(e, kAXRoleAttribute) == "AXButton", (attr(e, kAXTitleAttribute) == title || attr(e, kAXDescriptionAttribute) == title) { return e }
    for c in children(e) { if let f = find(c, title, depth: depth + 1) { return f } }
    return nil
}
let rounds = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 1
let titles = CommandLine.arguments.dropFirst(2)
var pressed = 0
for _ in 0..<rounds { for t in titles {
    if let b = find(root, t) { AXUIElementPerformAction(b, kAXPressAction as CFString); pressed += 1 } else { print("missing", t) }
    usleep(350_000)
}}
print("pressed", pressed)
