import SwiftUI

/// The one big element on the screen. Its content follows the store's phase: scan → review → clean → result.
struct CleanupHero: View {
    @Bindable var store: CleanupStore
    let onClean: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch store.phase {
            case .idle: idle
            case .scanning: scanning
            case .ready: ready
            case .cleaning: cleaning
            case .finished: CleanupOutcomeView(store: store)
            }
        }
        .padding(.vertical, 26)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .glassPanel(cornerRadius: 24)
        .hairline(cornerRadius: 24)
        .animation(.adaptive(reduceMotion), value: store.phase)
    }

    // MARK: Idle

    private var idle: some View {
        VStack(spacing: 16) {
            CleanupOrb(progress: nil) {
                Image(systemName: "sparkles")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
            }
            VStack(spacing: 5) {
                Text("Find space you can safely free")
                    .font(.system(size: 20, weight: .semibold))
                Text("Checks caches, logs, developer junk, idle project builds, installers and the Trash. Nothing is removed until you review it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: store.scan) {
                Label("Scan", systemImage: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(minWidth: 132)
            }
            .buttonStyle(SpeedTestButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
            .help("Scan this Mac for space you can free")
        }
        .transition(.opacity)
    }

    // MARK: Scanning

    private var scanning: some View {
        let total = CleanupCategoryID.allCases.count
        let done = store.finishedCategoryCount
        let found = store.reclaimableBytes
        let parts = CleanupFormat.split(found)
        return VStack(spacing: 16) {
            CleanupOrb(progress: Double(done) / Double(total)) {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(parts.number)
                            .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText(value: Double(found)))
                        Text(parts.unit)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Text("found so far")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .animation(.adaptive(reduceMotion, .snappy), value: found)
            }
            VStack(spacing: 4) {
                Text("Scanning…")
                    .font(.system(size: 17, weight: .semibold))
                Text("\(done) of \(total) categories checked")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(done)))
            }
            Button(action: store.cancelScan) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(minWidth: 132)
            }
            .buttonStyle(SpeedTestButtonStyle(prominent: false))
            .keyboardShortcut(.cancelAction)
            .help("Stop scanning")
        }
        .accessibilityElement(children: .contain)
        .transition(.opacity)
    }

    // MARK: Ready

    @ViewBuilder private var ready: some View {
        if store.reclaimableBytes == 0 {
            VStack(spacing: 12) {
                CleanupOrb(progress: 1, tint: .green) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.green)
                }
                Text("Nothing to clean")
                    .font(.system(size: 20, weight: .semibold))
                Text("Every place Cleanup checks is already tidy.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                rescanButton
            }
            .transition(.opacity)
        } else {
            readyWithResults
        }
    }

    private var readyWithResults: some View {
        let selected = store.selectedBytes
        let parts = CleanupFormat.split(selected)
        let found = store.reclaimableBytes
        let categories = store.orderedResults.filter { !$0.items.isEmpty }.count
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ready to clean")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(parts.number)
                            .font(.system(size: 54, weight: .semibold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText(value: Double(selected)))
                        Text(parts.unit)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .animation(.adaptive(reduceMotion, .snappy), value: selected)
                    Text("\(CleanupFormat.items(store.selectedCount)) selected · \(CleanupFormat.bytes(found)) found in \(categories) categor\(categories == 1 ? "y" : "ies")")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 10) {
                    Button(action: onClean) {
                        Label(selected > 0 ? "Clean \(CleanupFormat.bytes(selected))" : "Clean",
                              systemImage: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(minWidth: 150)
                    }
                    .buttonStyle(SpeedTestButtonStyle(prominent: selected > 0))
                    .disabled(store.selectedCount == 0)
                    .keyboardShortcut(.defaultAction)
                    .help(selected > 0 ? "Review what will be cleaned" : "Tick something to clean")
                    rescanButton
                }
            }
            CleanupCompositionBar(segments: store.orderedResults.map {
                .init(id: $0.category, total: $0.totalBytes, selected: store.selectedBytes(in: $0.category))
            })
            if let scanned = store.scanStarted {
                Text("Scanned \(CleanupFormat.relative(scanned)). Sizes are space on disk, measured during the scan.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .transition(.opacity)
    }

    private var rescanButton: some View {
        Button(action: store.scan) {
            Label("Scan again", systemImage: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.glass)
        .controlSize(.regular)
        .help("Scan again from scratch")
    }

    // MARK: Cleaning

    private var cleaning: some View {
        let total = max(1, store.cleanTotal)
        let done = min(store.cleanedCount, total)
        return VStack(spacing: 16) {
            CleanupOrb(progress: Double(done) / Double(total)) {
                VStack(spacing: 0) {
                    Text("\(done)")
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText(value: Double(done)))
                    Text("of \(total)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 4) {
                Text("Cleaning…")
                    .font(.system(size: 17, weight: .semibold))
                Text(store.cleaningName.isEmpty ? "Measuring free space" : store.cleaningName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 360)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cleaning, \(done) of \(total) items")
        .transition(.opacity)
    }
}

/// Large circular stage with an optional progress ring.
struct CleanupOrb<Content: View>: View {
    let progress: Double?
    var tint: Color = .accentColor
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let size: CGFloat = 156
    private let lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.16), tint.opacity(0.03)], center: .center,
                                     startRadius: 4, endRadius: size / 2))
            Circle().strokeBorder(.primary.opacity(0.07), lineWidth: lineWidth)
            if let progress {
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: max(0.001, min(1, progress)))
                    .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.adaptive(reduceMotion, .spring(response: 0.5, dampingFraction: 0.85)), value: progress)
            }
            content
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .combine)
        .accessibilityValue(progress.map { Format.percent($0) } ?? "")
    }
}
