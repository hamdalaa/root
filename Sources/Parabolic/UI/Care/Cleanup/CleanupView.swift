import SwiftUI

/// Mac Care → Cleanup: one scan over caches, logs, developer junk, idle project builds, installers, old downloads
/// and the Trash; review with per-item ticks; clean to the Trash by default; result measured from free space.
struct CleanupView: View {
    @Bindable private var store = CleanupStore.shared
    @State private var isConfirming = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                CleanupHero(store: store) { isConfirming = true }
                if showsPermissionNotice { permissionNotice.transition(.opacity) }
                if showsCategories {
                    CleanupCategoryList(store: store)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .animation(.adaptive(reduceMotion), value: store.phase)
        .sheet(isPresented: $isConfirming) {
            CleanupConfirmSheet(store: store)
        }
        .onDisappear { store.cancelScan() }
    }

    private var showsCategories: Bool {
        switch store.phase {
        case .idle, .scanning, .ready: true
        case .cleaning, .finished: false
        }
    }

    private var showsPermissionNotice: Bool {
        store.phase == .ready && store.deniedCount > 0
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Cleanup")
                .font(.system(size: 22, weight: .semibold))
            Text(headerSubtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var headerSubtitle: String {
        let history = store.history
        if let cleaned = history.lastCleanDate {
            var text = "Last cleaned \(CleanupFormat.relative(cleaned))"
            if let freed = history.lastCleanFreedBytes, freed > 0 {
                text += " · \(CleanupFormat.bytes(freed)) freed"
            } else if let trashed = history.lastCleanTrashedBytes, trashed > 0 {
                text += " · \(CleanupFormat.bytes(trashed)) moved to the Trash"
            }
            return text
        }
        if let scanned = history.lastScanDate, let bytes = history.lastScanBytes {
            return "Last scanned \(CleanupFormat.relative(scanned)) · \(CleanupFormat.bytes(bytes)) found"
        }
        return "Caches, logs and leftovers you can remove safely"
    }

    // MARK: Permission

    private var permissionNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.yellow)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(store.deniedCount.formatted()) folder\(store.deniedCount == 1 ? "" : "s") couldn’t be read")
                    .font(.system(size: 13, weight: .semibold))
                Text("macOS blocked access, so their size isn’t included above. Give Root Full Disk Access in System Settings, then scan again.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Privacy Settings", action: CleanupActions.openFullDiskAccess)
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(14)
        .glassPanel(cornerRadius: Tokens.radiusRow)
        .hairline(cornerRadius: Tokens.radiusRow)
        .accessibilityElement(children: .contain)
    }
}
