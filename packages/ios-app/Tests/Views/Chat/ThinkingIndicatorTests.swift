import XCTest
@testable import TronMobile

@available(iOS 26.0, *)
@MainActor
final class AnimatedThinkingLineTests: XCTestCase {

    // MARK: - Parent AnimatedThinkingLine Tests

    func testInstantiationNeuralSpark() {
        let settings = AppearanceSettings.shared
        let originalStyle = settings.thinkingIndicatorStyle
        settings.thinkingIndicatorStyle = .neuralSpark

        let view = AnimatedThinkingLine()
        XCTAssertNotNil(view)

        settings.thinkingIndicatorStyle = originalStyle
    }

    func testInstantiationFluidMercury() {
        let settings = AppearanceSettings.shared
        let originalStyle = settings.thinkingIndicatorStyle
        settings.thinkingIndicatorStyle = .fluidMercury

        let view = AnimatedThinkingLine()
        XCTAssertNotNil(view)

        settings.thinkingIndicatorStyle = originalStyle
    }

    func testInstantiationPhaseWaves() {
        let settings = AppearanceSettings.shared
        let originalStyle = settings.thinkingIndicatorStyle
        settings.thinkingIndicatorStyle = .phaseWaves

        let view = AnimatedThinkingLine()
        XCTAssertNotNil(view)

        settings.thinkingIndicatorStyle = originalStyle
    }

    func testInstantiationOrbitingParticles() {
        let settings = AppearanceSettings.shared
        let originalStyle = settings.thinkingIndicatorStyle
        settings.thinkingIndicatorStyle = .orbitingParticles

        let view = AnimatedThinkingLine()
        XCTAssertNotNil(view)

        settings.thinkingIndicatorStyle = originalStyle
    }

    // MARK: - Individual Indicator View Tests

    func testNeuralSparkIndicatorInstantiates() {
        let view = NeuralSparkIndicator()
        XCTAssertNotNil(view)
    }

    func testFluidMercuryIndicatorInstantiates() {
        let view = FluidMercuryIndicator()
        XCTAssertNotNil(view)
    }

    func testPhaseWaveIndicatorInstantiates() {
        let view = PhaseWaveIndicator()
        XCTAssertNotNil(view)
    }

    func testOrbitingParticleIndicatorInstantiates() {
        let view = OrbitingParticleIndicator()
        XCTAssertNotNil(view)
    }
}
