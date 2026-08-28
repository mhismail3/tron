import Testing
@testable import TronMobile

@Suite("Tron pulse loading indicator")
struct TronPulseLoadingIndicatorTests {
    @Test("pauses for reduced motion or an inactive scene")
    func pausePolicy() {
        #expect(TronPulseLoadingIndicatorEngine.animationPaused(
            reduceMotion: true, sceneActive: true
        ))
        #expect(TronPulseLoadingIndicatorEngine.animationPaused(
            reduceMotion: false, sceneActive: false
        ))
        #expect(!TronPulseLoadingIndicatorEngine.animationPaused(
            reduceMotion: false, sceneActive: true
        ))
    }

    @Test("concentric waves are staggered and bounded")
    func pulseGeometry() {
        let progress = (0..<TronPulseLoadingIndicatorEngine.pulseCount).map {
            TronPulseLoadingIndicatorEngine.progress(pulse: $0, time: 0.8)
        }
        #expect(progress.allSatisfy { $0 >= 0 && $0 < 1 })
        #expect(Set(progress).count == TronPulseLoadingIndicatorEngine.pulseCount)

        for value in [-1.0, 0, 0.5, 1, 2] {
            #expect((0.08...1).contains(TronPulseLoadingIndicatorEngine.scale(progress: value)))
            #expect((0...0.62).contains(TronPulseLoadingIndicatorEngine.opacity(progress: value)))
        }
    }
}
