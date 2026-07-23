import SwiftUI

/// Bounded visual history for the composer's normalized microphone level.
/// Raw audio remains owned by `ComposerMicCaptureEngine` and never enters UI state.
struct RecordingLevelWaveform: View {
    let level: Double
    @State private var samples = Array(repeating: 0.06, count: 18)

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(samples.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.tronEmerald)
                    .frame(width: 2, height: 3 + (samples[index] * 19))
            }
        }
        .frame(maxHeight: .infinity)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.45), location: 0.28),
                    .init(color: .black, location: 0.62),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .onChange(of: level, initial: true) { _, nextLevel in
            samples.removeFirst()
            samples.append(max(0.06, min(nextLevel, 1)))
        }
        .accessibilityHidden(true)
    }
}
