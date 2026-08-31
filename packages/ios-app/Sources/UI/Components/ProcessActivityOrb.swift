import SwiftUI

/// Native emerald-tinted port of the 20-point `solving` and `composing`
/// geometry from Jakub Antalik's MIT-licensed thinking-orbs project.
/// Geometry stays renderer-independent so focused tests can compare the
/// upstream numeric golden vectors without relying on screenshots.
enum ProcessActivityOrbMode: Hashable, Sendable {
    case solving
    case thinking
}

struct ProcessActivityOrbDot: Equatable, Sendable {
    let x: Double
    let y: Double
    let z: Double
    let radius: Double
    let white: Double
    let alpha: Double
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

    private static let size = 20.0

    static func frame(mode: ProcessActivityOrbMode, time: Double) -> [ProcessActivityOrbDot] {
        switch mode {
        case .solving: solvingFrame(time: time)
        case .thinking: thinkingFrame(time: time)
        }
    }

    // MARK: Solving / Rubik

    private static func solvingFrame(time: Double) -> [ProcessActivityOrbDot] {
        let center = size / 2
        let sphereRadius = (size / 2) * 0.82
        let project = projector(
            yaw: time * 0.55,
            tilt: 0.35 + 0.1 * sin(time * 0.9),
            centerX: center,
            centerY: center,
            scale: sphereRadius
        )
        let radiusScale = pow(size / 300, 0.6)
        let moves = makeMoves(count: 14)
        let cycle = solveCycle(time: time, count: 14, slotDuration: 0.42, rest: 1.2)
        var dots: [ProcessActivityOrbDot] = []
        let latitudeRings = 4
        let longitudeDensity = 12

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
                let depth = (projected.z + 1) / 2
                dots.append(ProcessActivityOrbDot(
                    x: projected.x,
                    y: projected.y,
                    z: projected.z,
                    radius: max(0.3, (1.14 + 3.23 * depth + (moved.inActive ? 0.57 : 0)) * radiusScale),
                    white: 0.62 - 0.54 * depth - (moved.inActive ? 0.14 : 0),
                    alpha: 1
                ))
            }
        }
        return finalized(dots)
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

    // MARK: Thinking / Composing ribbon

    /// The demo labels upstream's `composing` ribbon as “Thinking…”. Unlike
    /// the compact `breathing` ring, this is the dotted spherical sash the
    /// resting composer control is intended to show.
    private static func thinkingFrame(time: Double) -> [ProcessActivityOrbDot] {
        let center = size / 2
        let sphereRadius = (size / 2) * 0.78
        let cameraTilt = 0.3
        let project = projector(yaw: 0, tilt: cameraTilt, centerX: center, centerY: center, scale: 1)
        let radiusScale = pow(size / 300, 0.6)
        var dots: [ProcessActivityOrbDot] = []

        // Upstream composing-20 preset: eight faint Fibonacci-lattice dots
        // retain the spherical volume behind the ten-lane ribbon.
        let ghostCount = 8
        dots.reserveCapacity(ghostCount + 200)
        for index in 0..<ghostCount {
            let direction = fibonacciDirection(index: index, count: ghostCount)
            let projected = project(
                direction.x * sphereRadius,
                direction.y * sphereRadius,
                direction.z * sphereRadius
            )
            let depth = (projected.z / sphereRadius + 1) / 2
            dots.append(ProcessActivityOrbDot(
                x: projected.x,
                y: projected.y,
                z: projected.z,
                radius: max(0.3, 0.8 * radiusScale),
                white: 0.78,
                alpha: 0.1 + 0.22 * depth
            ))
        }

        // spin=0 freezes the band orientation while its two waves travel.
        let tilt = 0.55
        let ux = 1.0
        let uy = 0.0
        let uz = 0.0
        let vx = 0.0
        let vy = cos(tilt)
        let vz = sin(tilt)
        let nx = uy * vz - uz * vy
        let ny = uz * vx - ux * vz
        let nz = ux * vy - uy * vx
        let lanes = 10
        let segments = 20

        for lane in 0..<lanes {
            let laneOffset = (Double(lane) - Double(lanes - 1) / 2) * 0.075
            let edge = abs(Double(lane) - Double(lanes - 1) / 2) / max(1, Double(lanes - 1) / 2)
            for segment in 0..<segments {
                let angle = (Double(segment) / Double(segments)) * 2 * Double.pi
                let wobble = 0.16 * sin(angle * 3 - time * 1.7 + Double(lane) * 0.22)
                    + 0.07 * sin(angle * 5 + time * 1.1)
                let offset = laneOffset + wobble
                let x = ux * cos(angle) + vx * sin(angle) + nx * offset
                let y = uy * cos(angle) + vy * sin(angle) + ny * offset
                let z = uz * cos(angle) + vz * sin(angle) + nz * offset
                let length = sqrt(x * x + y * y + z * z)
                let projected = project(
                    (x / length) * sphereRadius,
                    (y / length) * sphereRadius,
                    (z / length) * sphereRadius
                )
                let depth = (projected.z / sphereRadius + 1) / 2
                dots.append(ProcessActivityOrbDot(
                    x: projected.x,
                    y: projected.y,
                    z: projected.z,
                    radius: max(0.3, (1.1803 + 1.8241 * depth) * (1 - 0.25 * edge) * radiusScale),
                    white: 0.52 - 0.44 * depth + 0.18 * edge,
                    alpha: 0.4 + 0.6 * depth
                ))
            }
        }
        return finalized(dots)
    }

    private static func fibonacciDirection(index: Int, count: Int) -> (x: Double, y: Double, z: Double) {
        let goldenAngle = Double.pi * (3 - sqrt(5))
        let y = 1 - (2 * (Double(index) + 0.5)) / Double(count)
        let radial = sqrt(1 - y * y)
        let angle = Double(index) * goldenAngle
        return (radial * cos(angle), y, radial * sin(angle))
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

    private static func finalized(_ dots: [ProcessActivityOrbDot]) -> [ProcessActivityOrbDot] {
        dots.filter { $0.alpha >= 0.02 }.sorted { $0.z < $1.z }
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
                let dots = ProcessActivityOrbEngine.frame(mode: mode, time: time)
                let scale = min(canvasSize.width, canvasSize.height) / 20
                for dot in dots {
                    let depthInk = min(1, max(0, 1 - dot.white))
                    let opacity = min(1, max(0, dot.alpha * (0.16 + 0.84 * depthInk)))
                    let radius = dot.radius * scale
                    let rect = CGRect(
                        x: dot.x * scale - radius,
                        y: dot.y * scale - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(Color.tronEmerald.opacity(opacity)))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var speed: Double {
        let baseSpeed = switch mode {
        case .solving: 1.95
        case .thinking: 3.12
        }
        return baseSpeed * max(0.1, animationSpeedScale)
    }
}
