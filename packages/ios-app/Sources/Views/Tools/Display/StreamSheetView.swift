import SwiftUI

/// Live stream sheet that displays frames from the Display tool's stream type.
/// Auto-presented on first frame, can be dismissed and re-opened via toolbar icon.
/// When the stream has ended, shows the last captured frame with stop button disabled.
@available(iOS 26.0, *)
struct StreamSheetView: View {
    let frameImage: UIImage?
    let isStreamActive: Bool
    let onClose: () -> Void
    let onStop: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let image = frameImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding()
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .tronIndigo))
                            .scaleEffect(1.5)
                        Text("Waiting for stream...")
                            .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronTextMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onStop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(isStreamActive ? .red : .tronTextMuted)
                    }
                    .disabled(!isStreamActive)
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.rectangle.fill")
                            .foregroundStyle(.tronIndigo)
                        Text(isStreamActive ? "Live Stream" : "Stream Ended")
                            .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(.tronIndigo)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronIndigo)
                    }
                }
            }
            .background(Color.tronBackground)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
    }
}
