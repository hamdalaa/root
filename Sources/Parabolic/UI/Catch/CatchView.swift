import AppKit
import SwiftUI

/// FDM-style popup for a caught download, in Root's own look (the main window's glass, tokens, chips and
/// grouped rows): confirm name, folder and options, then live progress.
struct CatchView: View {
    @Bindable var model: CatchModel
    let manager: DownloadManager
    let settings: AppSettings
    let history: HistoryStore
    let tools: ToolPaths
    /// Root's latest speed test, the basis of the time estimate.
    let lastSpeedTest: SpeedTest.Result?
    let close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("catchShowsDetails") private var showsDetails = false
    /// Return presses «Download» only after this short delay, so a keystroke meant for the browser can't.
    @State private var isReturnArmed = false
    @State private var freeSpace: Int64?
    private static let returnArmDelay: Duration = .milliseconds(400)
    static let width: CGFloat = 480

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space4) {
            CatchHeader(model: model, isEditable: model.stage == .confirm, eta: eta)
            switch model.stage {
            case .confirm: confirm
            case .downloading(let id): CatchProgressView(item: manager.item(id), manager: manager, settings: settings, close: close)
            case .cancelled: EmptyView()
            }
        }
        .padding(Tokens.space5)
        .frame(width: Self.width)
        .animation(reduceMotion ? nil : Tokens.motion, value: model.stage)
        .animation(reduceMotion ? nil : Tokens.motion, value: showsDetails)
        .task { await model.probe(prefs: settings.prefs, tools: tools) }
        .task {
            try? await Task.sleep(for: Self.returnArmDelay)
            isReturnArmed = true
        }
        .task(id: model.folder) {
            let folder = model.folder
            freeSpace = await Task.detached(priority: .utility) { CatchDetails.freeSpace(at: folder) }.value
        }
    }

    private var eta: Int? { CatchDetails.eta(bytes: model.size, mbps: lastSpeedTest?.downloadMbps) }
    private var space: CatchDetails.Space { CatchDetails.space(free: freeSpace, needed: model.size) }

    // MARK: Confirm

    private var confirm: some View {
        VStack(alignment: .leading, spacing: Tokens.space3) {
            notices
            folderRow
            if model.isMediaPage { qualityRow }
            options
            CatchDetailsSection(model: model, settings: settings, lastSpeedTest: lastSpeedTest, eta: eta,
                                freeSpace: freeSpace, space: space, isExpanded: $showsDetails)
            buttons
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let running = manager.activeDuplicate(url: model.source.url, filename: model.filename) {
            HStack(spacing: Tokens.space2) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.parabolicAccent)
                Text("Already downloading this file\(running.progress.map { " · \(Format.percent($0))" } ?? "")")
                    .font(.system(size: 12))
                Spacer()
                Button("Show Progress") { model.stage = .downloading(running.id) }
                    .buttonStyle(CatchSecondaryButtonStyle(compact: true))
            }
            .padding(10)
            .glassPanel(cornerRadius: Tokens.radiusRow, tint: Color.parabolicAccent.opacity(0.12))
        }
        if let previous = history.previous(for: model.source.url) {
            DuplicateNotice(entry: previous, compact: true)
        }
    }

    private var folderRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.parabolicAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text((model.folder as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(spaceLine)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(spaceColor)
            }
            Spacer(minLength: Tokens.space2)
            Button("Change…", action: chooseFolder)
                .buttonStyle(CatchSecondaryButtonStyle(compact: true))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: Tokens.radiusRow)
        .accessibilityElement(children: .combine)
    }

    private var spaceLine: String {
        guard let freeSpace else { return "Checking free space…" }
        let free = "\(Format.bytes(freeSpace)) free"
        switch space {
        case .notEnough: return "\(free) · not enough for this file"
        case .low: return "\(free) · low"
        case .plenty, .unknown: return free
        }
    }

    private var spaceColor: Color {
        switch space {
        case .notEnough: .red
        case .low: .yellow
        case .plenty, .unknown: .secondary
        }
    }

    private var qualityRow: some View {
        HStack(spacing: 10) {
            Image(systemName: model.preset?.symbol ?? "slider.horizontal.3")
                .font(.system(size: 14))
                .foregroundStyle(Color.parabolicAccent)
                .frame(width: 18)
            Text("Quality").font(.system(size: 13, weight: .medium))
            Spacer()
            Picker("Quality", selection: $model.preset) {
                ForEach(settings.prefs.allPresets) { preset in
                    Label(preset.name, systemImage: preset.symbol).tag(Optional(preset))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassPanel(cornerRadius: Tokens.radiusRow)
    }

    private var options: some View {
        HStack(spacing: Tokens.space4) {
            if !model.isMediaPage {
                Toggle("Start paused", isOn: $model.startPaused)
                    .help("Add it to the list without starting. Kept for the next popup.")
            }
            if !model.fileType.isEmpty {
                Toggle("Don’t ask for \(model.fileType.uppercased()) files", isOn: $model.skipThisType)
                    .help("\(model.fileType.uppercased()) files will start straight away. Undo in Settings → Browser.")
            }
            Spacer(minLength: 0)
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Cancel", role: .cancel) { model.stage = .cancelled; close() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(CatchSecondaryButtonStyle())
            if !model.isMediaPage {
                Button("Download Later") { start(paused: true) }
                    .buttonStyle(CatchSecondaryButtonStyle())
                    .help("Add to the list without starting")
            }
            Button(model.startPaused && !model.isMediaPage ? "Add Paused" : "Download") {
                start(paused: model.startPaused && !model.isMediaPage)
            }
            .keyboardShortcut(isReturnArmed ? .defaultAction : nil)
            .buttonStyle(CatchPrimaryButtonStyle())
            .disabled(space == .notEnough)
        }
    }

    // MARK: Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.folder)
        if panel.runModal() == .OK, let url = panel.url { model.folder = url.path }
    }

    private func start(paused: Bool) {
        // Same file already downloading (e.g. another mirror): follow that one instead of splitting the line.
        if let existing = manager.activeDuplicate(url: model.source.url, filename: model.filename) {
            model.stage = .downloading(existing.id)
            return
        }
        let request = model.request(paused: paused)
        var prefs = settings.prefs
        model.remember(in: &prefs)
        if prefs != settings.prefs { settings.prefs = prefs }
        let item: DownloadItem?
        if model.isMediaPage {
            item = manager.quickDownload(url: request.url, preset: request.preset, headers: request.headers, folder: request.folder)
        } else {
            item = manager.enqueueFile(url: request.url, filename: request.filename, headers: request.headers,
                                       folder: request.folder, size: request.size)
        }
        guard let item else { close(); return }
        if request.startPaused {
            manager.stop(item)
            close()
        } else {
            model.stage = .downloading(item.id)
        }
    }
}

/// Solid accent pill that stays vivid even when the floating panel isn't key
/// (system prominent buttons grey out in inactive panels and look disabled).
struct CatchPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(Color.parabolicAccent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Tokens.quick, value: configuration.isPressed)
            .contentShape(.capsule)
    }
}

/// Glass capsule for the popup's other buttons, with the label at full strength even when the panel isn't key
/// (system glass buttons dim their labels in an inactive panel, so Cancel looked disabled).
struct CatchSecondaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .foregroundStyle(.primary.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, compact ? 12 : 14)
            .frame(height: compact ? 24 : 30)
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(.capsule)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Tokens.quick, value: configuration.isPressed)
    }
}
