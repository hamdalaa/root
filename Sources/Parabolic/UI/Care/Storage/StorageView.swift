import AppKit
import SwiftUI

/// Mac Care → Storage: every disk's capacity, a disk-usage explorer with a space map, and a large-file finder.
struct StorageView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case explorer, largeFiles
        var id: String { rawValue }
        var title: String { self == .explorer ? "Explorer" : "Large Files" }
    }

    @AppStorage("storage.tab") private var tab: Tab = .explorer
    @State private var viewportHeight: CGFloat = 0
    @State private var topHeight: CGFloat = 0

    private static let spacing: CGFloat = 14
    private static let verticalPadding: CGFloat = 18
    /// Below this the treemap and list get too cramped, so the screen scrolls instead.
    private static let minToolHeight: CGFloat = 460

    /// The explorer / large-files pane takes the rest of the window, never less than `minToolHeight`.
    private var toolHeight: CGFloat {
        max(Self.minToolHeight, viewportHeight - topHeight - Self.spacing - Self.verticalPadding * 2)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let explorer = StorageExplorerModel.shared
    private let largeFiles = StorageLargeFilesModel.shared
    private let volumes = StorageVolumesStore.shared

    /// How often capacity is re-read while the screen is open.
    private static let refreshInterval: Duration = .seconds(15)

    var body: some View {
        // Scrolls as a whole when the window is shorter than the screen; otherwise the explorer simply
        // fills what's left. A fixed stack used to overflow upward, under the toolbar and banner.
        ScrollView {
            VStack(alignment: .leading, spacing: Self.spacing) {
                VStack(alignment: .leading, spacing: Self.spacing) {
                    header
                    StorageVolumeStrip(volumes: volumes.volumes, isLoaded: volumes.isLoaded,
                                       exploring: tab == .explorer ? exploringVolume : nil) { volume in
                        if tab != .explorer { tab = .explorer }
                        explorer.explore(volume.url)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if abs(height - topHeight) > 0.5 { topHeight = height }
                }
                Group {
                    switch tab {
                    case .explorer: StorageExplorerView(model: explorer, volumes: volumes)
                    case .largeFiles: StorageLargeFilesView(model: largeFiles)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: toolHeight)
                .transition(.opacity)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, Self.verticalPadding)
            .frame(minWidth: 560, maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if abs(height - viewportHeight) > 0.5 { viewportHeight = height }
        }
        .animation(reduceMotion ? nil : Tokens.quick, value: tab)
        .task {
            // Capacity changes as other apps write; keep it current while the screen is visible.
            while !Task.isCancelled {
                await volumes.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            Task { await volumes.refresh() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            Task { await volumes.refresh() }
        }
        .onAppear { activate(tab) }
        .onDisappear {
            explorer.disappeared()
            largeFiles.disappeared()
        }
        .onChange(of: tab) { old, new in
            if old == .explorer { explorer.disappeared() } else { largeFiles.disappeared() }
            activate(new)
        }
    }

    private func activate(_ tab: Tab) {
        switch tab {
        case .explorer: explorer.appeared()
        case .largeFiles: largeFiles.appeared()
        }
    }

    private var exploringVolume: StorageVolume? {
        volumes.volumes.first { $0.url.path == explorer.base.path }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Storage")
                    .font(.system(size: 22, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            Picker("View", selection: Binding(get: { tab }, set: { if $0 != tab { tab = $0 } })) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        }
    }

    private var subtitle: String {
        switch volumes.volumes.count {
        case 0: "What’s using space on your disks"
        case 1: "What’s using space on \(volumes.volumes[0].name)"
        default: "What’s using space on your \(volumes.volumes.count) disks"
        }
    }
}
