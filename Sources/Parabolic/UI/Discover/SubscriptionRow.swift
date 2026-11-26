import SwiftUI

/// One followed channel: identity, last check, new-upload badge and its controls.
struct SubscriptionRow: View {
    var subscription: Subscription
    var onRemove: () -> Void

    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(AppSettings.self) private var settings
    @Environment(ToolStore.self) private var tools
    @Environment(AppState.self) private var appState
    @State private var hovering = false

    private var sub: Subscription { subscription }
    private var isChecking: Bool { subscriptions.checkingIDs.contains(sub.id) }
    private var presets: [DownloadPreset] { settings.prefs.allPresets }
    private var presetName: String {
        if let id = sub.presetID, let preset = presets.first(where: { $0.id == id }) { return preset.name }
        return "Platform default"
    }

    var body: some View {
        HStack(spacing: Tokens.space3) {
            avatar
            identity
                .opacity(sub.isEnabled ? 1 : 0.55)
            Spacer(minLength: Tokens.space3)
            if sub.newCount > 0 { newBadge }
            presetMenu
            Toggle(isOn: binding(\.autoDownload)) {
                Text("Auto-download").font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .help("Download new uploads automatically. When off, they're counted instead.")
            checkButton
            Toggle("Enabled", isOn: binding(\.isEnabled))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(sub.isEnabled ? "Following. Turn off to pause checks." : "Paused")
                .accessibilityLabel("Follow \(sub.title)")
        }
        .padding(.vertical, Tokens.space3)
        .padding(.horizontal, Tokens.space4)
        .background {
            RoundedRectangle(cornerRadius: Tokens.radiusRow)
                .fill(.primary.opacity(hovering ? 0.03 : 0))
        }
        .discoverPanel()
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(sub.title)
    }

    // MARK: Parts

    private var avatar: some View {
        AsyncImage(url: sub.thumbnailURL.flatMap(URL.init(string:))) { phase in
            if case .success(let image) = phase {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Circle().fill(.primary.opacity(0.06))
                    Image(systemName: "person.crop.circle").font(.system(size: 20, weight: .light)).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(.circle)
        .overlay(Circle().strokeBorder(.primary.opacity(0.08)))
        .overlay(alignment: .bottomTrailing) {
            PlatformBadge(platform: sub.platform, size: 20)
                .offset(x: 4, y: 4)
        }
        .padding(.trailing, 4)
        .accessibilityHidden(true)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sub.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if let uploader = sub.uploader, uploader != sub.title {
                Text(uploader).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            status
        }
    }

    @ViewBuilder
    private var status: some View {
        if isChecking {
            Text("Checking for new uploads…").font(.system(size: 11)).foregroundStyle(.secondary)
        } else if let error = sub.lastError {
            Label(error, systemImage: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(error)
        } else if let checked = sub.lastChecked {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text("Checked \(DiscoverFormat.ago(checked, now: context.date))\(sub.isEnabled ? "" : " · Paused")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        } else {
            Text("Not checked yet").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private var newBadge: some View {
        Button {
            subscriptions.clearNewBadge(sub.id)
            appState.presentAdd(url: sub.url)
        } label: {
            Text("\(sub.newCount) new")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.parabolicAccent, in: .capsule)
        }
        .buttonStyle(.plain)
        .help("Pick which new uploads to download")
        .accessibilityLabel("\(sub.newCount) new uploads")
        .accessibilityHint("Opens the channel to pick videos")
    }

    private var presetMenu: some View {
        Menu {
            Picker("Preset", selection: binding(\.presetID)) {
                Text("Platform default (\(settings.prefs.preset(for: sub.platform).name))").tag(UUID?.none)
                Divider()
                ForEach(presets) { preset in
                    Label(preset.name, systemImage: preset.symbol).tag(Optional(preset.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(presetName).font(.system(size: 12))
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .controlSize(.small)
        .fixedSize()
        .help("Preset for new uploads")
        .accessibilityLabel("Preset, \(presetName)")
    }

    private var checkButton: some View {
        Button {
            Task { await subscriptions.check(sub.id) }
        } label: {
            ZStack {
                ProgressView().controlSize(.small).opacity(isChecking ? 1 : 0)
                Image(systemName: "arrow.clockwise").opacity(isChecking ? 0 : 1)
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(HoverButtonStyle(cornerRadius: 8, padding: 4))
        .disabled(isChecking || !tools.isReady)
        .help("Check now")
        .accessibilityLabel(isChecking ? "Checking" : "Check now")
    }

    @ViewBuilder
    private var menu: some View {
        Button("Check Now", systemImage: "arrow.clockwise") { Task { await subscriptions.check(sub.id) } }
            .disabled(isChecking || !tools.isReady)
        Button("Open in Browser", systemImage: "safari") { DiscoverActions.open(sub.url) }
        Button("Copy Link", systemImage: "link") { DiscoverActions.copy(sub.url) }
        Divider()
        Button("Remove…", systemImage: "trash", role: .destructive, action: onRemove)
    }

    // MARK: Editing

    private func binding<Value>(_ keyPath: WritableKeyPath<Subscription, Value>) -> Binding<Value> {
        Binding {
            subscriptions.subscriptions.first { $0.id == sub.id }?[keyPath: keyPath] ?? sub[keyPath: keyPath]
        } set: { value in
            guard var current = subscriptions.subscriptions.first(where: { $0.id == sub.id }) else { return }
            current[keyPath: keyPath] = value
            subscriptions.update(current)
        }
    }
}
