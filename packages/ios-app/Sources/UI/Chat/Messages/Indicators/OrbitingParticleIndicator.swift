import SwiftUI

/// Luminous dots weaving around a central axis with trailing particles
@available(iOS 26.0, *)
struct OrbitingParticleIndicator: View {
    // Particle configurations: (horizontal radius, vertical amplitude, speed, size)
    // Sorted by radius (largest first) for depth layering
    private let particles: [(hRadius: Double, vAmplitude: Double, speed: Double, size: Double)] = [
        (40.0, 6.0, 1.0, 2.5),
        (60.0, 4.5, 0.8, 2.2),
        (25.0, 5.0, 1.3, 2.0),
        (70.0, 3.5, 0.7, 1.8),
        (35.0, 5.5, 1.1, 2.3),
        (50.0, 4.0, 0.9, 2.0)
    ]

    private let trailCount = 7  // Number of trailing positions per particle
    private let trailTimeOffset = 0.02  // Time offset between trail dots

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                let width = size.width
                let height = size.height
                let midX = width / 2
                let midY = height / 2

                // Draw particles from largest radius to smallest (depth layering)
                for (index, particle) in particles.enumerated() {
                    // Base opacity decreases with larger orbits (depth effect)
                    let depthOpacity = 1.0 - Double(index) * 0.12

                    // Brightness oscillation
                    let brightnessPhase = time * particle.speed * 2.0 + Double(index) * 0.8
                    let brightness = 0.6 + 0.4 * sin(brightnessPhase)

                    // Draw trail (older positions first)
                    for trailIdx in (0..<trailCount).reversed() {
                        let trailTime = time - Double(trailIdx) * trailTimeOffset
                        let angle = trailTime * particle.speed

                        let x = midX + cos(angle) * particle.hRadius
                        let y = midY + sin(angle) * particle.vAmplitude

                        let isLead = trailIdx == 0
                        let trailFade = 1.0 - (Double(trailIdx) / Double(trailCount))
                        let trailSize = particle.size * (0.5 + trailFade * 0.5)
                        let trailOpacity = depthOpacity * brightness * trailFade

                        // Draw glow halo for lead particle
                        if isLead {
                            var haloPath = Path()
                            haloPath.addEllipse(in: CGRect(
                                x: x - particle.size * 2,
                                y: y - particle.size * 2,
                                width: particle.size * 4,
                                height: particle.size * 4
                            ))
                            context.fill(
                                haloPath,
                                with: .color(.tronEmerald.opacity(trailOpacity * 0.15))
                            )
                        }

                        // Draw particle dot
                        var dotPath = Path()
                        dotPath.addEllipse(in: CGRect(
                            x: x - trailSize,
                            y: y - trailSize,
                            width: trailSize * 2,
                            height: trailSize * 2
                        ))
                        context.fill(
                            dotPath,
                            with: .color(.tronEmerald.opacity(trailOpacity))
                        )
                    }
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
