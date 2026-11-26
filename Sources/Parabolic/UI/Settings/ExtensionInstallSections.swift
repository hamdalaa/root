import AppKit
import SwiftUI

/// Step-by-step install guidance for the Chromium and Firefox extensions shipped inside the app.
struct ExtensionInstallSections: View {
    @State private var copied = false

    private static let chromiumPage = "chrome://extensions"
    private static let firefoxPage = "about:debugging#/runtime/this-firefox"
    private static let firefoxPackage = "parabolic-firefox.xpi"

    /// The bundled copy, only to know whether this build ships the extension at all.
    private var folder: URL? { BrowserBridge.extensionFolder }
    /// Browsers load the copy in Application Support: it survives rebuilds and updates of Root.app.
    private var chromiumFolder: URL? { folder == nil ? nil : ExtensionInstaller.chromiumFolder }
    private var firefoxPackageURL: URL? { folder == nil ? nil : ExtensionInstaller.firefoxPackage }

    var body: some View {
        Section {
            if folder == nil { unbundledNote }
            InstallStep(number: 1, text: "Open **\(Self.chromiumPage)** in the address bar. Edge, Brave, Arc and Vivaldi open their own extensions page from this address too.")
            InstallStep(number: 2, text: "Turn on **Developer mode** (top right).")
            InstallStep(number: 3, text: "Click **Load unpacked** and choose the **chromium** folder that Show Extension Folder reveals.")
            HStack(spacing: Tokens.space2) {
                Button {
                    reveal(chromiumFolder)
                } label: {
                    Label("Show Extension Folder", systemImage: "folder")
                }
                .disabled(chromiumFolder == nil)
                Button {
                    copy(Self.chromiumPage)
                } label: {
                    Label(copied ? "Copied" : "Copy Extensions Page Address",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        } header: {
            Text("Install in Chrome, Brave, Edge, Arc or Vivaldi")
        } footer: {
            SettingsFooter("The folder lives in Application Support, so updating or rebuilding Root never removes the extension. Root refreshes its files on launch; after an update click ↻ on Root’s card in the extensions page.")
        }

        Section {
            InstallStep(number: 1, text: "Open **\(Self.firefoxPage)** in Firefox.")
            InstallStep(number: 2, text: "Click **Load Temporary Add-on…**")
            InstallStep(number: 3, text: "Pick **\(Self.firefoxPackage)** from the extension folder.")
            HStack(spacing: Tokens.space2) {
                Button {
                    reveal(firefoxPackageURL)
                } label: {
                    Label("Show Firefox Add-on", systemImage: "folder")
                }
                .disabled(firefoxPackageURL == nil)
                Button {
                    copy(Self.firefoxPage)
                } label: {
                    Label("Copy Page Address", systemImage: "doc.on.doc")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        } header: {
            Text("Install in Firefox")
        } footer: {
            SettingsFooter("Temporary add-ons are removed when Firefox quits. Regular Firefox only installs add-ons permanently once they are signed by Mozilla; Firefox Developer Edition and Nightly can keep unsigned ones.")
        }
    }

    private var unbundledNote: some View {
        Label("This copy of Root doesn't include the extension folder. Builds made with scripts/bundle.sh add it inside the app.",
              systemImage: "exclamationmark.triangle")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func reveal(_ url: URL?) {
        guard let url else { return }
        ExtensionInstaller.installFromBundleOrLog()
        FinderReveal.reveal([url], fallbackFolder: folder?.path)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(Tokens.quick) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(Tokens.quick) { copied = false }
        }
    }
}

/// A numbered instruction line in a settings section.
private struct InstallStep: View {
    var number: Int
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.space3) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(.primary.opacity(0.07), in: .circle)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .accessibilityHidden(true)
            Text(.init(text))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text.replacingOccurrences(of: "**", with: ""))")
    }
}
