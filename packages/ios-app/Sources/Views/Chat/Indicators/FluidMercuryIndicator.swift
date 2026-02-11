import SwiftUI

/// Morphing metaball blob that splits and recombines
@available(iOS 26.0, *)
struct FluidMercuryIndicator: View {
    // Metaball charge configurations: (radius, speed, angle offset)
    private let charges: [(radius: Double, speed: Double, angleOffset: Double)] = [
        (8.0, 1.2, 0.0),
        (12.0, 0.9, 2.1),
        (6.0, 1.5, 4.2)
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            Canvas { context, size in
                let width = size.width
                let height = size.height
                let midX = width / 2
                let midY = height / 2

                // Render in central 60% with coarse grid for performance
                let renderWidth = width * 0.6
                let startX = midX - renderWidth / 2
                let cellSize: CGFloat = 3  // 3x3 pixel cells

                for x in stride(from: startX, through: startX + renderWidth, by: cellSize) {
                    for y in stride(from: 0, through: height, by: cellSize) {
                        var fieldValue: Double = 0

                        // Sum metaball contributions
                        for (index, charge) in charges.enumerated() {
                            let angle = time * charge.speed + charge.angleOffset
                            let chargeX = midX + cos(angle) * charge.radius
                            let chargeY = midY + sin(angle) * charge.radius * 0.5  // Flatten vertical

                            let dx = x - chargeX
                            let dy = y - chargeY
                            let distSquared = dx * dx + dy * dy

                            if distSquared > 0.01 {  // Avoid division by zero
                                let radiusSquared = charge.radius * charge.radius
                                fieldValue += radiusSquared / distSquared
                            }
                        }

                        // Smoothstep threshold for soft contour
                        let threshold = 1.0
                        let softness = 0.3
                        let t = (fieldValue - threshold) / softness
                        let alpha = max(0, min(1, 0.5 + t * (1.5 - t * 0.5)))  // Smoothstep

                        if alpha > 0.01 {
                            // Modulate brightness by field for depth
                            let brightness = min(1.0, fieldValue / 3.0)
                            let opacity = alpha * (0.7 + brightness * 0.3)

                            var cellPath = Path()
                            cellPath.addRect(CGRect(x: x, y: y, width: cellSize, height: cellSize))
                            context.fill(
                                cellPath,
                                with: .color(.tronEmerald.opacity(opacity))
                            )
                        }
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
