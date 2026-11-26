import SwiftUI

/// Result of a clean. The headline is the measured change in free space, not the sum of item sizes.
struct CleanupOutcomeView: View {
    @Bindable var store: CleanupStore
    @State private var showsFailures = false

    var body: some View {
        if let outcome = store.outcome {
            content(outcome)
        }
    }

    private func content(_ outcome: CleanupOutcome) -> some View {
        let freed = outcome.measuredFreedBytes
        let hasFailures = !outcome.failures.isEmpty
        let nothingDone = outcome.trashedCount + outcome.deletedCount == 0
        return VStack(spacing: 16) {
            CleanupOrb(progress: 1, tint: nothingDone ? .yellow : .green) {
                Image(systemName: nothingDone ? "exclamationmark" : "checkmark")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(nothingDone ? .yellow : .green)
            }
            VStack(spacing: 6) {
                Text(headline(freed: freed, nothingDone: nothingDone))
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .multilineTextAlignment(.center)
                Text(freeSpaceNote(outcome))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            VStack(spacing: 0) {
                if outcome.trashedCount > 0 {
                    line("trash", "Moved to the Trash",
                         "\(CleanupFormat.items(outcome.trashedCount)) · \(CleanupFormat.bytes(outcome.trashedBytes))",
                         note: "Frees its space when you empty the Trash.")
                }
                if outcome.deletedCount > 0 {
                    line("xmark.bin", "Deleted",
                         "\(CleanupFormat.items(outcome.deletedCount)) · \(CleanupFormat.bytes(outcome.deletedBytes))",
                         note: nil)
                }
                if hasFailures {
                    failuresLine(outcome.failures)
                }
            }
            .frame(maxWidth: 480)
            .background(.primary.opacity(0.04), in: .rect(cornerRadius: Tokens.radiusRow))

            HStack(spacing: 10) {
                Button("Scan again", systemImage: "arrow.clockwise", action: store.scan)
                    .buttonStyle(.glass)
                Button("Done", action: store.dismissOutcome)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .transition(.opacity)
    }

    private func headline(freed: Int64?, nothingDone: Bool) -> String {
        if nothingDone { return "Nothing was removed" }
        guard let freed else { return "Cleaned" }
        if freed > 0 { return "\(CleanupFormat.bytes(freed)) more free space" }
        return "Cleaned"
    }

    private func freeSpaceNote(_ outcome: CleanupOutcome) -> String {
        let volumes = outcome.volumeNames.isEmpty ? "the disk" : ListFormatter.localizedString(byJoining: outcome.volumeNames)
        guard let freed = outcome.measuredFreedBytes else {
            return "Couldn’t read free space on \(volumes), so the change wasn’t measured."
        }
        if freed > 0 {
            return "Measured from free space on \(volumes) before and after cleaning."
        }
        if outcome.deletedCount == 0 && outcome.trashedCount > 0 {
            return "Free space on \(volumes) hasn’t changed yet because everything went to the Trash."
        }
        return "Free space on \(volumes) didn’t go up. Other apps may have written to the disk at the same time, or macOS hasn’t released the space yet."
    }

    private func line(_ symbol: String, _ title: String, _ value: String, note: String?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13))
                    if let note {
                        Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .accessibilityElement(children: .combine)
    }

    private func failuresLine(_ failures: [CleanupFailure]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showsFailures.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .frame(width: 20)
                    Text("\(CleanupFormat.items(failures.count)) couldn’t be removed")
                        .font(.system(size: 13))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showsFailures ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(failures.count) items couldn’t be removed")
            .accessibilityHint(showsFailures ? "Hide details" : "Show details")
            if showsFailures {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(failures.prefix(30)) { failure in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(failure.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text("\(failure.reason) · \(CleanupFormat.path(URL(fileURLWithPath: failure.path)))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if failures.count > 30 {
                        Text("and \(failures.count - 30) more")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 44)
                .padding(.trailing, 14)
                .padding(.bottom, 10)
            }
        }
    }
}
