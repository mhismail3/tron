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

    @Test("breathing geometry matches upstream 20-point golden vectors")
    func breathingGoldenVectors() {
        let frame = ProcessActivityOrbEngine.frame(mode: .breathing, time: 0.6)
        #expect(frame.count == 120)
        expect(frame[0], [12.339578, 17.20048, -1.987396, 0.4153, 0.536055, 0.623562])
        expect(frame[60], [15.590196, 12.488915, 0.229471, 0.608374, 0.319242, 0.708826])
        expect(frame[119], [3.883903, 5.556396, 1.984477, 0.519, 0.424028, 0.776326])

        let moved = ProcessActivityOrbEngine.frame(mode: .breathing, time: 3.3)
        #expect(moved.count == 120)
        expect(moved[0], [9.201663, 17.595667, -2.004845, 0.414845, 0.536547, 0.622891])
        expect(moved[119], [16.910423, 13.076719, 1.985655, 0.519031, 0.423994, 0.776371])
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
        #expect(!ProcessActivityOrbEngine.animationPaused(
            reduceMotion: false, isVisible: true, sceneActive: true
        ))
        #expect(
            ProcessActivityOrbEngine.frame(
                mode: .breathing,
                time: ProcessActivityOrbEngine.reducedMotionTime
            ) == ProcessActivityOrbEngine.frame(mode: .breathing, time: 0.6)
        )
    }

    @Test("frames remain depth sorted for painter order")
    func depthOrder() {
        for mode in [ProcessActivityOrbMode.solving, .breathing] {
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
