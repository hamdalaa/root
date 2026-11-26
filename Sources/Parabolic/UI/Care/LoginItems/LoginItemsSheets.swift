import SwiftUI

/// States exactly what turning off or removing will do, and only acts on the explicit button.
struct LoginItemConfirmSheet: View {
    @Bindable var model: LoginItemsModel
    let pending: LoginItemsModel.Pending

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch pending {
            case .disable(let entry): disable(entry)
            case .remove(let entries): remove(entries)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private func disable(_ entry: LoginItemEntry) -> some View {
        Group {
            Text("Turn off \(entry.owner.name)?").font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                point("stop.circle", entry.status.isActive
                      ? "Stops \(entry.label) now\(pidText(entry))."
                      : "\(entry.label) isn’t running now.")
                point("power", "It won’t start at login or on demand until you turn it back on.")
                point("doc", "The file stays in ~/Library/LaunchAgents — nothing is deleted.")
            }
            if entry.owner.appPath != nil {
                Text("\(entry.owner.name) may stop syncing, updating or showing its menu bar icon while this is off.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            buttons(confirm: "Turn Off") { model.confirmDisable(entry) }
        }
    }

    private func remove(_ entries: [LoginItemEntry]) -> some View {
        Group {
            Text(entries.count == 1 ? "Remove broken item?" : "Remove \(entries.count) broken items?")
                .font(.system(size: 16, weight: .semibold))
            Text("These point at programs that no longer exist, so they can’t run. Their files move to the Trash and are unloaded from launchd.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.plistURL.lastPathComponent).font(.system(size: 12, design: .monospaced))
                            Text(entry.health.reason ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(2).truncationMode(.middle)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .background(.primary.opacity(0.04), in: .rect(cornerRadius: 10))
            buttons(confirm: "Move to Trash", destructive: true) { model.confirmRemove(entries) }
        }
    }

    private func pidText(_ entry: LoginItemEntry) -> String {
        if case .running(let pid) = entry.status, pid > 0 { return " (PID \(pid))" }
        return ""
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
        }
    }

    private func buttons(confirm: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { model.pending = nil }.keyboardShortcut(.cancelAction)
            Button(confirm, role: destructive ? .destructive : nil, action: action)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .tint(destructive ? .red : .accentColor)
        }
    }
}
