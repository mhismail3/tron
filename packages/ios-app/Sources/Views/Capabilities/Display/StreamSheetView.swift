import SwiftUI

/// Live stream sheet that displays frames from the Display tool's stream type.
/// Auto-presented on first frame, can be dismissed and re-opened via toolbar icon.
/// When the stream has ended, shows the last captured frame with stop button disabled.
///
/// Takes the viewModel directly rather than `let` copies so that `@Observable`
/// tracking keeps the UI reactive (stop button, toolbar, frame image all update
/// in real time when stream state changes).
@available(iOS 26.0, *)
struct StreamSheetView: View {
    let viewModel: ChatViewModel
    let onClose: () -> Void
    let onStop: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Read from viewModel in body so @Observable tracks these accesses.
        let frameImage = viewModel.displayStreamState.streamFrameImage
        let isActive = viewModel.displayStreamState.isStreamActive

        NavigationStack {
            Group {
                if let image = frameImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding()
                } else if !isActive {
                    VStack(spacing: 16) {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 40))
                            .foregroundStyle(.tronTextMuted)
                        Text("Stream ended")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronTextMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .tronIndigo))
                            .scaleEffect(1.5)
                        Text("Waiting for stream...")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
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
                            .foregroundStyle(isActive ? .red : .tronTextMuted)
                    }
                    .disabled(!isActive)
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.rectangle.fill")
                            .foregroundStyle(.tronIndigo)
                        Text(isActive ? "Live Stream" : "Stream Ended")
                            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
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
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
    }
}
