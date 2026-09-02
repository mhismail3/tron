import SwiftUI

/// Minimal emerald activity animation inspired by Jakub Antalik's
/// MIT-licensed thinking-orbs project. Working uses a sparse twisting sphere;
/// resting uses a small set of continuous curved strands.
/// Geometry stays renderer-independent for deterministic focused tests.
enum ProcessActivityOrbMode: Hashable, Sendable {
    case solving
    case thinking
}

struct ProcessActivityOrbPoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

struct ProcessActivityOrbDot: Equatable, Sendable {
    let center: ProcessActivityOrbPoint
    let depth: Double
    let radius: Double
    let opacity: Double
}

struct ProcessActivityOrbStroke: Equatable, Sendable {
    let start: ProcessActivityOrbPoint
    let control1: ProcessActivityOrbPoint
    let control2: ProcessActivityOrbPoint
    let end: ProcessActivityOrbPoint
    let depth: Double
    let width: Double
    let opacity: Double
}

struct ProcessActivityOrbFrame: Equatable, Sendable {
    let dots: [ProcessActivityOrbDot]
    let strokes: [ProcessActivityOrbStroke]
}

enum ProcessActivityOrbEngine {
    static let reducedMotionTime = 0.6

    static func animationPaused(
        reduceMotion: Bool,
        isVisible: Bool,
        sceneActive: Bool,
        surfaceActive: Bool = true
    ) -> Bool {
        reduceMotion || !isVisible || !sceneActive || !surfaceActive
    }

    /// Longer delegated runs animate more slowly without allowing very long
    /// history items to become effectively static.
    static func durationSpeedScale(durationMs: Int?) -> Double {
        guard let durationMs, durationMs > 0 else { return 1 }
        let durationMinutes = Double(durationMs) / 60_000
        return max(0.45, 1 / (1 + durationMinutes * 0.08))
    }

    private struct Move: Sendable {
        let axis: Int
        let lower: Double
        let upper: Double
        let angle: Double
    }

    private struct ProjectedPoint: Sendable {
        let point: ProcessActivityOrbPoint
        let depth: Double
    }

    private static let size = 20.0
    private static let solvingMoves = makeMoves(count: 8)
    private static let thinkingLaneSamples = [0.0, 3.0, 6.0, 9.0]

    static func frame(mode: ProcessActivityOrbMode, time: Double) -> ProcessActivityOrbFrame {
        switch mode {
        case .solving: solvingFrame(time: time)
        case .thinking: thinkingFrame(time: time)
        }
    }

    // MARK: Solving / Rubik

    private static func solvingFrame(time: Double) -> ProcessActivityOrbFrame {
        let center = size / 2
        let sphereRadius = (size / 2) * 0.78
        let project = projector(
            yaw: time * 0.55,
            tilt: 0.35 + 0.1 * sin(time * 0.9),
            centerX: center,
            centerY: center,
            scale: sphereRadius
        )
        let moves = solvingMoves
        let cycle = solveCycle(time: time, count: moves.count, slotDuration: 0.48, rest: 1.4)
        var dots: [ProcessActivityOrbDot] = []
        let latitudeRings = 3
        let longitudeDensity = 8
        dots.reserveCapacity(16)

        for latitudeIndex in 0...latitudeRings {
            let latitude = -Double.pi / 2 + (Double(latitudeIndex) / Double(latitudeRings)) * Double.pi
            let cosineLatitude = cos(latitude)
            let sineLatitude = sin(latitude)
            let longitudeCount = max(1, Int((abs(cosineLatitude) * Double(longitudeDensity)).rounded()))
            for longitudeIndex in 0..<longitudeCount {
                let longitude = (Double(longitudeIndex) / Double(longitudeCount)) * 2 * Double.pi
                let moved = applyMoves(
                    point: (cosineLatitude * cos(longitude), sineLatitude, cosineLatitude * sin(longitude)),
                    moves: moves,
                    amounts: cycle.amounts,
                    active: cycle.active
                )
                let projected = project(moved.x, moved.y, moved.z)
                let depth = min(1, max(0, (projected.z + 1) / 2))
                dots.append(ProcessActivityOrbDot(
                    center: ProcessActivityOrbPoint(x: projected.x, y: projected.y),
                    depth: projected.z,
                    radius: 0.7 + 0.52 * depth + (moved.inActive ? 0.16 : 0),
                    opacity: 0.38 + 0.62 * depth
                ))
            }
        }
        return ProcessActivityOrbFrame(
            dots: dots.sorted { $0.depth < $1.depth },
            strokes: []
        )
    }

