import SwiftUI

/// Stage 2: skeleton of the result while yt-dlp looks the link up.
struct AddDiscoveringStage: View {
    var host: String
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.space5) {
            HStack(alignment: .top, spacing: Tokens.space4) {
                SkeletonBlock(cornerRadius: Tokens.radiusThumb)
                    .frame(width: Tokens.heroThumb.width, height: Tokens.heroThumb.height)
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBlock(cornerRadius: 5).frame(height: 16)
                    SkeletonBlock(cornerRadius: 5).frame(width: 170, height: 16)
                    SkeletonBlock(cornerRadius: 4).frame(width: 110, height: 11).padding(.top, 6)
                    SkeletonBlock(cornerRadius: 4).frame(width: 64, height: 11)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        SkeletonBlock(cornerRadius: 10).frame(width: 64, height: 20)
                        SkeletonBlock(cornerRadius: 10).frame(width: 44, height: 20)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: Tokens.heroThumb.height)

            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { index in
                    HStack {
                        SkeletonBlock(cornerRadius: 4).frame(width: 18, height: 14)
                        SkeletonBlock(cornerRadius: 4).frame(width: [90, 70, 110][index], height: 12)
                        Spacer()
                        SkeletonBlock(cornerRadius: 6).frame(width: 96, height: 20)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .padding(.vertical, 4)
            .glassPanel(cornerRadius: Tokens.radiusRow)
        }
        .padding(Tokens.space5)
        .accessibilityHidden(true)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SheetBottomBar {
                HStack(spacing: Tokens.space2) {
                    ProgressView().controlSize(.small)
                    Text("Looking up \(host)…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Looking up \(host)")
            } trailing: {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Stops looking up this link")
            }
        }
    }
}

/// Placeholder block with a slow shimmer sweep. Static when Reduce Motion is on.
struct SkeletonBlock: View {
    var cornerRadius: CGFloat
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.primary.opacity(0.07))
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, .white.opacity(0.14), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(proxy.size.width * 0.6, 60))
                            .offset(x: phase * proxy.size.width * 1.4)
                    }
                    .clipShape(.rect(cornerRadius: cornerRadius))
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}
