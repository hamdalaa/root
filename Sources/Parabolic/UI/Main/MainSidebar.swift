import SwiftUI

/// Source list: download filters, Discover, the sites you download from, the Library and an engine status card.
struct MainSidebar: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(AppState.self) private var appState
    @Environment(AppSettings.self) private var settings
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(SpeedTest.self) private var speedTest
    @Environment(ToolStore.self) private var tools

    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                header("Downloads")
                ForEach(SidebarItem.downloadFilters) { filter in
                    let count = manager.count(for: filter)
                    row(filter, count: count, alert: filter == .failed && count > 0) {
                        Image(systemName: filter.symbol)
                    }
                }

                header("Discover")
                row(.search) { Image(systemName: SidebarItem.search.symbol) }
                row(.subscriptions, count: newUploads, alert: newUploads > 0, busy: subscriptions.isChecking) {
                    Image(systemName: SidebarItem.subscriptions.symbol)
                }

                if settings.prefs.showPlatformsInSidebar {
                    header("Platforms")
                    let counts = manager.platformCounts
                    if counts.isEmpty {
                        SidebarPlatformsPlaceholder().padding(.horizontal, 10)
                    } else {
                        ForEach(counts, id: \.platform) { entry in
                            row(.platform(entry.platform), count: entry.count) {
                                PlatformTile(platform: entry.platform, size: 20)
                            }
                        }
                    }
                }

                header("Library")
                row(.history) { Image(systemName: SidebarItem.history.symbol) }
                row(.statistics) { Image(systemName: SidebarItem.statistics.symbol) }
                row(.speedTest, busy: speedTest.isRunning) { Image(systemName: SidebarItem.speedTest.symbol) }

                header("Mac Care")
                ForEach(SidebarItem.careTools) { tool in
                    row(tool) { Image(systemName: tool.symbol) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Only when yt-dlp needs attention; a healthy engine needs no permanent card.
            if !tools.isReady {
                SidebarStatusCard()
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        .onChange(of: appState.sidebarSelection) { _, filter in
            // Keep only selected rows that are still visible under the new filter.
            guard filter.showsDownloads else { return }
            let visible = Set(manager.items.filter { filter.includes($0) }.map(\.id))
            appState.selectedItemIDs.formIntersection(visible)
        }
        .onChange(of: manager.platformCounts.map(\.platform)) { _, platforms in
            // A platform row disappears when its last download is removed; fall back to All.
            if let selected = appState.sidebarSelection.platform, !platforms.contains(selected) {
                appState.sidebarSelection = .all
            }
        }
    }

    private var newUploads: Int { subscriptions.subscriptions.reduce(0) { $0 + $1.newCount } }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func row<Icon: View>(_ item: SidebarItem, count: Int = 0, alert: Bool = false, busy: Bool = false,
                                 @ViewBuilder icon: () -> Icon) -> some View {
        SidebarRow(title: item.title, isSelected: appState.sidebarSelection == item, count: count,
                   alert: alert, busy: busy, namespace: selectionNamespace, icon: icon()) {
            // Critically damped: the selection pill glides and lands without a wobble.
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.32)) {
                appState.sidebarSelection = item
            }
        }
    }
}

/// One sidebar row. Selection is a soft glass-white pill, not the heavy system highlight.
struct SidebarRow<Icon: View>: View {
    let title: String
    let isSelected: Bool
    var count = 0
    var alert = false
    var busy = false
    let namespace: Namespace.ID
    let icon: Icon
    let action: () -> Void

    @State private var isHovered = false
    @GestureState private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 22, height: 22)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if busy {
                    ProgressView().controlSize(.mini)
                } else if count > 0 {
                    Text("\(count)")
                        .contentTransition(.numericText(value: Double(count)))
                        .animation(.snappy, value: count)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(alert ? Color.white : Color.secondary)
                        .padding(.horizontal, alert ? 6 : 0)
                        .padding(.vertical, alert ? 1 : 0)
                        .background { if alert { Capsule().fill(.red) } }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.primary.opacity(isHovered && !isSelected ? 0.06 : 0))
                    if isSelected {
                        // One pill that glides between rows.
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.white.opacity(0.13))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                            }
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                            .matchedGeometryEffect(id: "sidebar-selection", in: namespace)
                    }
                }
            }
            .scaleEffect(isPressed ? 0.98 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 0).updating($isPressed) { _, state, _ in state = true })
        .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : Tokens.quick) { isHovered = hovering }
        }
        .animation(reduceMotion ? nil : Tokens.quick, value: isSelected)
        .accessibilityLabel(title)
        .accessibilityValue(count > 0 ? "\(count)" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A site the user downloads from: brand mark on a little app-icon tile, name and count.
struct SidebarPlatformRow: View {
    let platform: Platform
    let count: Int

    var body: some View {
        Label {
            Text(platform.title)
                .lineLimit(1)
        } icon: {
            PlatformTile(platform: platform, size: 20)
        }
        .badge(count)
        .help("\(platform.title): \(count) download\(count == 1 ? "" : "s")")
        .accessibilityLabel(platform.title)
        .accessibilityValue(count == 1 ? "1 item" : "\(count) items")
    }
}

/// Brand glyph on a solid, softly lit tile, like a tiny app icon. Reads on any selection colour.
struct PlatformTile: View {
    let platform: Platform
    var size: CGFloat = 20
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let radius = size * 0.27
        // Monochrome brands (X, TikTok…) get an explicit ink so sidebar vibrancy can't grey them out.
        PlatformGlyph(platform: platform, size: size * 0.62, style: platform.brandHex == nil ? .monochrome : .brand)
            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(colorScheme == .dark
                          ? AnyShapeStyle(LinearGradient(colors: [Color(white: 0.27), Color(white: 0.19)],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(LinearGradient(colors: [.white, Color(white: 0.955)],
                                                         startPoint: .top, endPoint: .bottom)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.primary.opacity(colorScheme == .dark ? 0.14 : 0.1), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 1, y: 0.5)
            .accessibilityHidden(true)
    }
}

/// Empty Platforms section: a hint, with a few muted marks so the idea is obvious.
struct SidebarPlatformsPlaceholder: View {
    private static let samples: [Platform] = [.youtube, .soundcloud, .tiktok, .instagram]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Self.samples) { platform in
                    PlatformTile(platform: platform, size: 18)
                }
            }
            .opacity(0.75)
            Text("Sites appear here as you download.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sites appear here as you download.")
    }
}
