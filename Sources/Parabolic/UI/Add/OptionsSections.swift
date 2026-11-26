import SwiftUI

/// "More options" card: trim to a section plus the extra files and live toggles. Collapsed by default.
struct TrimAndExtrasSection: View {
    @Bindable var model: AddDownloadModel
    var info: MediaInfo

    @State private var trimExpanded = false
    @State private var extrasExpanded = false

    private var trimSummary: String {
        guard model.trimEnabled else { return "Whole video" }
        if case .success(let frame?) = model.trimResult {
            return "\(Format.duration(frame.start) ?? "0:00") to \(Format.duration(frame.end) ?? "")"
        }
        return "Check the times"
    }

    private var extrasSummary: String {
        var parts: [String] = []
        if model.options.splitChapters { parts.append("Split chapters") }
        if model.options.exportDescription { parts.append("Description") }
        if model.options.saveThumbnailFile { parts.append("Thumbnail") }
        if model.options.liveFromStart { parts.append("From start") }
        return parts.isEmpty ? "None" : parts.joined(separator: ", ")
    }

    var body: some View {
        GroupCard(title: "More options") {
            if !info.meta.isLive {
                ExpandableRow(title: "Trim", summary: trimSummary, symbol: "scissors",
                              isExpanded: $trimExpanded, showsDivider: true) {
                    trimRows
                }
            }
            ExpandableRow(title: "Extras", summary: extrasSummary, symbol: "plus.square.on.square",
                          isExpanded: $extrasExpanded) {
                extrasRows
            }
        }
    }

    @ViewBuilder
    private var trimRows: some View {
        GroupRow(title: "Download only part", symbol: "timeline.selection") {
            Toggle("Download only part", isOn: $model.trimEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        if model.trimEnabled {
            GroupRow(title: "From", subtitle: "Like 1:23, 1:02:03 or seconds.", symbol: "arrow.right.to.line") {
                TimeField(label: "Start time", text: $model.trimStartText)
            }
            GroupRow(title: "To", subtitle: info.meta.duration.flatMap { Format.duration($0) }.map { "Ends at \($0)." },
                     symbol: "arrow.left.to.line", showsDivider: model.trimError != nil) {
                TimeField(label: "End time", text: $model.trimEndText)
            }
            if let error = model.trimError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 44)
                    .padding(.vertical, 6)
                    .accessibilityLabel("Trim error: \(error)")
            }
        }
    }

    @ViewBuilder
    private var extrasRows: some View {
        if info.chapterCount > 0 {
            toggleRow("Split chapters", subtitle: "One file per chapter (\(info.chapterCount)).", symbol: "list.number",
                      isOn: $model.options.splitChapters)
        }
        toggleRow("Save description", subtitle: "Writes a .description text file.", symbol: "text.alignleft",
                  isOn: $model.options.exportDescription)
        toggleRow("Save thumbnail image", subtitle: "Keeps the artwork as a JPEG next to the file.", symbol: "photo",
                  isOn: $model.options.saveThumbnailFile, divider: info.meta.isLive)
        if info.meta.isLive {
            toggleRow("Record live from start", subtitle: "Starts at the beginning of the stream, not now.",
                      symbol: "backward.end", isOn: $model.options.liveFromStart, divider: false)
        }
    }

    private func toggleRow(_ title: String, subtitle: String, symbol: String, isOn: Binding<Bool>, divider: Bool = true) -> some View {
        GroupRow(title: title, subtitle: subtitle, symbol: symbol, showsDivider: divider) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

/// Small monospaced time entry.
struct TimeField: View {
    var label: String
    @Binding var text: String

    var body: some View {
        TextField(label, text: $text, prompt: Text("0:00"))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13).monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: 96)
            .accessibilityLabel(label)
    }
}

/// Where and when the file lands: name, folder, login and scheduling.
struct SaveSection: View {
    @Bindable var model: AddDownloadModel
    var credentials: [Credential]

    var body: some View {
        GroupCard(title: "Save", footer: model.options.filename.isEmpty ? "An empty name uses the filename template from Settings." : nil) {
            GroupRow(title: "Name", symbol: "character.cursor.ibeam") {
                TextField("Filename", text: $model.options.filename, prompt: Text("Filename template"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .accessibilityLabel("Filename")
            }
            FolderRow(path: $model.options.saveFolder)
            if !credentials.isEmpty {
                CredentialPicker(credentials: credentials, selection: $model.credentialID)
            }
            ScheduleRows(startLater: $model.startLater, date: $model.scheduledAt)
        }
    }
}

/// "Start later" switch with an inline date picker.
struct ScheduleRows: View {
    @Binding var startLater: Bool
    @Binding var date: Date

    var body: some View {
        GroupRow(title: "Start later", subtitle: startLater ? nil : "Queues now and starts at a time you pick.",
                 symbol: "calendar.badge.clock", showsDivider: startLater) {
            Toggle("Start later", isOn: $startLater)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        if startLater {
            GroupRow(title: "Starts", symbol: "clock", showsDivider: false) {
                DatePicker("Start time", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .accessibilityLabel("Start date and time")
            }
        }
    }
}
