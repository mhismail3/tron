import SwiftUI

/// Overlapping sine waves with frequency modulation for drifting interference patterns
@available(iOS 26.0, *)
struct PhaseWaveIndicator: View {
    // Wave configurations: (base frequency, phase speed, mod speed, opacity, linewidth)
    private let waves: [(baseFreq: Double, phaseSpeed: Double, modSpeed: Double, opacity: Double, lineWidth: CGFloat)] = [
        (2.0, 2.0, 0.5, 0.9, 1.8),
        (3.0, 2.3, 0.7, 0.6, 1.4),
        (2.5, 2.5, 0.6, 0.35, 1.0)
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                let width = size.width
                let height = size.height
                let midY = height / 2
                let amplitude = height * 0.35

                // Draw each wave
                for wave in waves {
                    // Frequency modulation for drifting interference
                    let freqMod = 0.3 * sin(time * wave.modSpeed)
                    let frequency = wave.baseFreq + freqMod
                    let phase = time * wave.phaseSpeed

                    var path = Path()
                    let step: CGFloat = 4
                    var points: [CGPoint] = []

                    // Sample points along the wave
                    for x in stride(from: 0, through: width, by: step) {
                        let normalizedX = x / width
                        let angle = normalizedX * frequency * 2 * .pi + phase
                        let y = midY + sin(angle) * amplitude
                        points.append(CGPoint(x: x, y: y))
                    }

                    // Ensure final point
                    if points.last?.x != width {
                        let angle = frequency * 2 * .pi + phase
                        let y = midY + sin(angle) * amplitude
                        points.append(CGPoint(x: width, y: y))
                    }

                    // Draw smooth quadratic curves through points
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
                        with: .color(.tronEmerald.opacity(wave.opacity)),
                        style: StrokeStyle(lineWidth: wave.lineWidth, lineCap: .round, lineJoin: .round)
                    )
                }
            }
            .drawingGroup()
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white, location: 0.1),
                        .init(color: .white, location: 0.9),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
        .frame(height: 20)
    }
}
