import AppKit
import SwiftUI

/// Glass pill in the footer while conversions exist; opens a popover with every job.
struct ConversionsPill: View {
    @Environment(ConversionStore.self) private var conversions
    @State private var isShowingJobs = false

    var body: some View {
        let active = conversions.activeCount
        Button { isShowingJobs.toggle() } label: {
            HStack(spacing: 7) {
                if active > 0 {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(active > 0 ? "Converting \(active)" : "Conversions")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            .padding(.horizontal, 13)
            .frame(height: 34)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help("Show conversions")
        .accessibilityLabel(active > 0 ? "\(active) conversions running" : "Conversions")
        .popover(isPresented: $isShowingJobs, arrowEdge: .top) {
            ConversionJobsList()
        }
    }
}

/// Popover list of conversion jobs, newest first.
struct ConversionJobsList: View {
    @Environment(ConversionStore.self) private var conversions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Conversions").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Clear Finished") { conversions.clearFinished() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(!conversions.jobs.contains { $0.state != .running })
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if conversions.jobs.isEmpty {
                Text("No conversions")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(conversions.jobs) { job in
                            ConversionJobRow(job: job)
                            if job.id != conversions.jobs.last?.id { Divider().padding(.leading, 50) }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 340)
    }
}

struct ConversionJobRow: View {
    let job: ConversionJob
    @Environment(ConversionStore.self) private var conversions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.target.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                Text(job.output.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(job.output.path)
                detail
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder private var detail: some View {
        switch job.state {
        case .running:
            HStack(spacing: 6) {
                ProgressCapsule(progress: job.progress, height: 4)
                Text(job.progress.map { Format.percent($0) } ?? job.target.label)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        case .completed:
            Label("Done · \(job.target.label)", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(2)
        case .cancelled:
            Text("Cancelled")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch job.state {
        case .running:
            CircleGlassButton(title: "Cancel", symbol: "xmark") { conversions.cancel(job) }
        case .completed:
            CircleGlassButton(title: "Show in Finder", symbol: "magnifyingglass") {
                FinderReveal.reveal([job.output])
            }
        default:
            EmptyView()
        }
    }
}
