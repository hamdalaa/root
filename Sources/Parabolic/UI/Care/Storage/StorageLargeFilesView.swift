import SwiftUI

fileprivate extension StorageLargeFile {
    var lastUsedSort: Date { lastUsed ?? .distantPast }
    var kindTitle: String { kind.title }
}

/// Files above a size threshold across Home and every other disk, with kind filters and multi-select actions.
struct StorageLargeFilesView: View {
    let model: StorageLargeFilesModel

    @State private var previewURL: URL?
    @State private var trashRequest: StorageTrashRequest?
    @State private var trashErrors: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            if !model.kindCounts.isEmpty { kindFilters }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .quickLookPreview($previewURL)
        .confirmationDialog(trashRequest?.title ?? "", isPresented: isConfirmingTrash, titleVisibility: .visible,
                            presenting: trashRequest) { request in
            Button("Move to Trash", role: .destructive) { performTrash(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
        .alert("Some files weren’t moved to the Trash", isPresented: hasTrashErrors) {
            Button("OK") { trashErrors = [] }
        } message: {
            Text(trashErrors.joined(separator: "\n"))
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Text("Larger than")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Picker("Larger than", selection: Binding(get: { model.threshold }, set: { model.setThreshold($0) })) {
                ForEach(StorageThreshold.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 290)
            Spacer(minLength: 8)
            status
            Button { model.isSearching ? model.stop() : model.search() } label: {
                Image(systemName: model.isSearching ? "stop.fill" : "arrow.clockwise").frame(width: 16, height: 16)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .keyboardShortcut("r", modifiers: .command)
            .help(model.isSearching ? "Stop searching" : "Search again")
            .accessibilityLabel(model.isSearching ? "Stop searching" : "Search again")
        }
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .searching(let message):
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(message).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        case .stopped:
            Text("Stopped. Results may be incomplete.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .done:
            if let searchedAt = model.searchedAt {
                Text("Searched \(searchedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        case .idle:
            EmptyView()
        }
    }

    private var kindFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                let files = model.aboveThreshold
                StorageFilterChip(title: "All", count: files.count, bytes: files.reduce(0) { $0 + $1.diskBytes },
                                  symbol: nil, isOn: model.kind == nil) { model.setKind(nil) }
                ForEach(model.kindCounts, id: \.kind) { entry in
                    StorageFilterChip(title: entry.kind.title, count: entry.count, bytes: entry.bytes,
                                      symbol: entry.kind.symbol, isOn: model.kind == entry.kind) {
                        model.setKind(model.kind == entry.kind ? nil : entry.kind)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        let files = model.visible
        if files.isEmpty {
            Group {
                switch model.phase {
                case .idle:
                    StorageStateView(symbol: "doc.badge.ellipsis", title: "Find your largest files",
                                     message: "Root asks Spotlight for big files in your Home folder and on your other disks.") {
                        Button("Search") { model.search() }.buttonStyle(.glassProminent).controlSize(.large)
                    }
                case .searching(let message):
                    StorageStateView(symbol: "magnifyingglass", title: "Searching…", message: message) {
                        ProgressView().controlSize(.small)
                    }
                case .done, .stopped:
                    StorageStateView(symbol: "checkmark.circle", title: emptyTitle,
                                     message: "Nothing in your Home folder or on your other disks is that large.",
                                     tint: .green) {
                        if model.kind != nil { Button("Show All Kinds") { model.setKind(nil) }.buttonStyle(.glass) }
                        if model.threshold != .mb100 {
                            Button("Try 100 MB") { model.setThreshold(.mb100) }.buttonStyle(.glass)
                        }
                    }
                }
            }
            .glassPanel(cornerRadius: 18)
            .hairline(cornerRadius: 18)
        } else {
            table(files)
                .glassPanel(cornerRadius: 18)
                .hairline(cornerRadius: 18)
        }
    }

    private var emptyTitle: String {
        let what = model.kind.map { $0.title.lowercased() } ?? "files"
        return "No \(what) larger than \(model.threshold.title)"
    }

    private func table(_ files: [StorageLargeFile]) -> some View {
        Table(files, selection: Binding(get: { model.selection }, set: { model.setSelection($0) }),
              sortOrder: Binding(get: { model.sortOrder }, set: { model.setSortOrder($0) })) {
            TableColumn("Name", value: \.name) { file in
                HStack(spacing: 8) {
                    StorageIcons.image(for: file.url)
                        .resizable()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                        if file.isSparse {
                            Text("Sparse: \(Format.bytes(file.size)) file, \(Format.bytes(file.diskBytes)) on disk")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if file.protectionReason != nil {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .help(file.protectionReason ?? "")
                            .accessibilityLabel("Protected")
                    }
                }
            }
            .width(min: 180, ideal: 260)
            TableColumn("Kind", value: \.kindTitle) { file in
                Text(file.kind.title).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 96)
            TableColumn("Size", value: \.diskBytes) { file in
                Text(Format.bytes(file.diskBytes))
                    .monospacedDigit()
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 84)
            TableColumn("Last Opened", value: \.lastUsedSort) { file in
                Text(file.lastUsed.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help(file.lastUsed == nil ? "macOS has no record of this file being opened." : "")
            }
            .width(min: 80, ideal: 100)
            TableColumn("Location", value: \.location) { file in
                Text(file.location)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.url.deletingLastPathComponent().path)
            }
            .width(min: 120, ideal: 220)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: URL.self) { urls in
            menu(for: model.all.filter { urls.contains($0.url) })
        } primaryAction: { urls in
            if let url = urls.first { previewURL = url }
        }
        .onKeyPress(.space) {
            guard let url = model.selection.first else { return .ignored }
            previewURL = previewURL == url ? nil : url
            return .handled
        }
        .accessibilityLabel("Large files")
    }

    @ViewBuilder private func menu(for files: [StorageLargeFile]) -> some View {
        if files.count == 1, let file = files.first {
            Button("Quick Look") { previewURL = file.url }
        }
        if !files.isEmpty {
            Button("Reveal in Finder") { StorageFinder.reveal(files.map(\.url)) }
            Button(files.count == 1 ? "Copy Path" : "Copy Paths") { StorageFinder.copyPaths(files.map(\.url)) }
            Divider()
            if files.allSatisfy({ !$0.canTrash }) {
                Button("Can’t Move to Trash: \(files[0].protectionReason ?? "Protected")") {}.disabled(true)
            } else {
                Button("Move to Trash…", role: .destructive) { requestTrash(files) }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            let selected = model.selectedFiles
            if selected.isEmpty {
                let files = model.visible
                if !files.isEmpty {
                    Text("\(files.count.formatted()) file\(files.count == 1 ? "" : "s") · \(Format.bytes(files.reduce(0) { $0 + $1.diskBytes }))")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                }
                sourceNote
            } else {
                Text("\(selected.count.formatted()) selected · \(Format.bytes(selected.reduce(0) { $0 + $1.diskBytes }))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            if !selected.isEmpty {
                Button("Reveal in Finder") { StorageFinder.reveal(selected.map(\.url)) }
                    .buttonStyle(.glass)
                Button(role: .destructive) { requestTrash(selected) } label: {
                    Label("Move to Trash…", systemImage: "trash")
                }
                .buttonStyle(.glass)
                .tint(.red)
                .disabled(selected.allSatisfy { !$0.canTrash })
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .frame(minHeight: 28)
    }

    @ViewBuilder private var sourceNote: some View {
        let spotlight = model.notes.filter { $0.method == .spotlight }.map(\.name)
        let walked = model.notes.filter { $0.method == .walk }
        if !model.notes.isEmpty {
            HStack(spacing: 4) {
                if !spotlight.isEmpty {
                    Text("Spotlight: \(spotlight.joined(separator: ", "))")
                }
                if !walked.isEmpty {
                    Text("· Walked without Spotlight: \(walked.map(\.name).joined(separator: ", "))")
                }
                let unreadable = walked.reduce(0) { $0 + $1.unreadable }
                if unreadable > 0 {
                    Text("· \(unreadable) unreadable folder\(unreadable == 1 ? "" : "s")")
                        .foregroundStyle(.yellow)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .help("Spotlight doesn’t index caches and some system folders, so files there aren’t listed.")
        }
    }

    // MARK: Trash

    private func requestTrash(_ files: [StorageLargeFile]) {
        let allowed = files.filter(\.canTrash)
        guard !allowed.isEmpty else { return }
        trashRequest = StorageTrashRequest(urls: allowed.map(\.url), bytes: allowed.reduce(0) { $0 + $1.diskBytes },
                                           fileCount: allowed.count, skipped: files.count - allowed.count)
    }

    private func performTrash(_ request: StorageTrashRequest) {
        trashRequest = nil
        Task {
            let failures = await model.trash(request.urls)
            if !failures.isEmpty { trashErrors = failures.map { "\($0.0.lastPathComponent): \($0.1)" } }
        }
    }

    private var isConfirmingTrash: Binding<Bool> {
        Binding(get: { trashRequest != nil }, set: { if !$0, trashRequest != nil { trashRequest = nil } })
    }

    private var hasTrashErrors: Binding<Bool> {
        Binding(get: { !trashErrors.isEmpty }, set: { if !$0, !trashErrors.isEmpty { trashErrors = [] } })
    }
}

/// Kind filter capsule with a count; tinted with the accent when on.
private struct StorageFilterChip: View {
    let title: String
    let count: Int
    let bytes: Int64
    let symbol: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(title)
                Text(count.formatted())
                    .monospacedDigit()
                    .foregroundStyle(isOn ? Color.accentColor.opacity(0.8) : Color.secondary)
            }
            .font(.system(size: 11.5, weight: isOn ? .semibold : .medium))
            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(isOn ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.07)))
            .contentShape(.capsule)
        }
        .buttonStyle(StorageChipButtonStyle())
        .help("\(count) \(title.lowercased()) · \(Format.bytes(bytes))")
        .accessibilityLabel(title)
        .accessibilityValue("\(count) files, \(Format.bytes(bytes))")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct StorageChipButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        StorageHoverFill(isPressed: configuration.isPressed, cornerRadius: 13) { configuration.label }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
