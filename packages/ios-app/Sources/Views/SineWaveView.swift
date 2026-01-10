import SwiftUI

/// Continuous sine wave visualization that responds to audio levels.
/// Uses smooth animation for natural wave movement with graceful edge fading.
@available(iOS 26.0, *)
struct SineWaveView: View {
    let audioLevel: Float  // 0-1 normalized
    let color: Color

    // Smooth the audio level changes
    @State private var smoothedLevel: CGFloat = 0

    private let waveCount = 3  // Number of overlapping waves

    var body: some View {
        TimelineView(.animation(minimumInterval: 1/60)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                let width = size.width
                let height = size.height
                let midY = height / 2

                // Draw multiple waves with different phases for depth
                for waveIndex in 0..<waveCount {
                    let opacity = 1.0 - (Double(waveIndex) * 0.25)
                    let phaseOffset = Double(waveIndex) * .pi / 3
                    let amplitudeScale = 1.0 - (Double(waveIndex) * 0.2)

                    // Use time directly for smooth continuous movement
                    let phase = time * (1.5 + Double(waveIndex) * 0.3)

                    var path = Path()
                    // Use smoothed level for less jittery amplitude
                    let baseAmplitude = midY * 0.6 * smoothedLevel * amplitudeScale
                    let amplitude = max(baseAmplitude, midY * 0.05)  // Minimum visible amplitude
                    let frequency = 2.0 + Double(waveIndex) * 0.5

                    for x in stride(from: 0, through: width, by: 1) {
                        let normalizedX = x / width
                        let angle = normalizedX * frequency * 2 * .pi + phase + phaseOffset
                        let y = midY + sin(angle) * amplitude

                        if x == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }

                    // Calculate edge fade for stroke opacity
                    context.stroke(
                        path,
                        with: .color(color.opacity(opacity)),
                        lineWidth: 2 - CGFloat(waveIndex) * 0.3
                    )
                }
            }
            // Apply gradient mask for edge fade
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white, location: 0.15),
                        .init(color: .white, location: 0.85),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
        .onChange(of: audioLevel) { _, newValue in
            // Smooth audio level changes with animation
            withAnimation(.easeOut(duration: 0.1)) {
                smoothedLevel = CGFloat(newValue)
            }
        }
        .onAppear {
            smoothedLevel = CGFloat(audioLevel)
        }
    }
}

#Preview {
    if #available(iOS 26.0, *) {
        ZStack {
            Color.black
            SineWaveView(audioLevel: 0.5, color: .green)
                .frame(height: 80)
                .padding(.horizontal, 20)
        }
    }
}
