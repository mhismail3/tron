import Testing
@testable import TronMobile

@Suite("Process activity orb")
struct ProcessActivityOrbTests {
    private let tolerance = 0.0001

    @Test("solving geometry matches upstream 20-point golden vectors")
    func solvingGoldenVectors() {
        let frame = ProcessActivityOrbEngine.frame(mode: .solving, time: 0.6)
        #expect(frame.count == 30)
        expect(frame[0], [8.121109, 13.194107, -0.892058, 0.3, 0.590856, 1])
        expect(frame[15], [16.718233, 5.326801, -0.062962, 0.522558, 0.367, 1])
        expect(frame[29], [8.422388, 13.144049, 0.903313, 0.829897, 0.106106, 1])

        let moved = ProcessActivityOrbEngine.frame(mode: .solving, time: 3.3)
        #expect(moved.count == 30)
        expect(moved[0], [8.017374, 7.144441, -0.905688, 0.366774, 0.454536, 1])
        expect(moved[29], [11.717005, 8.646124, 0.963792, 0.849134, 0.089776, 1])
    }

    @Test("thinking geometry matches upstream composing-20 golden vectors")
    func thinkingGoldenVectors() {
        let frame = ProcessActivityOrbEngine.frame(mode: .thinking, time: 0.6)
        #expect(frame.count == 208)
        expect(frame[0], [7.795005, 12.112063, -7.177547, 0.3, 0.682444, 0.42394])
        expect(frame[104], [17.798885, 9.900929, -0.087031, 0.398683, 0.322455, 0.696653])
        expect(frame[207], [10, 6.759833, 7.095162, 0.431603, 0.27988, 0.972891])

        let moved = ProcessActivityOrbEngine.frame(mode: .thinking, time: 3.3)
        #expect(moved.count == 208)
        expect(moved[0], [12.25499, 12.510684, -7.032175, 0.3, 0.678343, 0.429532])
        expect(moved[104], [2.850035, 6.905081, 0.373456, 0.362251, 0.389467, 0.714364])
        expect(moved[207], [10, 7.503918, 7.389829, 0.436692, 0.271569, 0.984224])
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

    @Test("frames remain depth sorted for painter order")
    func depthOrder() {
        for mode in [ProcessActivityOrbMode.solving, .thinking] {
            let frame = ProcessActivityOrbEngine.frame(mode: mode, time: 5.1)
            #expect(zip(frame, frame.dropFirst()).allSatisfy { pair in pair.0.z <= pair.1.z })
            #expect(frame.allSatisfy { $0.radius >= 0.3 && $0.alpha >= 0.02 })
        }
    }

    private func expect(_ dot: ProcessActivityOrbDot, _ expected: [Double]) {
        let actual = [dot.x, dot.y, dot.z, dot.radius, dot.white, dot.alpha]
        #expect(actual.count == expected.count)
        for (value, golden) in zip(actual, expected) {
            #expect(abs(value - golden) <= tolerance)
        }
    }
}
