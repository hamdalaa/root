import AppKit
import SwiftUI

/// SHA-256 of a finished file, plus a field to check it against the hash a site publishes.
struct InspectorChecksum: View {
    let path: String

    @State private var hash: String?
    @State private var isHashing = false
    @State private var failed = false
    @State private var expected = ""
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Regular files only (a torrent can finish as a folder).
    static func canHash(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private var trimmedExpected: String { expected.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Checksum")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
            VStack(alignment: .leading, spacing: 12) {
                if let hash {
                    hashView(hash)
                    verifyField(hash)
                } else {
                    calculateRow
                }
            }
            .padding(Tokens.space3 + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: Tokens.radiusRow)
        }
        .animation(reduceMotion ? nil : Tokens.motion, value: hash)
        .animation(reduceMotion ? nil : Tokens.quick, value: trimmedExpected.isEmpty)
    }

    // MARK: Calculate

    private var calculateRow: some View {
        HStack(spacing: 10) {
            Button(action: calculate) {
                HStack(spacing: 6) {
                    if isHashing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "number")
                    }
                    Text(isHashing ? "Calculating…" : "Calculate SHA-256")
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.glass)
            .disabled(isHashing)
            Spacer(minLength: 0)
            if failed {
                Label("Couldn’t read the file", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            }
        }
    }

    private func calculate() {
        isHashing = true
        failed = false
        Task {
            let result = await Checksum.sha256(of: path)
            isHashing = false
            hash = result
            failed = result == nil
        }
    }

    // MARK: Result

    private func hashView(_ hash: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("SHA-256")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hash, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.hover)
                .help("Copy the SHA-256 hash")
            }
            Text(hash)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("SHA-256 hash")
                .accessibilityValue(hash)
        }
    }

    private func verifyField(_ hash: String) -> some View {
        let matches = Checksum.matches(hash, expected: trimmedExpected)
        return VStack(alignment: .leading, spacing: 6) {
            TextField("Verify", text: $expected, prompt: Text("Paste the expected hash to verify"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .accessibilityLabel("Expected hash")
            if !trimmedExpected.isEmpty {
                Label(matches ? "Matches" : "Doesn’t match",
                      systemImage: matches ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(matches ? Color.green : Color.red)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .leading)))
                    .accessibilityLabel(matches ? "Checksum matches" : "Checksum doesn't match")
            }
        }
    }
}
