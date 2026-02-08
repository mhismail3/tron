import SwiftUI

/// Floating mic button for voice notes - smaller than plus button, teal tint.
/// Automatically disables when audio recording is unavailable (e.g., during phone calls).
@available(iOS 26.0, *)
struct FloatingVoiceNotesButton: View {
    let action: () -> Void
    private let audioMonitor = AudioAvailabilityMonitor.shared

    var body: some View {
        Button(action: action) {
            Image(systemName: audioMonitor.isRecordingAvailable ? "mic.fill" : "mic.slash.fill")
                .font(TronTypography.button)
                .foregroundStyle(audioMonitor.isRecordingAvailable ? .tronTeal : .white.opacity(0.3))
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .disabled(!audioMonitor.isRecordingAvailable)
        .glassEffect(
            .regular.tint(audioMonitor.isRecordingAvailable
                ? Color.tronTeal.opacity(0.4)
                : Color.white.opacity(0.1)
            ).interactive(),
            in: .circle
        )
    }
}

#Preview {
    if #available(iOS 26.0, *) {
        ZStack {
            Color.black
            FloatingVoiceNotesButton(action: {})
        }
    }
}
