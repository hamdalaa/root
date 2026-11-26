import SwiftUI

/// Mac Care → Memory: a live RAM analyzer. Composition and pressure up top, a five-minute pressure history,
/// ways to free memory, and every process rolled up under the app it belongs to.
struct MemoryView: View {
    private var monitor: MemoryMonitor { .shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let snapshot = monitor.snapshot {
                content(snapshot)
            } else if let error = monitor.readError {
                ContentUnavailableView {
                    Label("Can’t read memory", systemImage: "memorychip")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { monitor.retry() }
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading memory…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { monitor.primeIfNeeded() }
        // Samples once a second only while this screen is on screen; leaving it cancels the loop.
        .task { await monitor.run() }
    }

    private func content(_ snapshot: MemorySnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(snapshot)
                MemoryHero(snapshot: snapshot)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        MemoryPressureHistoryCard()
                        MemorySwapCard(snapshot: snapshot).frame(width: 270)
                    }
                    VStack(spacing: 16) {
                        MemoryPressureHistoryCard()
                        MemorySwapCard(snapshot: snapshot)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        MemorySuggestionsCard()
                        MemoryPurgeCard().frame(width: 320)
                    }
                    VStack(spacing: 16) {
                        MemorySuggestionsCard()
                        MemoryPurgeCard()
                    }
                }
                MemoryAppListCard()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .overlay(alignment: .bottom) { noticeBanner }
        .animation(reduceMotion ? nil : Tokens.motion, value: monitor.notice)
    }

    private func header(_ snapshot: MemorySnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Memory")
                    .font(.system(size: 22, weight: .semibold))
                Text("\(MemoryFormat.bytes(snapshot.breakdown.total)) installed · live from macOS")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            MemoryLiveIndicator()
        }
    }

    @ViewBuilder private var noticeBanner: some View {
        if let notice = monitor.notice {
            Label(notice, systemImage: "info.circle")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassCapsule()
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// A small pulsing dot that tells the user the numbers are live.
private struct MemoryLiveIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
                .opacity(pulse ? 0.35 : 1)
            Text("Updating every second")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared styling

enum MemoryStyle {
    static func color(_ severity: MemoryVerdict.Severity) -> Color {
        switch severity {
        case .ok: .green
        case .warning: .yellow
        case .critical: .red
        case .unknown: .secondary
        }
    }

    static func color(_ level: MemoryPressureLevel?) -> Color {
        switch level {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        case nil: .secondary
        }
    }

    static func symbol(_ severity: MemoryVerdict.Severity) -> String {
        switch severity {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }
}
