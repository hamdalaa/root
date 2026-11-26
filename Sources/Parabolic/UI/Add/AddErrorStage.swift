import SwiftUI

/// Stage 3: yt-dlp couldn't read the link. Explains why and offers the fix that fits.
struct AddErrorStage: View {
    @Bindable var model: AddDownloadModel
    var message: String
    var onRetry: () -> Void
    var onCancel: () -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(ToolStore.self) private var tools

    private var needsLogin: Bool { Self.mentionsLogin(message) }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space5) {
            AddSheetHeader(title: tools.isReady ? "Couldn't open this link" : "yt-dlp isn't installed",
                           subtitle: model.host,
                           symbol: tools.isReady ? "exclamationmark.triangle" : "shippingbox",
                           tint: tools.isReady ? .red : .parabolicAccent)

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Tokens.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.04), in: .rect(cornerRadius: Tokens.radiusRow))
                .accessibilityLabel("Error: \(message)")

            if !tools.isReady { installCard }
            if needsLogin { loginCard }
        }
        .padding(Tokens.space5)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SheetBottomBar {
                Button {
                    model.backToInput()
                } label: {
                    Label("Edit link", systemImage: "chevron.left")
                }
                .buttonStyle(.glass)
                .accessibilityHint("Goes back to the link field")
            } trailing: {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button(action: onRetry) {
                    Label(model.credentialID == nil ? "Retry" : "Retry with login", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!tools.isReady)
            }
            .controlSize(.large)
        }
    }

    private var installCard: some View {
        GroupCard(title: "Get yt-dlp", footer: tools.lastMessage) {
            GroupRow(title: "Install the official build",
                     subtitle: "Downloads the official standalone macOS build from GitHub.",
                     symbol: "arrow.down.app", showsDivider: false) {
                if tools.isUpdating {
                    ProgressView().controlSize(.small).accessibilityLabel("Installing yt-dlp")
                } else {
                    Button("Install yt-dlp") {
                        Task {
                            await tools.installManagedYtdlp(nightly: false)
                            if tools.isReady { onRetry() }
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityHint("Downloads yt-dlp, then tries the link again")
                }
            }
        }
    }

    private var loginCard: some View {
        GroupCard(title: "This might need a login",
                  footer: "You can also let yt-dlp use your browser's cookies: Settings → Network → Cookies from browser.") {
            if settings.prefs.credentials.isEmpty {
                GroupRow(title: "No saved logins yet", subtitle: "Add one in Settings, or use browser cookies.",
                         symbol: "person.badge.key", showsDivider: false) {
                    SettingsLink { Text("Open Settings…") }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Open Settings")
                }
            } else {
                CredentialPicker(credentials: settings.prefs.credentials, selection: $model.credentialID,
                                 title: "Use a saved login", showsDivider: true)
                GroupRow(title: "Browser cookies", subtitle: settings.prefs.cookieBrowser == .none
                         ? "Not set" : "Using \(settings.prefs.cookieBrowser.label)",
                         symbol: "safari", showsDivider: false) {
                    SettingsLink { Text("Settings…") }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .accessibilityLabel("Open Settings to choose a cookie browser")
                }
            }
        }
    }

    /// True when the failure reads like a sign-in, private, members-only or age gate.
    static func mentionsLogin(_ message: String) -> Bool {
        let lower = message.lowercased()
        if ["sign in", "sign-in", "log in", "logged in", "log-in"].contains(where: lower.contains) { return true }
        let words = Set(lower.components(separatedBy: CharacterSet.alphanumerics.inverted))
        let keys: Set<String> = ["login", "private", "members", "member", "age", "cookies", "cookie", "authentication"]
        return !words.isDisjoint(with: keys) || lower.contains("age-restricted") || lower.contains("age restricted")
    }
}
