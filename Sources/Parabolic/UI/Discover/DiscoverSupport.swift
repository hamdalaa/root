import AppKit
import SwiftUI

// MARK: - Formatting

enum DiscoverFormat {
    /// "1.2M views", "830 views", "1 view".
    static func views(_ count: Int?) -> String? {
        guard let count, count >= 0 else { return nil }
        if count == 1 { return "1 view" }
        return count.formatted(.number.notation(.compactName).precision(.significantDigits(1...3))) + " views"
    }

    /// "just now", "5 min ago", "3 hr ago", then the system's relative phrasing.
    static func ago(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) hr ago"
        default: return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
        }
    }

    /// "every hour", "every 30 minutes", "every 2 hours".
    static func interval(minutes: Int) -> String {
        let minutes = max(15, minutes)
        if minutes == 60 { return "every hour" }
        if minutes % 60 == 0 { return "every \(minutes / 60) hours" }
        return "every \(minutes) minutes"
    }
}

enum DiscoverActions {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func open(_ link: String) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Recent searches

struct RecentSearch: Codable, Hashable, Identifiable {
    var query: String
    var source: SearchSource
    var id: String { "\(source.rawValue):\(query.lowercased())" }

    static let limit = 8

    static func decode(_ json: String) -> [RecentSearch] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([RecentSearch].self, from: data)) ?? []
    }

    static func encode(_ items: [RecentSearch]) -> String {
        guard let data = try? JSONEncoder().encode(items) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Newest first, de-duplicated (case-insensitive per source), capped at `limit`.
    static func adding(_ item: RecentSearch, to items: [RecentSearch]) -> [RecentSearch] {
        Array(([item] + items.filter { $0.id != item.id }).prefix(limit))
    }
}

// MARK: - Source picker

/// Glass segmented control of search sources, each with its logo. The selection pill slides between segments.
struct SearchSourcePicker: View {
    @Binding var selection: SearchSource
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SearchSource.allCases) { source in
                SourceSegment(source: source, isSelected: selection == source, pill: pill) {
                    withAnimation(reduceMotion ? nil : Tokens.motion) { selection = source }
                }
            }
        }
        .padding(3)
        .glassCapsule()
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search source")
    }
}

private struct SourceSegment: View {
    var source: SearchSource
    var isSelected: Bool
    var pill: Namespace.ID
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                PlatformGlyph(platform: source.platform, size: 14, style: isSelected ? .brand : .monochrome)
                Text(source.platform.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                if isSelected {
                    Capsule()
                        .fill(.background.opacity(0.9))
                        .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
                        .matchedGeometryEffect(id: "pill", in: pill)
                } else if hovering {
                    Capsule().fill(.primary.opacity(0.06))
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(source.platform.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Placeholder panel

/// Centered message for empty, no-result and error states.
struct DiscoverMessage<Actions: View>: View {
    var symbol: String
    var title: String
    var message: String
    var tint: Color = .secondary
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Tokens.space4) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 64, height: 64)
                .glassEffect(.regular, in: .circle)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
                    .textSelection(.enabled)
            }
            actions
        }
        .padding(.vertical, Tokens.space6)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension DiscoverMessage where Actions == EmptyView {
    init(symbol: String, title: String, message: String, tint: Color = .secondary) {
        self.init(symbol: symbol, title: title, message: message, tint: tint) { EmptyView() }
    }
}

/// Hairline-bordered solid glass panel used by rows and cards on the Discover screens.
extension View {
    func discoverPanel(cornerRadius: CGFloat = Tokens.radiusRow) -> some View {
        glassPanel(cornerRadius: cornerRadius)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.08)))
    }
}
