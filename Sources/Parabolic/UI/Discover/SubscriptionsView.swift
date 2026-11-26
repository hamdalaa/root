import SwiftUI

/// Followed channels and playlists. New uploads download automatically with each one's preset.
struct SubscriptionsView: View {
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(AppSettings.self) private var settings
    @Environment(ToolStore.self) private var tools
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pendingRemoval: Subscription?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.space5) {
                header
                if subscriptions.subscriptions.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: Tokens.space2) {
                        ForEach(subscriptions.subscriptions) { sub in
                            SubscriptionRow(subscription: sub, onRemove: { pendingRemoval = sub })
                        }
                    }
                }
            }
            .padding(.horizontal, Tokens.space6)
            .padding(.top, Tokens.space5)
            .padding(.bottom, Tokens.space6)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .animation(reduceMotion ? nil : Tokens.motion, value: subscriptions.subscriptions.map(\.id))
        .confirmationDialog("Remove “\(pendingRemoval?.title ?? "")”?",
                            isPresented: Binding { pendingRemoval != nil } set: { if !$0 { pendingRemoval = nil } },
                            presenting: pendingRemoval) { sub in
            Button("Remove", role: .destructive) { subscriptions.remove(sub.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("New uploads will stop downloading. Files you already have are kept.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: Tokens.space3) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Subscriptions")
                    .font(.system(size: 26, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                infoLine
            }
            Spacer(minLength: Tokens.space3)
            GlassEffectContainer(spacing: Tokens.space2) {
                HStack(spacing: Tokens.space2) {
                    if !subscriptions.subscriptions.isEmpty {
                        Button(action: subscriptions.checkAll) {
                            HStack(spacing: 6) {
                                if subscriptions.isChecking {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text("Check All")
                            }
                        }
                        .buttonStyle(.glass)
                        .disabled(!tools.isReady || subscriptions.isChecking)
                        .help(tools.isReady ? "Look for new uploads now" : "Install yt-dlp in Settings first")
                    }
                    Button {
                        appState.isAddSubscriptionPresented = true
                    } label: {
                        Image(systemName: "plus").frame(height: 16)
                    }
                    .buttonStyle(.glass)
                    .help("Follow a channel or playlist")
                    .accessibilityLabel("Add Subscription")
                }
            }
            .controlSize(.large)
        }
    }

    private var infoLine: some View {
        @Bindable var settings = settings
        let isOn = settings.prefs.subscriptionsEnabled
        return HStack(spacing: Tokens.space2) {
            Image(systemName: isOn ? "clock.arrow.circlepath" : "pause.circle")
                .foregroundStyle(isOn ? Color.parabolicAccent : .secondary)
            Text(isOn ? "Checks \(DiscoverFormat.interval(minutes: settings.prefs.subscriptionCheckMinutes)) while Root is open"
                      : "Automatic checks are off")
                .foregroundStyle(.secondary)
            Toggle("Automatic checks", isOn: $settings.prefs.subscriptionsEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel("Automatic checks")
        }
        .font(.system(size: 12))
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: Tokens.space5) {
            HStack(spacing: -10) {
                ForEach([Platform.youtube, .soundcloud, .twitch, .bandcamp], id: \.self) { platform in
                    PlatformBadge(platform: platform, size: 44)
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                }
            }
            .accessibilityHidden(true)
            VStack(spacing: Tokens.space2) {
                Text("Follow channels you love")
                    .font(.system(size: 22, weight: .semibold))
                Text("Add a YouTube channel, playlist or any profile yt-dlp can list. Root checks for new uploads and downloads them with the preset you choose, or just counts them for you to pick from.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
            Button {
                appState.isAddSubscriptionPresented = true
            } label: {
                Label("Add Subscription", systemImage: "plus")
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, Tokens.space6 + Tokens.space4)
        .padding(.horizontal, Tokens.space6)
        .frame(maxWidth: .infinity)
        .discoverPanel(cornerRadius: Tokens.radiusWindowCard)
    }
}
