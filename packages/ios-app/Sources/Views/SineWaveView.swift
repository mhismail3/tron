import SwiftUI

/// Continuous sine wave visualization that responds to audio levels.
/// Uses smooth animation for natural wave movement with graceful edge fading.
@available(iOS 26.0, *)
struct SineWaveView: View {
    let audioLevel: Float  // 0-1 normalized
    let color: Color

    // Smooth the audio level changes with spring animation
    @State private var displayedLevel: CGFloat = 0

    private let waveCount = 3  // Number of overlapping waves

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                let width = size.width
                let height = size.height
                let midY = height / 2

                // Draw multiple waves with different phases for depth
                for waveIndex in 0..<waveCount {
                    let opacity = 1.0 - (Double(waveIndex) * 0.25)
                    let phaseOffset = Double(waveIndex) * .pi / 3
                    let amplitudeScale = 1.0 - (Double(waveIndex) * 0.15)

                    // Faster wave speed for fluid motion (4-5x faster than before)
                    let speed = 6.0 + Double(waveIndex) * 1.2
                    let phase = time * speed + phaseOffset

                    var path = Path()
                    let baseAmplitude = midY * 0.6 * displayedLevel * amplitudeScale
                    let amplitude = max(baseAmplitude, midY * 0.08)  // Slightly higher minimum
                    let frequency = 2.5 + Double(waveIndex) * 0.4

                    // Use larger steps with quadratic curves for smoother rendering
                    let step: CGFloat = 4
                    var points: [CGPoint] = []

                    for x in stride(from: 0, through: width, by: step) {
                        let normalizedX = x / width
                        let angle = normalizedX * frequency * 2 * .pi + phase
                        let y = midY + sin(angle) * amplitude
                        points.append(CGPoint(x: x, y: y))
                    }

                    // Ensure we include the final point
                    if points.last?.x != width {
                        let angle = frequency * 2 * .pi + phase
                        let y = midY + sin(angle) * amplitude
                        points.append(CGPoint(x: width, y: y))
                    }

                    // Draw smooth curve through points
                    if let first = points.first {
                        path.move(to: first)

                        for i in 1..<points.count {
                            let current = points[i]
                            let previous = points[i - 1]
                            let midPoint = CGPoint(
                                x: (previous.x + current.x) / 2,
                                y: (previous.y + current.y) / 2
                            )
                            path.addQuadCurve(to: midPoint, control: previous)
                        }

                        if let last = points.last {
                            path.addLine(to: last)
                        }
                    }

                    context.stroke(
                        path,
                        with: .color(color.opacity(opacity)),
                        style: StrokeStyle(lineWidth: 2.2 - CGFloat(waveIndex) * 0.4, lineCap: .round, lineJoin: .round)
                    )
                }
            }
            .drawingGroup() // Rasterize to Metal for better performance
            // Apply gradient mask for edge fade
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white, location: 0.12),
                        .init(color: .white, location: 0.88),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
        .onChange(of: audioLevel) { _, newValue in
            // Use spring animation for natural, bouncy response
            withAnimation(.interpolatingSpring(stiffness: 300, damping: 20)) {
                displayedLevel = CGFloat(newValue)
            }
        }
        .onAppear {
            displayedLevel = CGFloat(audioLevel)
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
