import AppKit
import SwiftUI

/// Shared formatting for the Cleanup screen.
enum CleanupFormat {
    static func bytes(_ value: Int64) -> String {
        value > 0 ? ByteCountFormatter.string(fromByteCount: value, countStyle: .file) : "Zero KB"
    }

    /// Splits "4.2 GB" into ("4.2", "GB") for a hero number with a smaller unit.
    static func split(_ value: Int64) -> (number: String, unit: String) {
        let text = bytes(value)
        guard let space = text.lastIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }

    static func path(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func items(_ count: Int) -> String { "\(count.formatted()) item\(count == 1 ? "" : "s")" }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    /// "Idle 4 months" from a last-activity date.
    static func idle(since date: Date, now: Date = Date()) -> String {
        let days = max(0, Int(now.timeIntervalSince(date) / 86_400))
        switch days {
        case ..<1: return "Used today"
        case 1: return "Untouched for 1 day"
        case ..<60: return "Untouched for \(days) days"
        case ..<730: return "Untouched for \(days / 30) months"
        default: return "Untouched for \(days / 365) years"
        }
    }
}

/// Three-state checkbox drawn to match the accent colour, with a generous hit target.
struct CleanupCheckbox: View {
    let mark: CleanupStore.Mark
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(mark == .off ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(mark == .on ? "Selected" : mark == .mixed ? "Partly selected" : "Not selected")
        .accessibilityAddTraits(.isToggle)
    }

    private var symbol: String {
        switch mark {
        case .on: "checkmark.square.fill"
        case .mixed: "minus.square.fill"
        case .off: "square"
        }
    }
}

/// Rounded tile holding a category symbol.
struct CleanupSymbolTile: View {
    let symbol: String
    var isActive = true
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill((isActive ? Color.accentColor : Color.primary).opacity(isActive ? 0.13 : 0.06))
            )
            .accessibilityHidden(true)
    }
}

/// One capsule split into a segment per category, sized by bytes; ticked space is solid accent.
struct CleanupCompositionBar: View {
    struct Segment: Identifiable {
        let id: CleanupCategoryID
        let total: Int64
        let selected: Int64
    }

    let segments: [Segment]
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let total = max(1, segments.reduce(Int64(0)) { $0 + $1.total })
            let visible = segments.filter { $0.total > 0 }
            let gaps = CGFloat(max(0, visible.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(visible) { segment in
                    let width = max(3, (proxy.size.width - gaps) * CGFloat(segment.total) / CGFloat(total))
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.primary.opacity(0.09))
                        Rectangle()
                            .fill(Color.accentColor.gradient)
                            .frame(width: width * CGFloat(segment.selected) / CGFloat(max(1, segment.total)))
                    }
                    .frame(width: width)
                }
            }
            .clipShape(.capsule)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Row background that lights up on hover, like a Finder list.
struct CleanupHoverRow: ViewModifier {
    var cornerRadius: CGFloat = 10
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.primary.opacity(isHovering ? 0.05 : 0))
            )
            .onHover { hovering in
                guard hovering != isHovering else { return }
                isHovering = hovering
            }
            .animation(Tokens.quick, value: isHovering)
    }
}

extension View {
    func cleanupHoverRow(cornerRadius: CGFloat = 10) -> some View {
        modifier(CleanupHoverRow(cornerRadius: cornerRadius))
    }
}

/// Small capsule badge, e.g. "In use by Safari".
struct CleanupBadge: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: .capsule)
        .fixedSize()
    }
}

enum CleanupActions {
    @MainActor static func reveal(_ url: URL) {
        FinderReveal.reveal([url])
    }

    static func openFullDiskAccess() {
        NSWorkspace.shared.open(CleanupLiveEnvironment.fullDiskAccessURL)
    }
}