    private static func solveCycle(
        time: Double,
        count: Int,
        slotDuration: Double,
        rest: Double
    ) -> (amounts: [Double], active: Int) {
        let cycleDuration = 2 * Double(count) * slotDuration + rest
        let cycleTime = positiveRemainder(time, cycleDuration)
        var amounts = Array(repeating: 0.0, count: count)
        var active = -1
        if cycleTime < 2 * Double(count) * slotDuration {
            let slot = Int(floor(cycleTime / slotDuration))
            let progress = (cycleTime - Double(slot) * slotDuration) / slotDuration
            let clamped = min(1, progress / 0.7)
            let eased = 1 - pow(1 - clamped, 3)
            if slot < count {
                if slot > 0 {
                    for index in 0..<slot { amounts[index] = 1 }
                }
                amounts[slot] = eased
                active = slot
            } else {
                let undo = 2 * count - 1 - slot
                if undo > 0 {
                    for index in 0..<undo { amounts[index] = 1 }
                }
                amounts[undo] = 1 - eased
                active = undo
            }
        }
        return (amounts, active)
    }

    private static func makeMoves(count: Int) -> [Move] {
        (0..<count).map { index in
            let axis = min(2, Int(floor(hash(Double(index), 2.3) * 3)))
            let lower = -1 + 0.5 * Double(min(3, Int(floor(hash(Double(index), 5.9) * 4))))
            let direction = hash(Double(index), 7.7) < 0.5 ? 1.0 : -1.0
            return Move(axis: axis, lower: lower, upper: lower + 0.5, angle: direction * .pi / 2)
        }
    }

    private static func applyMoves(
        point: (x: Double, y: Double, z: Double),
        moves: [Move],
        amounts: [Double],
        active: Int
    ) -> (x: Double, y: Double, z: Double, inActive: Bool) {
        var x = point.x
        var y = point.y
        var z = point.z
        var inActive = false
        for index in moves.indices where amounts[index] > 0 {
            let move = moves[index]
            let coordinate = move.axis == 0 ? x : (move.axis == 1 ? y : z)
            guard coordinate >= move.lower, coordinate < move.upper else { continue }
            if index == active { inActive = true }
            let angle = move.angle * amounts[index]
            let cosine = cos(angle)
            let sine = sin(angle)
            switch move.axis {
            case 0:
                let nextY = y * cosine - z * sine
                z = y * sine + z * cosine
                y = nextY
            case 1:
                let nextX = x * cosine + z * sine
                z = -x * sine + z * cosine
                x = nextX
            default:
                let nextX = x * cosine - y * sine
                y = x * sine + y * cosine
                x = nextX
            }
        }
        return (x, y, z, inActive)
    }

    // MARK: Thinking / composing ribbon

    /// Preserve the original ribbon projection and its two traveling waves,
    /// but join mirrored longitude samples into eleven continuous strands
    /// instead of drawing 208 independent circles.
    private static func thinkingFrame(time: Double) -> ProcessActivityOrbFrame {
        let center = size / 2
        let sphereRadius = (size / 2) * 0.78
        let project = projector(
            yaw: 0,
            tilt: 0.3,
            centerX: center,
            centerY: center,
            scale: 1
        )
        let segments = 20
        var strokes: [ProcessActivityOrbStroke] = []
        strokes.reserveCapacity(segments / 2 + 1)

        for column in 0...(segments / 2) {
            let angle = (Double(column) / Double(segments)) * 2 * Double.pi
            let mirroredAngle = positiveRemainder(2 * Double.pi - angle, 2 * Double.pi)
            var samples: [ProjectedPoint] = []
            samples.reserveCapacity(thinkingLaneSamples.count * 2)
            for lane in thinkingLaneSamples {
                samples.append(thinkingPoint(
                    angle: angle,
                    lane: lane,
                    time: time,
                    sphereRadius: sphereRadius,
                    project: project
                ))
                if column > 0, column < segments / 2 {
                    samples.append(thinkingPoint(
                        angle: mirroredAngle,
                        lane: lane,
                        time: time,
                        sphereRadius: sphereRadius,
                        project: project
                    ))
                }
            }
            samples.sort { $0.point.y < $1.point.y }
            guard let first = samples.first, let last = samples.last else { continue }
            let firstThird = samples[samples.count / 3]
            let secondThird = samples[(samples.count * 2) / 3]
            let height = last.point.y - first.point.y
            let frontDepth = samples.reduce(-Double.infinity) { max($0, $1.depth) }
            let normalizedDepth = min(1, max(0, (frontDepth / sphereRadius + 1) / 2))
            let averageDepth = samples.reduce(0) { $0 + $1.depth } / Double(samples.count)

            strokes.append(ProcessActivityOrbStroke(
                start: first.point,
                control1: ProcessActivityOrbPoint(
                    x: firstThird.point.x,
                    y: first.point.y + height * 0.33
                ),
                control2: ProcessActivityOrbPoint(
                    x: secondThird.point.x,
                    y: first.point.y + height * 0.67
                ),
                end: last.point,
                depth: averageDepth,
                width: 0.58 + 0.38 * normalizedDepth,
                opacity: 0.3 + 0.68 * normalizedDepth
            ))
        }

        return ProcessActivityOrbFrame(
            dots: [],
            strokes: strokes.sorted { $0.depth < $1.depth }
        )
    }

