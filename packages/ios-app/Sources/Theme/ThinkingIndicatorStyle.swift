import SwiftUI

/// Animation style for the thinking indicator shown during agent processing
enum ThinkingIndicatorStyle: String, CaseIterable, Sendable, Identifiable {
    case neuralSpark
    case fluidMercury
    case phaseWaves
    case orbitingParticles

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .neuralSpark: return "Neural Spark"
        case .fluidMercury: return "Fluid Mercury"
        case .phaseWaves: return "Phase Waves"
        case .orbitingParticles: return "Orbiting Particles"
        }
    }

    var icon: String {
        switch self {
        case .neuralSpark: return "waveform.path"
        case .fluidMercury: return "drop.fill"
        case .phaseWaves: return "waveform"
        case .orbitingParticles: return "smallcircle.filled.circle"
        }
    }
}
