import AppKit
import Foundation
import Observation

enum GatewayAppMode: Equatable {
    case loading
    case onboarding
    case menuBarOnly
}

/// Process-local owner shared by AppKit lifecycle and SwiftUI presentation.
/// Durable completion remains in `GatewayStatePersisting`.
@MainActor
@Observable
final class GatewayAppContext {
    let dependencies: GatewayDependencies
    let coordinator: GatewayLifecycleCoordinator
    var mode: GatewayAppMode = .loading
    var onboardingError: GatewayLifecycleFailure?
    var onMenuBarRequested: (() -> Void)?

    private var started = false

    init(dependencies: GatewayDependencies = .live) {
        self.dependencies = dependencies
        self.coordinator = GatewayLifecycleCoordinator(dependencies: dependencies)
    }

    func start() async {
        guard !started else { return }
        started = true
        switch dependencies.stateStore.read() {
        case .missing:
            mode = .onboarding
        case .corrupt:
            onboardingError = .stateReadFailed
            mode = .onboarding
        case .valid(let state) where !state.onboardingCompleted:
            mode = .onboarding
        case .valid:
            mode = .menuBarOnly
            onMenuBarRequested?()
            _ = await coordinator.perform(.reconcileForLaunch)
        }
    }

    func completeOnboarding() async -> GatewayLifecycleFailure? {
        onboardingError = nil
        switch await coordinator.perform(.completeOnboarding) {
        case .succeeded:
            mode = .menuBarOnly
            onMenuBarRequested?()
            return nil
        case .failed(let failure):
            onboardingError = failure
            return failure
        case .busy:
            onboardingError = .serviceFailed
            return .serviceFailed
        case .needsOnboarding:
            onboardingError = .stateReadFailed
            return .stateReadFailed
        }
    }
}
