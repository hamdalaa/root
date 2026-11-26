import AppKit
import SwiftUI

/// «More details»: the facts behind the download in one grouped card, collapsed by default.
struct CatchDetailsSection: View {
    let model: CatchModel
    let settings: AppSettings
    let lastSpeedTest: SpeedTest.Result?
    let eta: Int?
    let freeSpace: Int64?
    let space: CatchDetails.Space
    @Binding var isExpanded: Bool

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space2) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("More details")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(spacing: 0) {
                    CatchDetailRow(label: "Page", value: pageValue, detail: pageDetail, symbol: "safari")
                    CatchDetailRow(label: "Link", value: model.source.url, symbol: "link", monospaced: true) {
                        Button(action: copyLink) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.borderless)
                        .help("Copy the direct link")
                        .accessibilityLabel(copied ? "Copied" : "Copy link")
                    }
                    CatchDetailRow(label: "Type", value: typeValue, symbol: "doc.text")
                    CatchDetailRow(label: "Resumable", value: resumableValue, symbol: "arrow.clockwise")
                    CatchDetailRow(label: "Connections", value: connectionsValue, symbol: "point.3.filled.connected.trianglepath.dotted")
                    CatchDetailRow(label: "Time", value: timeValue, detail: timeDetail, symbol: "clock")
                    CatchDetailRow(label: "Free space", value: spaceValue, symbol: "internaldrive", tint: spaceTint)
                    CatchDetailRow(label: "Category", value: model.category.rawValue, symbol: model.category.symbol, showsDivider: false)
                }
                .padding(.vertical, 2)
                .glassPanel(cornerRadius: Tokens.radiusRow)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Values (honest: "Unknown" rather than a guess)

    private var pageValue: String {
        model.pageTitle ?? model.pageHost ?? (model.isMediaPage ? model.filename : "Not sent by the browser")
    }

    private var pageDetail: String? {
        model.pageTitle == nil ? nil : model.pageHost
    }

    private var typeValue: String {
        if model.isMediaPage { return model.preset.map { "\($0.fileType.label) from the page" } ?? "Media page" }
        if model.isTorrent { return "BitTorrent" }
        return model.contentType ?? (model.isProbing ? "Checking…" : "Unknown")
    }

    private var resumableValue: String {
        if model.isTorrent { return "Yes (torrent)" }
        if model.isMediaPage { return "Handled by yt-dlp" }
        switch model.resumable {
        case true?: return "Yes"
        case false?: return "No, the server can’t resume it"
        case nil: return model.isProbing ? "Checking…" : "Unknown"
        }
    }

    private var connectionsValue: String {
        if model.isTorrent { return "Peers, as many as the swarm has" }
        if model.isMediaPage { return "Handled by yt-dlp" }
        let count = CatchDetails.connections(prefs: settings.prefs, resumable: model.resumable)
        if model.resumable == false { return "1, the server can’t split the file" }
        return settings.prefs.turboMode ? "\(count) (Turbo)" : "\(count)"
    }

    private var timeValue: String {
        guard model.size != nil else { return model.isMediaPage ? "Known once it starts" : "Unknown size" }
        guard let eta, let mbps = lastSpeedTest?.downloadMbps else { return "Run a speed test in Root for an estimate" }
        return "\(CatchDetails.etaText(eta)) at \(Int(mbps.rounded())) Mbps"
    }

    private var timeDetail: String? {
        guard eta != nil, let date = lastSpeedTest?.date else { return nil }
        return "From your speed test, \(date.formatted(.relative(presentation: .named)))"
    }

    private var spaceValue: String {
        guard let freeSpace else { return "Checking…" }
        switch space {
        case .notEnough: return "\(Format.bytes(freeSpace)), not enough for this file"
        case .low: return "\(Format.bytes(freeSpace)), running low"
        case .plenty, .unknown: return Format.bytes(freeSpace)
        }
    }

    private var spaceTint: Color? {
        switch space {
        case .notEnough: .red
        case .low: .yellow
        case .plenty, .unknown: nil
        }
    }

    private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.source.url, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// One fact: label on the left, value on the right (truncated in the middle), optional trailing control.
struct CatchDetailRow<Trailing: View>: View {
    let label: String
    let value: String
    var detail: String?
    let symbol: String
    var monospaced = false
    var tint: Color?
    var showsDivider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.parabolicAccent)
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .leading)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(value)
                        .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 12, weight: .medium))
                        .foregroundStyle(tint ?? .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .accessibilityElement(children: .combine)
            if showsDivider {
                Divider().padding(.leading, 42).padding(.trailing, 14)
            }
        }
    }
}

extension CatchDetailRow where Trailing == EmptyView {
    init(label: String, value: String, detail: String? = nil, symbol: String, monospaced: Bool = false,
         tint: Color? = nil, showsDivider: Bool = true) {
        self.init(label: label, value: value, detail: detail, symbol: symbol, monospaced: monospaced, tint: tint,
                  showsDivider: showsDivider) { EmptyView() }
    }
}