    private static func thinkingPoint(
        angle: Double,
        lane: Double,
        time: Double,
        sphereRadius: Double,
        project: Projector
    ) -> ProjectedPoint {
        let laneOffset = (lane - 4.5) * 0.075
        let wobble = 0.16 * sin(angle * 3 - time * 1.7 + lane * 0.22)
            + 0.07 * sin(angle * 5 + time * 1.1)
        let offset = laneOffset + wobble
        let tilt = 0.55
        let x = cos(angle)
        let y = cos(tilt) * sin(angle) - sin(tilt) * offset
        let z = sin(tilt) * sin(angle) + cos(tilt) * offset
        let length = sqrt(x * x + y * y + z * z)
        let projected = project(
            (x / length) * sphereRadius,
            (y / length) * sphereRadius,
            (z / length) * sphereRadius
        )
        return ProjectedPoint(
            point: ProcessActivityOrbPoint(x: projected.x, y: projected.y),
            depth: projected.z
        )
    }

    // MARK: Shared math

    private typealias Projector = (Double, Double, Double) -> (x: Double, y: Double, z: Double)

    private static func projector(
        yaw: Double,
        tilt: Double,
        centerX: Double,
        centerY: Double,
        scale: Double
    ) -> Projector {
        let sineTilt = sin(tilt)
        let cosineTilt = cos(tilt)
        let sineYaw = sin(yaw)
        let cosineYaw = cos(yaw)
        return { x, y, z in
            let rotatedX = x * cosineYaw + z * sineYaw
            let rotatedZ = -x * sineYaw + z * cosineYaw
            let rotatedY = y * cosineTilt - rotatedZ * sineTilt
            let depth = y * sineTilt + rotatedZ * cosineTilt
            return (centerX + rotatedX * scale, centerY - rotatedY * scale, depth)
        }
    }

    private static func hash(_ first: Double, _ second: Double) -> Double {
        let value = sin(first * 12.9898 + second * 78.233) * 43_758.5453
        return value - floor(value)
    }

    private static func positiveRemainder(_ value: Double, _ divisor: Double) -> Double {
        value - floor(value / divisor) * divisor
    }
}

struct ProcessActivityOrb: View {
    let mode: ProcessActivityOrbMode
    var size: CGFloat = 20
    var isVisible = true
    var animationSpeedScale = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tronPresentationActivity) private var presentationActivity

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1 / 30,
            paused: ProcessActivityOrbEngine.animationPaused(
                reduceMotion: reduceMotion,
                isVisible: isVisible,
                sceneActive: scenePhase == .active,
                surfaceActive: presentationActivity.allowsContinuousAnimation
            )
        )) { _ in
            Canvas(rendersAsynchronously: true) { context, canvasSize in
                let time = reduceMotion
                    ? ProcessActivityOrbEngine.reducedMotionTime
                    : ProcessInfo.processInfo.systemUptime * speed
                let frame = ProcessActivityOrbEngine.frame(mode: mode, time: time)
                let scale = min(canvasSize.width, canvasSize.height) / 20
                for stroke in frame.strokes {
                    var path = Path()
                    path.move(to: scaled(stroke.start, by: scale))
                    path.addCurve(
                        to: scaled(stroke.end, by: scale),
                        control1: scaled(stroke.control1, by: scale),
                        control2: scaled(stroke.control2, by: scale)
                    )
                    let top = scaled(stroke.start, by: scale)
                    let bottom = scaled(stroke.end, by: scale)
                    let ink = Color.tronEmerald
                    context.stroke(
                        path,
                        with: .linearGradient(
                            Gradient(stops: [
                                .init(color: ink.opacity(stroke.opacity * 0.82), location: 0),
                                .init(color: ink.opacity(stroke.opacity), location: 0.42),
                                .init(color: ink.opacity(stroke.opacity * 0.3), location: 1),
                            ]),
                            startPoint: top,
                            endPoint: bottom
                        ),
                        style: StrokeStyle(
                            lineWidth: stroke.width * scale,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
                for dot in frame.dots {
                    let radius = dot.radius * scale
                    let center = scaled(dot.center, by: scale)
                    let rect = CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(Color.tronEmerald.opacity(dot.opacity))
                    )
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func scaled(_ point: ProcessActivityOrbPoint, by scale: CGFloat) -> CGPoint {
        CGPoint(x: CGFloat(point.x) * scale, y: CGFloat(point.y) * scale)
    }

    private var speed: Double {
        let baseSpeed = switch mode {
        case .solving: 1.95
        case .thinking: 3.12
        }
        return baseSpeed * max(0.1, animationSpeedScale)
    }
}
