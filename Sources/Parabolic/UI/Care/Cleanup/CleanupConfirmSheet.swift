import SwiftUI

/// States exactly what will happen to each ticked category before anything is touched.
struct CleanupConfirmSheet: View {
    @Bindable var store: CleanupStore
    @Environment(\.dismiss) private var dismiss
    @State private var deleteCachesImmediately = false
    @State private var confirmsEmptyTrash = false

    private struct Line: Identifiable {
        var id: CleanupCategoryID { category }
        let category: CleanupCategoryID
        let count: Int
        let bytes: Int64
        let action: CleanupAction
        let inUse: Int
    }

    var body: some View {
        let plan = store.plan(deleteCachesImmediately: deleteCachesImmediately)
        let lines = lines(for: plan)
        let total = plan.reduce(Int64(0)) { $0 + $1.item.bytes }
        let trashBytes = plan.filter { $0.category == .trash }.reduce(Int64(0)) { $0 + $1.item.bytes }
        let erasesTrash = plan.contains { $0.category == .trash }
        let hasCaches = store.selectedEntries.contains { $0.0.allowsImmediateDelete && $0.1.isCache }
        let inUse = plan.filter { $0.item.inUseBy != nil }.count

        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                CleanupSymbolTile(symbol: "sparkles", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean \(CleanupFormat.bytes(total))?")
                        .font(.system(size: 17, weight: .semibold))
                    Text("\(CleanupFormat.items(plan.count)) in \(lines.count) categor\(lines.count == 1 ? "y" : "ies")")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    row(line)
                    if index < lines.count - 1 { Divider().padding(.leading, 44) }
                }
            }
            .padding(.vertical, 4)
            .background(.primary.opacity(0.04), in: .rect(cornerRadius: Tokens.radiusRow))

            if hasCaches {
                Toggle(isOn: Binding(get: { deleteCachesImmediately },
                                     set: { if $0 != deleteCachesImmediately { deleteCachesImmediately = $0 } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete caches immediately")
                            .font(.system(size: 13))
                        Text("Skips the Trash for app, browser and developer caches so the space comes back now. Apps rebuild caches as needed. This can’t be undone.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
            }

            if erasesTrash {
                VStack(alignment: .leading, spacing: 8) {
                    Label("The Trash will be emptied", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.red)
                    Toggle(isOn: Binding(get: { confirmsEmptyTrash },
                                         set: { if $0 != confirmsEmptyTrash { confirmsEmptyTrash = $0 } })) {
                        Text("Permanently erase \(CleanupFormat.bytes(trashBytes)) in the Trash. These items can’t be recovered.")
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: .rect(cornerRadius: Tokens.radiusControl + 2))
            }

            VStack(alignment: .leading, spacing: 4) {
                if inUse > 0 {
                    Label("\(CleanupFormat.items(inUse)) belong to apps that are open. Quit them first for the best result; they may recreate the files.",
                          systemImage: "app.badge")
                        .foregroundStyle(.secondary)
                }
                if plan.contains(where: { $0.action == .trash }) {
                    Label("Items moved to the Trash free their space when you empty it. You can put them back from the Trash until then.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .labelStyle(CleanupTopAlignedLabelStyle())
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle(plan)) {
                    store.clean(deleteCachesImmediately: deleteCachesImmediately)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(erasesTrash ? .red : .accentColor)
                .keyboardShortcut(.defaultAction)
                .disabled(plan.isEmpty || (erasesTrash && !confirmsEmptyTrash))
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 500)
    }

    private func primaryTitle(_ plan: [CleanupPlanEntry]) -> String {
        if plan.allSatisfy({ $0.action == .trash }) { return "Move to Trash" }
        if plan.allSatisfy({ $0.action == .delete }) { return "Delete" }
        return "Clean"
    }

    private func lines(for plan: [CleanupPlanEntry]) -> [Line] {
        let grouped = Dictionary(grouping: plan) { "\($0.category.rawValue)|\($0.action.rawValue)" }
        return grouped.values.compactMap { entries -> Line? in
            guard let first = entries.first else { return nil }
            return Line(category: first.category, count: entries.count,
                        bytes: entries.reduce(0) { $0 + $1.item.bytes }, action: first.action,
                        inUse: entries.filter { $0.item.inUseBy != nil }.count)
        }
        .sorted { lhs, rhs in
            let order = CleanupCategoryID.allCases
            let a = order.firstIndex(of: lhs.category)!, b = order.firstIndex(of: rhs.category)!
            return a == b ? lhs.action.rawValue < rhs.action.rawValue : a < b
        }
    }

    private func row(_ line: Line) -> some View {
        HStack(spacing: 10) {
            CleanupSymbolTile(symbol: line.category.symbol, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.category.title).font(.system(size: 13))
                Text(destination(line))
                    .font(.system(size: 11))
                    .foregroundStyle(line.action == .delete ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(CleanupFormat.bytes(line.bytes))
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                Text(CleanupFormat.items(line.count))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private func destination(_ line: Line) -> String {
        switch (line.category, line.action) {
        case (.trash, _): "Erased permanently"
        case (_, .delete): "Deleted now, can’t be undone"
        case (_, .trash): "Moved to the Trash"
        }
    }
}

struct CleanupTopAlignedLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}
