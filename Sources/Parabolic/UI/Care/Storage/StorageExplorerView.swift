import SwiftUI

/// Disk-usage explorer: breadcrumbs and status on top, the space map and the sorted list side by side.
struct StorageExplorerView: View {
    let model: StorageExplorerModel
    let volumes: StorageVolumesStore

    @State private var trashRequest: StorageTrashRequest?
    @State private var trashErrors: [String] = []
    @State private var previewURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StorageExplorerBar(model: model, volumes: volumes)
            notices
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? nil : Tokens.motion, value: model.location)
        }
        .quickLookPreview($previewURL)
        .confirmationDialog(trashRequest?.title ?? "", isPresented: isConfirmingTrash, titleVisibility: .visible,
                            presenting: trashRequest) { request in
            Button("Move to Trash", role: .destructive) { performTrash(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
        .alert("Some items weren’t moved to the Trash", isPresented: hasTrashErrors) {
            Button("OK") { trashErrors = [] }
        } message: {
            Text(trashErrors.joined(separator: "\n"))
        }
    }

    // MARK: Notices

    @ViewBuilder private var notices: some View {
        if let listing = model.listing, listing.unreadable > 0 {
            StoragePermissionNotice(unreadable: listing.unreadable, samples: listing.unreadableSamples,
                                    hasFullDiskAccess: model.hasFullDiskAccess)
        }
        if let listing = model.listing, listing.skippedVolumes > 0 {
            Label("\(listing.skippedVolumes) other disk\(listing.skippedVolumes == 1 ? " is" : "s are") mounted inside this folder and not counted here.",
                  systemImage: "externaldrive")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            firstRun
        case .failed(let message, let denied):
            failed(message, denied: denied)
        case .scanning, .done, .stopped:
            if let listing = model.listing {
                if listing.items.isEmpty && listing.otherCount == 0 {
                    StorageStateView(symbol: "folder", title: "This folder is empty",
                                     message: "There’s nothing in “\(listing.folder.lastPathComponent)” taking up space.") {
                        if model.canGoBack { Button("Back") { model.goBack() } }
                    }
                    .glassPanel(cornerRadius: 18)
                    .hairline(cornerRadius: 18)
                } else {
                    split(listing)
                        .id(listing.folder.path)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
                }
            } else {
                StorageStateView(symbol: "magnifyingglass", title: "Reading “\(model.location.lastPathComponent)”…",
                                 message: "Listing what’s inside before measuring it.") {
                    ProgressView().controlSize(.small)
                }
                .glassPanel(cornerRadius: 18)
                .hairline(cornerRadius: 18)
            }
        }
    }

    private func split(_ listing: StorageListing) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                map(listing).frame(minWidth: 340)
                list(listing).frame(width: 340)
            }
            VStack(spacing: 12) {
                map(listing).frame(height: 220)
                list(listing)
            }
        }
    }

    private func map(_ listing: StorageListing) -> some View {
        StorageTreemapView(listing: listing, model: model) { item in menu([item]) }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassPanel(cornerRadius: 18)
            .hairline(cornerRadius: 18)
    }

    private func list(_ listing: StorageListing) -> some View {
        StorageItemList(listing: listing, model: model, onQuickLook: quickLook, onTrash: requestTrash)
            .padding(.vertical, 4)
            .frame(maxHeight: .infinity)
            .glassPanel(cornerRadius: 18)
            .hairline(cornerRadius: 18)
    }

    private func menu(_ items: [StorageItem]) -> StorageItemMenu {
        StorageItemMenu(items: items, onOpen: model.open, onQuickLook: quickLook, onTrash: requestTrash)
    }

    private var firstRun: some View {
        StorageStateView(symbol: "chart.pie",
                         title: "See what’s using space in “\(displayName(model.location))”",
                         message: firstRunMessage) {
            Button { model.explore(model.location) } label: {
                Label("Scan \(displayName(model.location))", systemImage: "play.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Button("Choose Folder…") { chooseFolder() }
                .buttonStyle(.glass)
                .controlSize(.large)
        }
        .glassPanel(cornerRadius: 18)
        .hairline(cornerRadius: 18)
    }

    private var firstRunMessage: String {
        var text = "Root measures every folder on this disk without following links or crossing into other disks. Nothing is changed."
        if !model.hasFullDiskAccess {
            text += " Without Full Disk Access some folders can’t be measured, and macOS may ask before Root reads Desktop, Documents or other apps’ data."
        }
        return text
    }

    private func failed(_ message: String, denied: Bool) -> some View {
        StorageStateView(symbol: denied ? "lock.fill" : "exclamationmark.triangle.fill",
                         title: denied ? "Root can’t read “\(model.location.lastPathComponent)”" : "Couldn’t read this folder",
                         message: denied ? "macOS is blocking access to this folder. Give Root Full Disk Access, then try again." : message,
                         tint: denied ? .yellow : .red) {
            if denied {
                Button("Open Full Disk Access Settings") { StorageSafety.openFullDiskAccessSettings() }
                    .buttonStyle(.glassProminent)
            }
            Button("Try Again") { model.rescan() }
                .buttonStyle(.glass)
            if model.canGoBack { Button("Back") { model.goBack() }.buttonStyle(.glass) }
        }
        .glassPanel(cornerRadius: 18)
        .hairline(cornerRadius: 18)
    }

    private func displayName(_ url: URL) -> String {
        if url.path == model.home.path { return "Home" }
        if let volume = volumes.volume(containing: url), volume.url.path == url.path { return volume.name }
        return url.lastPathComponent
    }

    // MARK: Actions

    private func chooseFolder() {
        StorageFinder.chooseFolder(startingAt: model.location) { url in model.explore(url) }
    }

    private func quickLook(_ url: URL) {
        previewURL = previewURL == url ? nil : url
    }

    private func requestTrash(_ items: [StorageItem]) {
        let allowed = items.filter { StorageSafety.canTrash($0.url) && !$0.isSizing }
        guard !allowed.isEmpty else { return }
        trashRequest = StorageTrashRequest(urls: allowed.map(\.url), bytes: allowed.reduce(0) { $0 + $1.bytes },
                                           fileCount: allowed.reduce(0) { $0 + $1.fileCount })
    }

    private func performTrash(_ request: StorageTrashRequest) {
        trashRequest = nil
        Task {
            let failures = await model.trash(request.urls)
            if !failures.isEmpty {
                trashErrors = failures.map { "\($0.0.lastPathComponent): \($0.1)" }
            }
        }
    }

    private var isConfirmingTrash: Binding<Bool> {
        Binding(get: { trashRequest != nil }, set: { if !$0, trashRequest != nil { trashRequest = nil } })
    }

    private var hasTrashErrors: Binding<Bool> {
        Binding(get: { !trashErrors.isEmpty }, set: { if !$0, !trashErrors.isEmpty { trashErrors = [] } })
    }
}

/// Back, breadcrumbs, scan status and folder controls.
struct StorageExplorerBar: View {
    let model: StorageExplorerModel
    let volumes: StorageVolumesStore

    var body: some View {
        HStack(spacing: 10) {
            Button { model.goBack() } label: {
                Image(systemName: "chevron.left").frame(width: 16, height: 16)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(!model.canGoBack)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back")
            .accessibilityLabel("Back")

            breadcrumbs
                .layoutPriority(1)
            Spacer(minLength: 8)
            status
            Button { model.rescan() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(model.phase == .idle)
            .keyboardShortcut("r", modifiers: .command)
            .help("Measure this folder again")
            .accessibilityLabel("Rescan")

            Button("Choose Folder…") {
                StorageFinder.chooseFolder(startingAt: model.location) { url in model.explore(url) }
            }
            .buttonStyle(.glass)
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        .font(.system(size: 12))
    }

    private var breadcrumbs: some View {
        let crumbs = model.crumbs
        return HStack(spacing: 3) {
            ForEach(Array(crumbs.enumerated()), id: \.offset) { index, url in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                let isLast = index == crumbs.count - 1
                Button { model.open(url) } label: {
                    HStack(spacing: 4) {
                        if index == 0 { Image(systemName: symbol(for: url)).font(.system(size: 11)) }
                        Text(name(for: url))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 12.5, weight: isLast ? .semibold : .regular))
                    .foregroundStyle(isLast ? Color.primary : Color.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .contentShape(.rect(cornerRadius: 6))
                }
                .buttonStyle(StorageCrumbButtonStyle())
                .disabled(isLast)
                .accessibilityLabel(name(for: url))
                .accessibilityAddTraits(isLast ? .isHeader : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .scanning:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(scanningText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                Button("Stop") { model.stopScan() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .accessibilityElement(children: .combine)
        case .stopped:
            HStack(spacing: 8) {
                Label("Stopped. Figures are partial.", systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
                Button("Resume") { model.rescan() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        case .done:
            if let listing = model.listing {
                Text(doneText(listing))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .help(shareOfVolume(listing) ?? "")
            }
        case .idle, .failed:
            EmptyView()
        }
    }

    private var scanningText: String {
        let measured = Format.bytes(model.listing?.totalBytes ?? 0)
        let progress = model.progress
        guard progress.total > 0 else { return "Listing…" }
        return "\(progress.sized) of \(progress.total) folders · \(measured) so far"
    }

    private func doneText(_ listing: StorageListing) -> String {
        let total = listing.totalBytes + listing.selfBytes
        return "\(Format.bytes(total)) · \(listing.totalFiles.formatted()) files"
    }

    private func shareOfVolume(_ listing: StorageListing) -> String? {
        guard let volume = volumes.volume(containing: listing.folder), volume.total > 0 else { return nil }
        return "\(StoragePercent.text(listing.totalBytes, of: volume.total)) of \(volume.name)"
    }

    private func name(for url: URL) -> String {
        if url.path == model.home.path { return "Home" }
        if url.path == "/" { return volumes.volumes.first(where: \.isRoot)?.name ?? "Startup Disk" }
        if let volume = volumes.volumes.first(where: { $0.url.path == url.path }) { return volume.name }
        return url.lastPathComponent
    }

    private func symbol(for url: URL) -> String {
        if url.path == model.home.path { return "house" }
        if volumes.volumes.contains(where: { $0.url.path == url.path }) || url.path == "/" { return "internaldrive" }
        return "folder"
    }
}

/// Plain crumb that gets a soft fill on hover and press.
private struct StorageCrumbButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StorageHoverFill(isPressed: configuration.isPressed) { configuration.label }
    }
}

/// Soft rounded fill that tracks hover and press.
struct StorageHoverFill<Content: View>: View {
    var isPressed: Bool
    var cornerRadius: CGFloat = 6
    @ViewBuilder var content: Content

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.primary.opacity(!isEnabled ? 0 : (isPressed ? 0.10 : (isHovered ? 0.06 : 0)))))
            .onHover { hovering in if hovering != isHovered { isHovered = hovering } }
            .animation(Tokens.quick, value: isHovered)
    }
}
