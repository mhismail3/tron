import Foundation
import Observation

/// Owns only the presentation lifecycle of one bounded provider-usage read.
/// Runtime authority and caching remain in the Gateway; this owner rejects late
/// results when the target, profile, foreground lease, or mounted surface changes.
struct ProviderUsageReadIdentity: Equatable, Sendable {
    let target: ProviderCatalogTarget
    let providerID: String?
    let profileRevision: Int
    let profileID: String?
    let invalidationGeneration: Int
    let foregroundGeneration: Int
    let requestGeneration: Int
    let presentationActive: Bool
}

@MainActor
@Observable
final class ProviderUsageReadController {
    private(set) var snapshots: [String: ProviderUsageSnapshot] = [:]
    private(set) var isLoading = false
    private(set) var didFail = false
    private(set) var requestGeneration = 0
    private var activeIdentity: ProviderUsageReadIdentity?

    func begin(clear: Bool = false) {
        requestGeneration &+= 1
        reset(clear: clear)
    }

    func reset(clear: Bool = false) {
        activeIdentity = nil
        if clear { snapshots = [:] }
        isLoading = false
        didFail = false
    }

    func read(
        identity: ProviderUsageReadIdentity,
        fetch: @escaping @MainActor () async throws -> ProviderUsageResponse,
        current: @escaping @MainActor () -> Bool
    ) async {
        guard identity.presentationActive, !Task.isCancelled else { return }
        activeIdentity = identity
        isLoading = true
        didFail = false
        defer {
            if admitted(identity, current: current) { isLoading = false }
        }
        do {
            let response = try await fetch()
            guard admitted(identity, current: current) else { return }
            snapshots = Dictionary(uniqueKeysWithValues: response.providers.map { ($0.providerId, $0) })
        } catch is CancellationError {
            return
        } catch {
            guard admitted(identity, current: current) else { return }
            didFail = true
        }
    }

    private func admitted(
        _ identity: ProviderUsageReadIdentity,
        current: @MainActor () -> Bool
    ) -> Bool {
        !Task.isCancelled
            && activeIdentity == identity
            && identity.presentationActive
            && current()
    }
}
