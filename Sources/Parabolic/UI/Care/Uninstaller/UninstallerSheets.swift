import AppKit
import SwiftUI

/// Confirm → working → result, in one sheet so the flow never jumps between windows.
struct UninstallerFlowSheet: View {
    @Bindable var model: UninstallerModel
    let flow: UninstallerModel.Flow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch flow {
            case .confirmApp(let plan): confirmApp(plan)
            case .confirmLeftovers(let items): confirmLeftovers(items)
            case .working(let message): working(message)
            case .result(let title, let outcome): result(title, outcome)
            }
        }
        .padding(22)
        .frame(width: 460)
        .interactiveDismissDisabled(isWorking)
    }

    private var isWorking: Bool { if case .working = flow { true } else { false } }

    // MARK: Confirm

    private func confirmApp(_ plan: UninstallerPlan) -> some View {
        let app = plan.app
        return Group {
            HStack(spacing: 12) {
                Image(nsImage: UninstallerUI.icon(app.url.path)).resizable().frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Uninstall \(app.name)?").font(.system(size: 16, weight: .semibold))
                    Text(totalLine(plan)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                bullet("trash", "Moves \(app.url.lastPathComponent) (\(UninstallerUI.size(plan.appBytes))) to the Trash.")
                if !plan.files.isEmpty {
                    bullet("folder", "Moves \(plan.files.count) support item\(plan.files.count == 1 ? "" : "s") (\(UninstallerUI.size(plan.fileBytes))) to the Trash.")
                }
                let moved = plan.files.compactMap { $0.link.target }
                if !moved.isEmpty {
                    let volumes = Set(moved.map { UninstallVolume.from(path: $0.path).title }).sorted().joined(separator: ", ")
                    bullet("externaldrive", "\(moved.count) of these live\(moved.count == 1 ? "s" : "") on \(volumes) behind a link. The data and the link both go to the Trash.")
                }
                if plan.agentCount > 0 {
                    bullet("gearshape.2", "Stops \(plan.agentCount) background item\(plan.agentCount == 1 ? "" : "s") before removing it.")
                }
                if !app.aliases.isEmpty {
                    bullet("link", "Removes the shortcut\(app.aliases.count == 1 ? "" : "s") in \(app.aliases.map { $0.deletingLastPathComponent().lastPathComponent }.joined(separator: ", ")).")
                }
                if plan.isRunning {
                    bullet("xmark.app", "\(app.name) is open. Root asks it to quit first — save your work in it.", tint: .yellow)
                }
                if app.needsAdmin {
                    bullet("lock", "macOS will ask for an administrator password because this app belongs to the system.")
                }
                if plan.pendingSizes {
                    bullet("hourglass", "Some sizes are still being measured, so the total may be higher.")
                }
            }
            Text("Everything can be put back from the Trash until you empty it.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.flow = nil }
                    .keyboardShortcut(.cancelAction)
                Button(plan.isRunning ? "Quit and Uninstall" : "Uninstall", role: .destructive) {
                    model.performUninstall(plan)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .tint(.red)
            }
        }
    }

    private func totalLine(_ plan: UninstallerPlan) -> String {
        let count = 1 + plan.files.count + plan.app.aliases.count
        return "\(count) item\(count == 1 ? "" : "s") · \(UninstallerUI.size(plan.totalBytes)) in total"
    }

    private func confirmLeftovers(_ items: [UninstallTrashItem]) -> some View {
        let bytes = items.compactMap(\.bytes).reduce(0, +)
        return Group {
            VStack(alignment: .leading, spacing: 4) {
                Text("Move \(items.count) leftover\(items.count == 1 ? "" : "s") to the Trash?")
                    .font(.system(size: 16, weight: .semibold))
                Text("\(UninstallerUI.size(bytes)) from apps that are no longer installed.")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items) { item in
                        HStack {
                            Text((item.url.path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(UninstallerUI.size(item.bytes)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 180)
            .background(.primary.opacity(0.04), in: .rect(cornerRadius: 10))
            Text("If an app you still use needs one of these, it recreates it or you can put it back from the Trash.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.flow = nil }.keyboardShortcut(.cancelAction)
                Button("Move to Trash", role: .destructive) { model.performLeftoverRemoval(items) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .tint(.red)
            }
        }
    }

    // MARK: Working / result

    private func working(_ message: String) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(message).font(.system(size: 13))
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .accessibilityElement(children: .combine)
    }

    private func result(_ title: String, _ outcome: UninstallTrashOutcome) -> some View {
        let success = outcome.failed.isEmpty && outcome.stopReason == nil
        return Group {
            Label {
                Text(title).font(.system(size: 16, weight: .semibold))
            } icon: {
                Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(success ? Color.green : Color.yellow)
            }
            if !outcome.removed.isEmpty {
                Text("Moved \(outcome.removed.count) item\(outcome.removed.count == 1 ? "" : "s") · \(UninstallerUI.size(outcome.removedBytes)) to the Trash.")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
            if let stop = outcome.stopReason {
                Text(stop).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            if !outcome.removed.isEmpty || !outcome.failed.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(outcome.failed, id: \.item.id) { failure in
                            resultRow(failure.item, symbol: "xmark.circle.fill", tint: .red, detail: failure.reason)
                        }
                        ForEach(outcome.removed) { item in
                            resultRow(item, symbol: "checkmark.circle", tint: .secondary, detail: nil)
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 200)
                .background(.primary.opacity(0.04), in: .rect(cornerRadius: 10))
            }
            HStack {
                if !outcome.removed.isEmpty {
                    Button("Open Trash") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash"))
                    }
                }
                Spacer()
                Button("Done") { model.flow = nil }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func resultRow(_ item: UninstallTrashItem, symbol: String, tint: Color, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer()
            if detail == nil, let bytes = item.bytes {
                Text(UninstallerUI.size(bytes)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .help(item.url.path)
        .accessibilityElement(children: .combine)
    }

    private func bullet(_ symbol: String, _ text: String, tint: Color = .secondary) -> some View {
        Label {
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
        }
    }
}
