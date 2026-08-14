import Foundation

enum MacCommandModeGatewayStartResult: Equatable, Sendable {
    case ok
    case busy
    case failed(GatewayLifecycleFailure)
}

enum MacCommandModeGatewayStarter {
    static func start(
        coordinator: GatewayLifecycleCoordinator
    ) async -> MacCommandModeGatewayStartResult {
        switch await coordinator.perform(.start) {
        case .succeeded:
            .ok
        case .busy:
            .busy
        case .failed(let failure):
            .failed(failure)
        case .needsOnboarding:
            .failed(.stateReadFailed)
        }
    }
}
