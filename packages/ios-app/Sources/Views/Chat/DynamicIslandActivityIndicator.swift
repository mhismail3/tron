import SwiftUI

/// Orbiting emerald arc around the Dynamic Island pill shape.
/// Uses TimelineView + Canvas + drawingGroup (Metal-backed) for smooth 60fps animation.
@available(iOS 26.0, *)
struct DynamicIslandActivityIndicator: View {
    // MARK: - Tunable Constants

    /// Dynamic Island pill dimensions (iPhone 14 Pro+)
    private let pillWidth: CGFloat = 126
    private let pillHeight: CGFloat = 37
    private let pillTopOffset: CGFloat = 11
    /// Padding between pill edge and arc stroke center (negative = outside)
    private let arcInset: CGFloat = -4

    /// Arc length as fraction of perimeter (0.25 = 25%)
    private let arcLength: CGFloat = 0.25
    /// Seconds per full orbit
    private let orbitDuration: Double = 2.0

    /// Stroke widths at the head
    private let glowWidth: CGFloat = 5
    private let coreWidth: CGFloat = 2.5
    /// Glow opacity at the head
    private let glowOpacity: Double = 0.3

    /// Number of segments for the gradient tail effect
    private let segments: Int = 20

    @State private var appeared = false

    var body: some View {
        TimelineView(.animation) { timeline in
            canvas(date: timeline.date)
        }
        .frame(height: pillTopOffset + pillHeight + 4 + glowWidth)
        .allowsHitTesting(false)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.3)) {
                appeared = true
            }
        }
    }

    private func canvas(date: Date) -> some View {
        let elapsed = date.timeIntervalSinceReferenceDate
        let progress = elapsed.truncatingRemainder(dividingBy: orbitDuration) / orbitDuration

        return Canvas { context, size in
            let pillRect = CGRect(
                x: (size.width - pillWidth) / 2,
                y: pillTopOffset,
                width: pillWidth,
                height: pillHeight
            )
            let cornerRadius = pillHeight / 2
            let arcRect = pillRect.insetBy(dx: arcInset, dy: arcInset)
            let arcCornerRadius = cornerRadius - arcInset

            let pillPath = RoundedRectangle(cornerRadius: arcCornerRadius)
                .path(in: arcRect)

            let segLen = arcLength / CGFloat(segments)

            // Draw tail-to-head so the bright head paints on top
            for i in 0..<segments {
                // t=0 at tail, t=1 at head
                let t = CGFloat(i) / CGFloat(segments - 1)
                // Ease-in curve: tail fades fast, head stays bright
                let fade = t * t

                let segStart = progress + segLen * CGFloat(i)
                let segEnd = segStart + segLen * 1.5 // slight overlap to avoid gaps

                let seg = trimmedArc(from: pillPath, start: segStart, end: min(segEnd, segStart + segLen * 1.5))

                let segGlowWidth = glowWidth * (0.2 + 0.8 * fade)
                let segCoreWidth = coreWidth * (0.15 + 0.85 * fade)

                // Glow layer
                context.stroke(
                    seg,
                    with: .color(Color.tronEmerald.opacity(glowOpacity * fade)),
                    style: StrokeStyle(lineWidth: segGlowWidth, lineCap: .round)
                )

                // Core layer
                context.stroke(
                    seg,
                    with: .color(Color.tronEmerald.opacity(fade)),
                    style: StrokeStyle(lineWidth: segCoreWidth, lineCap: .round)
                )
            }
        }
        .drawingGroup()
    }

    /// Trim a path, handling wrap-around past 1.0
    private func trimmedArc(from path: Path, start: Double, end: Double) -> Path {
        if end <= 1 {
            return path.trimmedPath(from: CGFloat(start), to: CGFloat(end))
        }
        var combined = path.trimmedPath(from: CGFloat(start), to: 1)
        combined.addPath(path.trimmedPath(from: 0, to: CGFloat(end - 1)))
        return combined
    }
}

#Preview {
    if #available(iOS 26.0, *) {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                DynamicIslandActivityIndicator()
                Spacer()
            }
        }
    }
}
