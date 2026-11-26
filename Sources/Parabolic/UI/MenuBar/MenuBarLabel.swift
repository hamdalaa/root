import SwiftUI

/// Status item: outline arrow when idle, filled arrow plus overall percent while downloading.
/// Kept to a lone Image or a single Text (with an inline symbol): the shapes NSStatusItem renders natively.
struct MenuBarLabel: View {
    @Environment(DownloadManager.self) private var manager

    var body: some View {
        if manager.activeItems.isEmpty {
            Image(systemName: "arrow.down.circle")
        } else if let progress = manager.overallProgress, progress > 0 {
            Text("\(Image(systemName: "arrow.down.circle.fill")) \(Format.percent(progress))")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        } else {
            Image(systemName: "arrow.down.circle.fill")
        }
    }
}
