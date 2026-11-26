import AppKit
import Observation
import SwiftUI

/// Mounted volumes, re-read on demand. Shared so the explorer and Large Files agree on what exists.
@MainActor
@Observable
final class StorageVolumesStore {
    static let shared = StorageVolumesStore()

    private(set) var volumes: [StorageVolume] = []
    private(set) var isLoaded = false

    func refresh() async {
        let read = await Task.detached(priority: .utility) { StorageVolumeReader.read() }.value
        if read != volumes { volumes = read }
        if !isLoaded { isLoaded = true }
    }

    /// The volume a path lives on (longest mount-point match), falling back to the startup disk.
    func volume(containing url: URL) -> StorageVolume? {
        var path = url.path
        if path.hasPrefix("/System/Volumes/Data/") { path = String(path.dropFirst("/System/Volumes/Data".count)) }
        let matches = volumes.filter { !$0.isRoot && (path == $0.url.path || path.hasPrefix($0.url.path + "/")) }
        return matches.max { $0.url.path.count < $1.url.path.count } ?? volumes.first(where: \.isRoot)
    }
}

extension StoragePressure {
    var tint: Color {
        switch self {
        case .ok: .accentColor
        case .warning: .yellow
        case .critical: .red
        }
    }
}

/// The volumes row: the startup disk as the wide hero card, other disks beside it.
struct StorageVolumeStrip: View {
    let volumes: [StorageVolume]
    let isLoaded: Bool
    let exploring: StorageVolume?
    let onExplore: (StorageVolume) -> Void

    var body: some View {
        Group {
            if volumes.isEmpty {
                placeholder
            } else {
                ViewThatFits(in: .horizontal) {
                    // Startup disk as the hero; every other disk stacks beside it, so nothing is clipped.
                    HStack(alignment: .top, spacing: 12) {
                        heroCard.frame(minWidth: 400, maxWidth: .infinity)
                        if !others.isEmpty {
                            VStack(spacing: 10) { otherCards }
                                .frame(minWidth: 280, maxWidth: 380)
                        }
                    }
                    VStack(spacing: 10) {
                        heroCard
                        otherCards
                    }
                }
            }
        }
    }

    private var others: [StorageVolume] { Array(volumes.dropFirst()) }

    @ViewBuilder private var heroCard: some View {
        if let hero = volumes.first {
            StorageVolumeCard(volume: hero, isHero: true, isExploring: hero.id == exploring?.id) { onExplore(hero) }
        }
    }

    @ViewBuilder private var otherCards: some View {
        ForEach(others) { volume in
            StorageVolumeCard(volume: volume, isHero: false, isExploring: volume.id == exploring?.id) { onExplore(volume) }
        }
    }

    private var placeholder: some View {
        HStack(spacing: 10) {
            if isLoaded {
                Image(systemName: "externaldrive.badge.questionmark").foregroundStyle(.secondary)
                Text("No disks reported their capacity.").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
                Text("Reading disks…").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, minHeight: 96)
        .glassPanel(cornerRadius: 18)
        .hairline(cornerRadius: 18)
    }
}

/// One disk: icon, name, how much is available, and a used / purgeable / free bar. Clicking explores it.
struct StorageVolumeCard: View {
    let volume: StorageVolume
    let isHero: Bool
    let isExploring: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: isHero ? 12 : 9) {
                titleRow
                figures
                StorageCapacityBar(volume: volume, height: isHero ? 12 : 7)
                if isHero { legend }
            }
            .padding(isHero ? 16 : 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(StorageCardButtonStyle(isHovered: isHovered, isSelected: isExploring))
        .onHover { hovering in if hovering != isHovered { isHovered = hovering } }
        .help("Explore \(volume.name)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(volume.name)
        .accessibilityValue("\(Format.bytes(volume.available)) available of \(Format.bytes(volume.total)). \(volume.pressure.label).")
        .accessibilityHint("Shows what’s using space on this disk")
        .accessibilityAddTraits(isExploring ? [.isButton, .isSelected] : .isButton)
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            StorageIcons.image(for: volume.url)
                .resizable()
                .frame(width: isHero ? 34 : 26, height: isHero ? 34 : 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(volume.name)
                    .font(.system(size: isHero ? 14 : 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if volume.pressure != .ok || isHero {
                Text(volume.pressure.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(volume.pressure == .ok ? Color.green : volume.pressure.tint)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background((volume.pressure == .ok ? Color.green : volume.pressure.tint).opacity(0.13), in: .capsule)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if volume.isRoot { parts.append("Startup disk") }
        else if volume.isInternal { parts.append("Internal") }
        else if !volume.isLocal { parts.append("Network") }
        else { parts.append("External") }
        if let format = volume.format { parts.append(format) }
        return parts.joined(separator: " · ")
    }

    private var figures: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(Format.bytes(volume.available))
                .font(.system(size: isHero ? 28 : 19, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(volume.pressure == .critical ? Color.red : Color.primary)
                .contentTransition(.numericText())
            Text(isHero ? "available" : "free")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text("of \(Format.bytes(volume.total))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem("Used", volume.used, fill: AnyShapeStyle(volume.pressure.tint))
            if volume.purgeable > 0 {
                legendItem("Purgeable", volume.purgeable, fill: AnyShapeStyle(volume.pressure.tint.opacity(0.35)))
                    .help("Space macOS frees on its own when needed: caches, local snapshots and optimised iCloud files.")
            }
            legendItem("Free", volume.free, fill: AnyShapeStyle(.primary.opacity(0.12)))
            Spacer(minLength: 0)
        }
    }

    private func legendItem(_ title: String, _ bytes: Int64, fill: AnyShapeStyle) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2.5).fill(fill).frame(width: 9, height: 9)
            Text(title).foregroundStyle(.secondary)
            Text(Format.bytes(bytes)).monospacedDigit()
        }
        .font(.system(size: 11))
    }
}

/// Used, purgeable and free as one capsule.
struct StorageCapacityBar: View {
    let volume: StorageVolume
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let total = max(Double(volume.total), 1)
            let used = width * Double(volume.used) / total
            let purgeable = width * Double(volume.purgeable) / total
            HStack(spacing: 0) {
                Rectangle()
                    .fill(LinearGradient(colors: [volume.pressure.tint.opacity(0.85), volume.pressure.tint],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, used))
                Rectangle()
                    .fill(volume.pressure.tint.opacity(0.35))
                    .frame(width: max(0, purgeable))
                Spacer(minLength: 0)
            }
            .frame(width: width, height: height)
            .background(.primary.opacity(0.10))
            .clipShape(.capsule)
            .animation(Tokens.quick, value: volume.used)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Glass card that lifts on hover and dips when pressed; accent hairline when it's the disk being explored.
struct StorageCardButtonStyle: ButtonStyle {
    var isHovered: Bool
    var isSelected: Bool
    var cornerRadius: CGFloat = 18

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.primary.opacity(configuration.isPressed ? 0.07 : (isHovered ? 0.04 : 0)))
            }
            .glassPanel(cornerRadius: cornerRadius, tint: isSelected ? Color.accentColor.opacity(0.08) : nil)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : .primary.opacity(0.08),
                                  lineWidth: isSelected ? 1.2 : 1)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
            .animation(Tokens.quick, value: isHovered)
    }
}
