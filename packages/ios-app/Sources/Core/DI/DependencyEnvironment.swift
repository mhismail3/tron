import SwiftUI

// MARK: - Environment Key

/// Environment key for accessing the dependency container
private struct DependencyContainerKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue: DependencyContainer = DependencyContainer()
}

extension EnvironmentValues {
    /// Access the dependency container from the environment
    var dependencies: DependencyContainer {
        get { self[DependencyContainerKey.self] }
        set { self[DependencyContainerKey.self] = newValue }
    }
}

// MARK: - View Extensions

extension View {
    /// Inject dependencies into the view hierarchy
    func withDependencies(_ container: DependencyContainer) -> some View {
        self.environment(\.dependencies, container)
    }
}
