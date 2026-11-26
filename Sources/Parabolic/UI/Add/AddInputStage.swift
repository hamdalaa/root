import SwiftUI

/// Stage 1: a big glass link field that recognises the site as you type, with paste and Continue.
struct AddInputStage: View {
    @Bindable var model: AddDownloadModel
    var onContinue: () -> Void
    var onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var platform: Platform? { TypedLinkRecognizer.platform(in: model.urlText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AddSheetHeader(title: "New download",
                           subtitle: "Paste a link from YouTube or any other site yt-dlp supports.",
                           symbol: "arrow.down.circle")
                .padding(.bottom, Tokens.space5)

            PlatformLinkField(text: $model.urlText, hasError: model.inputError != nil, onSubmit: onContinue)
                .onChange(of: model.urlText) { if model.inputError != nil { model.inputError = nil } }

            Group {
                if let error = model.inputError {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .padding(.leading, Tokens.space4)
                        .padding(.top, Tokens.space2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .accessibilityLabel("Error: \(error)")
                }
            }
            .animation(reduceMotion ? nil : Tokens.quick, value: model.inputError)

            HStack(spacing: Tokens.space3) {
                LinkPlatformStrip(highlighted: platform == .other ? nil : platform)
                    .animation(reduceMotion ? nil : Tokens.quick, value: platform)
                Text("and many more sites")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, Tokens.space4 + 2)
            .padding(.top, Tokens.space3)

            HStack(spacing: Tokens.space2) {
                Label("Playlist and channel links let you pick videos or follow new uploads.", systemImage: "rectangle.stack")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(2)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: onContinue)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityHint("Looks up the link")
            }
            .controlSize(.large)
            .padding(.top, Tokens.space6)
        }
        .padding(Tokens.space5)
    }
}
