import AppKit
import SwiftUI

/// The popup after «Download»: live progress, then Open / Show in Finder, or Retry.
struct CatchProgressView: View {
    let item: DownloadItem?
    let manager: DownloadManager
    let settings: AppSettings
    let close: () -> Void

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: Tokens.space3) {
                ProgressCapsule(progress: item.status == .completed ? 1 : (item.status == .running ? item.progress : nil),
                                tint: Color.status(item.status), height: 7)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusLine(item))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(item.status == .failed ? .red : .secondary)
                            .lineLimit(2)
                        if item.engine == .direct, item.status == .running {
                            Label("\(connections) connections", systemImage: "point.3.filled.connected.trianglepath.dotted")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .transition(.opacity)
                        }
                    }
                    Spacer()
                    if item.status == .running {
                        Sparkline(samples: item.speedSamples)
                            .frame(width: 80, height: 20)
                    }
                }
                HStack(spacing: 10) {
                    Spacer()
                    buttons(item)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    @ViewBuilder
    private func buttons(_ item: DownloadItem) -> some View {
        switch item.status {
        case .completed:
            Button("Done", action: close)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(CatchSecondaryButtonStyle())
            Button("Show in Finder") { if let url = item.fileURL { FinderReveal.reveal([url]) } }
                .buttonStyle(CatchSecondaryButtonStyle())
            // No Return shortcut: opening a file must be a deliberate click.
            Button("Open") { if let url = item.fileURL { NSWorkspace.shared.open(url) }; close() }
                .buttonStyle(CatchPrimaryButtonStyle())
        case .failed, .stopped:
            Button("Close", action: close).buttonStyle(CatchSecondaryButtonStyle())
            Button("Retry") { manager.retry(item) }
                .buttonStyle(CatchPrimaryButtonStyle())
        default:
            Button(item.status == .paused ? "Resume" : "Pause") {
                item.status == .paused ? manager.resume(item) : manager.pause(item)
            }
            .buttonStyle(CatchSecondaryButtonStyle())
            .disabled(!(item.canPause || item.canResume))
            Button("Cancel") { manager.stop(item); close() }
                .buttonStyle(CatchSecondaryButtonStyle())
            Button("Hide", action: close)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(CatchPrimaryButtonStyle())
                .help("Keeps downloading in Root")
        }
    }

    private var connections: Int { CatchDetails.connections(prefs: settings.prefs, resumable: nil) }

    private func statusLine(_ item: DownloadItem) -> String {
        switch item.status {
        case .running:
            let done = Format.bytes(item.downloadedBytes)
            let total = item.totalBytes.map { " of \(Format.bytes($0))" } ?? ""
            let pct = item.progress.map { " · \(Format.percent($0))" } ?? ""
            return "\(done)\(total)\(pct) · \(Format.speed(item.speed)) · \(Format.eta(item.eta))"
        case .completed: return "Downloaded \(Format.bytes(item.totalBytes))"
        case .failed: return item.errorMessage ?? "Download failed"
        default: return item.statusText
        }
    }
}
