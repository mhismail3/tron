import Testing
@testable import TronMobile

@Suite("Process activity orb")
struct ProcessActivityOrbTests {
    @Test("working geometry uses sixteen large depth-aware dots")
    func workingGeometry() {
        let frame = ProcessActivityOrbEngine.frame(mode: .solving, time: 0.6)
        let moved = ProcessActivityOrbEngine.frame(mode: .solving, time: 3.3)

        #expect(frame.dots.count == 16)
        #expect(frame.strokes.isEmpty)
        #expect(moved.dots.count == 16)
        #expect(frame != moved)
        #expect(frame.dots.allSatisfy { dot in
            (0...20).contains(dot.center.x)
                && (0...20).contains(dot.center.y)
                && (0.7...1.38).contains(dot.radius)
                && (0.38...1).contains(dot.opacity)
        })
    }

    @Test("resting geometry preserves the ribbon wave with eleven continuous curves")
    func restingGeometry() {
        let frame = ProcessActivityOrbEngine.frame(mode: .thinking, time: 0.6)
        let moved = ProcessActivityOrbEngine.frame(mode: .thinking, time: 3.3)

        #expect(frame.dots.isEmpty)
        #expect(frame.strokes.count == 11)
        #expect(moved.strokes.count == 11)
        #expect(frame != moved)
        #expect(frame.strokes.allSatisfy { stroke in
            stroke.start.y < stroke.end.y
                && (0.7...1).contains(stroke.width)
                && (0.5...1).contains(stroke.opacity)
                && points(stroke).allSatisfy { point in
                    point.x.isFinite && point.y.isFinite
                        && (-1...21).contains(point.x)
                        && (-1...21).contains(point.y)
                }
        })
        #expect(frame.strokes.contains { stroke in
            abs(stroke.control1.x - stroke.control2.x) > 0.25
        })
    }

    @Test("reduced motion and offscreen rendering pause deterministically")
    func lifecyclePausePolicy() {
        #expect(ProcessActivityOrbEngine.reducedMotionTime == 0.6)
        #expect(ProcessActivityOrbEngine.animationPaused(
            reduceMotion: true, isVisible: true, sceneActive: true
        ))
        #expect(ProcessActivityOrbEngine.animationPaused(
            reduceMotion: false, isVisible: false, sceneActive: true
        ))
        #expect(ProcessActivityOrbEngine.animationPaused(
            reduceMotion: false, isVisible: true, sceneActive: false
        ))
        #expect(ProcessActivityOrbEngine.animationPaused(
            reduceMotion: false,
            isVisible: true,
            sceneActive: true,
            surfaceActive: false
        ))
        #expect(!ProcessActivityOrbEngine.animationPaused(
            reduceMotion: false, isVisible: true, sceneActive: true
        ))
        #expect(
            ProcessActivityOrbEngine.frame(
                mode: .thinking,
                time: ProcessActivityOrbEngine.reducedMotionTime
            ) == ProcessActivityOrbEngine.frame(mode: .thinking, time: 0.6)
        )
    }

    @Test("longer runs animate more slowly within a readable bound")
    func durationSpeedScale() {
        let short = ProcessActivityOrbEngine.durationSpeedScale(durationMs: 10_000)
        let medium = ProcessActivityOrbEngine.durationSpeedScale(durationMs: 300_000)
        let long = ProcessActivityOrbEngine.durationSpeedScale(durationMs: 3_600_000)

        #expect(ProcessActivityOrbEngine.durationSpeedScale(durationMs: nil) == 1)
        #expect(ProcessActivityOrbEngine.durationSpeedScale(durationMs: 0) == 1)
        #expect(short < 1)
        #expect(short > medium)
        #expect(medium > long)
        #expect(long == 0.45)
    }

    @Test("frames retain depth painter order with bounded ink")
    func depthOrder() {
        for mode in [ProcessActivityOrbMode.solving, .thinking] {
            let frame = ProcessActivityOrbEngine.frame(mode: mode, time: 5.1)
            #expect(zip(frame.dots, frame.dots.dropFirst()).allSatisfy { pair in
                pair.0.depth <= pair.1.depth
            })
            #expect(zip(frame.strokes, frame.strokes.dropFirst()).allSatisfy { pair in
                pair.0.depth <= pair.1.depth
            })
            #expect(frame.dots.allSatisfy { $0.radius > 0 && $0.opacity > 0 && $0.opacity <= 1 })
            #expect(frame.strokes.allSatisfy { $0.width > 0 && $0.opacity > 0 && $0.opacity <= 1 })
        }
    }

    private func points(_ stroke: ProcessActivityOrbStroke) -> [ProcessActivityOrbPoint] {
        [stroke.start, stroke.control1, stroke.control2, stroke.end]
    }
}
