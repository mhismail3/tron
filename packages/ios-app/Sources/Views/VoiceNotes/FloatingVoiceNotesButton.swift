import SwiftUI

/// Floating mic button for voice notes, teal tint.
/// Automatically disables when audio recording is unavailable (e.g., during phone calls).
@available(iOS 26.0, *)
struct FloatingVoiceNotesButton: View {
    let action: () -> Void
    var size: CGFloat = 44
    private let audioMonitor = AudioAvailabilityMonitor.shared

    var body: some View {
        Button(action: action) {
            Image(systemName: audioMonitor.isRecordingAvailable ? "mic.fill" : "mic.slash.fill")
                .font(TronTypography.button)
                .foregroundStyle(audioMonitor.isRecordingAvailable ? .tronTeal : .tronTextDisabled)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .disabled(!audioMonitor.isRecordingAvailable)
        .glassEffect(
            .regular.tint(audioMonitor.isRecordingAvailable
                ? Color.tronTeal.opacity(0.4)
                : Color.tronOverlay(0.1)
            ).interactive(),
            in: .circle
        )
    }
}

#if DEBUG
#Preview {
    ZStack {
        Color.black
        FloatingVoiceNotesButton(action: {})
    }
}
#endif
