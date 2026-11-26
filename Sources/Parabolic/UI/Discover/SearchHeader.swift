import SwiftUI

/// Title, the large glass search field and the source picker.
struct SearchHeader: View {
    var isSelecting: Bool
    var canSelect: Bool
    var isLoading: Bool
    var onSubmit: () -> Void
    var onToggleSelect: () -> Void

    @Environment(AppState.self) private var appState
    @State private var width: CGFloat = 0

    /// Below this the source picker moves under the field.
    private static let inlineWidth: CGFloat = 760

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: Tokens.space4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Search")
                    .font(.system(size: 26, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if canSelect || isSelecting {
                    Button(isSelecting ? "Done" : "Select", action: onToggleSelect)
                        .buttonStyle(.glass)
                        .help(isSelecting ? "Leave selection mode" : "Select several results to download together")
                }
            }
            GlassEffectContainer(spacing: Tokens.space3) {
                // Layout follows the measured width (not ViewThatFits) so it never feeds a minimum
                // width back into the split view.
                if width >= Self.inlineWidth {
                    HStack(spacing: Tokens.space3) {
                        field
                        SearchSourcePicker(selection: $appState.searchSource).fixedSize()
                    }
                } else {
                    VStack(alignment: .leading, spacing: Tokens.space3) {
                        field
                        ScrollView(.horizontal) {
                            SearchSourcePicker(selection: $appState.searchSource).fixedSize().padding(2)
                        }
                        .scrollIndicators(.never)
                    }
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var field: some View {
        @Bindable var appState = appState
        return SearchField(text: $appState.searchQuery, source: appState.searchSource, isLoading: isLoading, onSubmit: onSubmit)
            .frame(minWidth: 0, maxWidth: .infinity)
    }
}

/// Large glass search field. Shows the site's logo instead of the magnifier when a link is typed.
private struct SearchField: View {
    @Binding var text: String
    var source: SearchSource
    var isLoading: Bool
    var onSubmit: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var linkPlatform: Platform? { TypedLinkRecognizer.platform(in: text) }

    var body: some View {
        HStack(spacing: Tokens.space3) {
            Group {
                if let platform = linkPlatform {
                    PlatformGlyph(platform: platform, size: 18).transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .frame(width: 20)
            .accessibilityHidden(true)

            TextField("Search \(source.platform.title) or paste a link", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .onSubmit(onSubmit)
                .accessibilityLabel("Search \(source.platform.title)")

            if isLoading {
                ProgressView().controlSize(.small).accessibilityLabel("Searching")
            }
            if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(HoverButtonStyle(cornerRadius: 12, padding: 4))
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, Tokens.space4)
        .padding(.trailing, Tokens.space2)
        .frame(height: 44)
        .glassCapsule(interactive: true)
        .overlay(Capsule().strokeBorder(.primary.opacity(focused ? 0.16 : 0.08)))
        .animation(reduceMotion ? nil : Tokens.quick, value: linkPlatform)
        .onAppear { if text.isEmpty { focused = true } }
    }
}
