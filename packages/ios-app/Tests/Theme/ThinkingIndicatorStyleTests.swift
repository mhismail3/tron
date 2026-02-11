import Testing
import SwiftUI
@testable import TronMobile

@MainActor
struct ThinkingIndicatorStyleTests {

    // MARK: - ThinkingIndicatorStyle

    @Test func rawValues() {
        #expect(ThinkingIndicatorStyle.neuralSpark.rawValue == "neuralSpark")
        #expect(ThinkingIndicatorStyle.fluidMercury.rawValue == "fluidMercury")
        #expect(ThinkingIndicatorStyle.phaseWaves.rawValue == "phaseWaves")
        #expect(ThinkingIndicatorStyle.orbitingParticles.rawValue == "orbitingParticles")
    }

    @Test func allCasesOrder() {
        #expect(ThinkingIndicatorStyle.allCases == [.neuralSpark, .fluidMercury, .phaseWaves, .orbitingParticles])
        #expect(ThinkingIndicatorStyle.allCases.count == 4)
    }

    @Test func displayNames() {
        #expect(ThinkingIndicatorStyle.neuralSpark.displayName == "Neural Spark")
        #expect(ThinkingIndicatorStyle.fluidMercury.displayName == "Fluid Mercury")
        #expect(ThinkingIndicatorStyle.phaseWaves.displayName == "Phase Waves")
        #expect(ThinkingIndicatorStyle.orbitingParticles.displayName == "Orbiting Particles")
    }

    @Test func icons() {
        #expect(ThinkingIndicatorStyle.neuralSpark.icon == "waveform.path")
        #expect(ThinkingIndicatorStyle.fluidMercury.icon == "drop.fill")
        #expect(ThinkingIndicatorStyle.phaseWaves.icon == "waveform")
        #expect(ThinkingIndicatorStyle.orbitingParticles.icon == "smallcircle.filled.circle")
    }

    @Test func rawValueRoundTrip() {
        for style in ThinkingIndicatorStyle.allCases {
            let parsed = ThinkingIndicatorStyle(rawValue: style.rawValue)
            #expect(parsed == style)
        }
    }

    @Test func unknownRawValueReturnsNil() {
        let parsed = ThinkingIndicatorStyle(rawValue: "garbage")
        #expect(parsed == nil)
    }

    @Test func defaultIsNeuralSpark() {
        // Clear any stored value
        UserDefaults.standard.removeObject(forKey: "thinkingIndicatorStyle")
        // Verify the default logic
        let style = ThinkingIndicatorStyle(rawValue: UserDefaults.standard.string(forKey: "thinkingIndicatorStyle") ?? "") ?? .neuralSpark
        #expect(style == .neuralSpark)
    }

    @Test func persistsToUserDefaults() {
        let settings = AppearanceSettings.shared
        let originalStyle = settings.thinkingIndicatorStyle

        settings.thinkingIndicatorStyle = .fluidMercury
        #expect(UserDefaults.standard.string(forKey: "thinkingIndicatorStyle") == "fluidMercury")

        settings.thinkingIndicatorStyle = .phaseWaves
        #expect(UserDefaults.standard.string(forKey: "thinkingIndicatorStyle") == "phaseWaves")

        settings.thinkingIndicatorStyle = .orbitingParticles
        #expect(UserDefaults.standard.string(forKey: "thinkingIndicatorStyle") == "orbitingParticles")

        settings.thinkingIndicatorStyle = .neuralSpark
        #expect(UserDefaults.standard.string(forKey: "thinkingIndicatorStyle") == "neuralSpark")

        // Restore
        settings.thinkingIndicatorStyle = originalStyle
    }
}
