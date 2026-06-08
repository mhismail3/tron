import SwiftUI

/// Energy pulses traveling along a horizontal wire with Gaussian glow
@available(iOS 26.0, *)
struct NeuralSparkIndicator: View {
    // Pulse configurations: (speed, intensity oscillation speed, sigma for glow width)
    private let pulses: [(speed: Double, intensitySpeed: Double, sigma: Double)] = [
        (0.3, 2.1, 20.0),
        (0.5, 1.7, 18.0),
        (0.7, 2.4, 22.0),
        (0.45, 1.9, 19.0)
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                let width = size.width
                let height = size.height
                let midY = height / 2

                // Draw base wire line
                var wirePath = Path()
                wirePath.move(to: CGPoint(x: 0, y: midY))
                wirePath.addLine(to: CGPoint(x: width, y: midY))
                context.stroke(
                    wirePath,
                    with: .color(.tronEmerald.opacity(0.15)),
                    style: StrokeStyle(lineWidth: 1.0, lineCap: .round)
                )

                // Draw spark pulses
                let step: CGFloat = 3  // Column width for performance
                for x in stride(from: 0, through: width, by: step) {
                    var totalIntensity: Double = 0

                    // Sum contributions from all pulses
                    for (index, pulse) in pulses.enumerated() {
                        // Pulse position wraps around
                        let pulsePos = fmod(time * pulse.speed, 1.0) * width
                        let distance = abs(x - pulsePos)

                        // Gaussian glow: exp(-d²/2σ²)
                        let gaussian = exp(-pow(distance, 2.0) / (2.0 * pow(pulse.sigma, 2.0)))

                        // Intensity oscillation
                        let phaseOffset = Double(index) * 0.7  // Phase shift per pulse
                        let intensityMod = 0.5 + 0.5 * sin(time * pulse.intensitySpeed + phaseOffset)

                        totalIntensity += gaussian * intensityMod
                    }

                    // Clamp and render column
                    let opacity = min(totalIntensity, 1.0)
                    if opacity > 0.01 {  // Skip rendering negligible values
                        var columnPath = Path()
                        columnPath.move(to: CGPoint(x: x, y: midY - height * 0.3))
                        columnPath.addLine(to: CGPoint(x: x, y: midY + height * 0.3))
                        context.stroke(
                            columnPath,
                            with: .color(.tronEmerald.opacity(opacity)),
                            style: StrokeStyle(lineWidth: step, lineCap: .butt)
                        )
                    }
                }
            }
            .drawingGroup()  // Metal rasterization
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
