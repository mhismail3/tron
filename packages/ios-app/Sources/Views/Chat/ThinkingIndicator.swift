import SwiftUI

/// Parent view that switches between different thinking indicator animations based on user settings
@available(iOS 26.0, *)
struct AnimatedThinkingLine: View {
    @State private var appearanceSettings = AppearanceSettings.shared

    var body: some View {
        switch appearanceSettings.thinkingIndicatorStyle {
        case .neuralSpark:
            NeuralSparkIndicator()
        case .phaseWaves:
            PhaseWaveIndicator()
        case .orbitingParticles:
            OrbitingParticleIndicator()
        }
    }
}
