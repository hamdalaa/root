import SwiftUI

/// The selected app: facts, every related file with a checkbox, and the Uninstall button.
struct UninstallerDetailPane: View {
    @Bindable var model: UninstallerModel

    var body: some View {
        Group {
            if let app = model.selectedApp {
                content(app)
            } else {
                ContentUnavailableView("Select an app", systemImage: "app.badge.checkmark",
                                       description: Text("You’ll see the app and every support file it left in your Library."))
            }
        }
        .frame(maxHeight: .infinity)
        .glassPanel(cornerRadius: 18)
        .hairline(cornerRadius: 18)
    }

    private func content(_ app: UninstallApp) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    identity(app)
                    facts(app)
                    files(app)
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
            Divider().opacity(0.5)
            footer(app)
        }
    }

    private func identity(_ app: UninstallApp) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: UninstallerUI.icon(app.url.path))
                .resizable()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 17, weight: .semibold)).lineLimit(2)
                Text(app.version.map { "Version \($0)" } ?? "No version number")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let id = app.bundleID {
                    Text(id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                        .textSelection(.enabled).lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func facts(_ app: UninstallApp) -> some View {
        VStack(spacing: 0) {
            factRow("Location", value: (app.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                    help: app.url.path) {
                Button { UninstallerUI.reveal([app.url]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless).help("Show in Finder").accessibilityLabel("Show \(app.name) in Finder")
            }
            factRow("Size", value: model.sizes[app.id].map { UninstallerUI.size($0) }
                        ?? (model.unmeasurable.contains(app.id) ? "Couldn’t be measured" : "Measuring…")) { EmptyView() }
            factRow("Last opened", value: app.lastUsed.map { $0.formatted(date: .abbreviated, time: .omitted) }
                        ?? "Unknown — Spotlight has no record") { EmptyView() }
            factRow("Installed from", value: app.isAppStore ? "App Store" : "Outside the App Store") { EmptyView() }
            if !app.aliases.isEmpty {
                factRow("Also linked from", value: app.aliases.map { $0.deletingLastPathComponent().path }.joined(separator: ", "),
                        showsDivider: false) { EmptyView() }
            }
        }
        .padding(.vertical, 2)
        .background(.primary.opacity(0.04), in: .rect(cornerRadius: 12))
    }

    private func factRow<Trailing: View>(_ title: String, value: String, help: String? = nil, showsDivider: Bool = true,
                                         @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                Text(value).font(.system(size: 12).monospacedDigit()).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(help ?? value)
                trailing()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            if showsDivider { Divider().padding(.leading, 12).opacity(0.6) }
        }
    }

    @ViewBuilder
    private func files(_ app: UninstallApp) -> some View {
        if let files = model.files(for: app) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(files.isEmpty ? "No support files found" : "Support files")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if files.count > 1 {
                        let allOn = files.allSatisfy(model.isChecked)
                        Button(allOn ? "Select None" : "Select All") { model.setAll(files, checked: !allOn) }
                            .buttonStyle(.borderless).font(.system(size: 11))
                    }
                }
                .padding(.horizontal, 4)
                if files.isEmpty {
                    Text("Nothing in your Library is named after \(app.name), so only the app itself goes to the Trash.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                } else {
                    VStack(spacing: 2) {
                        ForEach(files) { file in
                            UninstallerFileRow(file: file, measurement: model.fileSizes[file.id],
                                               isChecked: Binding(get: { model.isChecked(file) },
                                                                  set: { model.setChecked(file, $0) }))
                        }
                    }
                    if files.contains(where: { !UninstallerModel.isDefaultSelected($0) }) {
                        Text("Items shared with another app, or matched only by developer, are left unchecked.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for support files…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    private func footer(_ app: UninstallApp) -> some View {
        let ready = model.files(for: app) != nil
        let bytes = model.plannedBytes(for: app)
        let count = (model.files(for: app) ?? []).filter(model.isChecked).count
        return VStack(spacing: 6) {
            Button { model.requestUninstall(app) } label: {
                Text(bytes.map { "Uninstall — \(UninstallerUI.size($0))" } ?? "Uninstall…")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!ready)
            .help("Review what will be moved to the Trash")
            Text(ready ? "\(app.name) and \(count) support item\(count == 1 ? "" : "s") go to the Trash. Nothing is erased."
                       : "Checking what \(app.name) installed…")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(14)
    }
}

/// One support file with a checkbox, size and Reveal.
private struct UninstallerFileRow: View {
    let file: UninstallRelatedFile
    let measurement: UninstallSizer.Measurement?
    @Binding var isChecked: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $isChecked) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Remove \(file.url.lastPathComponent)")
            Image(systemName: file.kind.symbol)
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(file.link.target.map { "\(file.url.path) → \($0.path)" } ?? file.url.path)
            Button { UninstallerUI.reveal([file.link.target ?? file.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .opacity(isHovered ? 1 : 0)
                .help("Show in Finder")
                .accessibilityLabel("Show \(file.url.lastPathComponent) in Finder")
            sizeText.frame(minWidth: 58, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.primary.opacity(isHovered ? 0.05 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture { isChecked.toggle() }
    }

    private var subtitle: String {
        var parts = [file.kind.title]
        if let note = UninstallerUI.linkNote(file.link) { parts.append(note) }
        parts.append(file.sharedWith.map { "also used by \($0)" } ?? file.match.note)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var sizeText: some View {
        if let label = UninstallerUI.linkSizeLabel(file.link) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                .help(UninstallerUI.linkHelp(file.link))
        } else if let measurement {
            Text(measurement.bytes.map { UninstallerUI.size($0) + (measurement.isPartial ? "+" : "") } ?? "Can’t read")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .help(measurement.isPartial ? "Some contents couldn’t be read, so it’s at least this big" : "")
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}
