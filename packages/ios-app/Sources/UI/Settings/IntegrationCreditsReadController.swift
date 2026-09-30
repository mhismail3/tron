import Foundation
import Observation
import TronMobileCore

/// Owns the disposable X balance presentation read; no result outlives its exact
/// profile identity, mounted sheet, or latest request.
@MainActor
@Observable
final class IntegrationCreditsReadController {
    private(set) var balances: [String: IntegrationXCredits] = [:]
    private(set) var loadingIDs: Set<String> = []
    private(set) var requestGeneration = 0
    private var activeRequests: [String: Int] = [:]

    func begin(clear: Bool = false) {
        requestGeneration &+= 1
        activeRequests.removeAll()
        loadingIDs.removeAll()
        if clear { balances.removeAll() }
    }

    func read(
        instance: IntegrationInstance,
        identity: KnowledgePresentationIdentity,
        client: IntegrationsRPCClient,
        presentationActive: @escaping @MainActor () -> Bool,
        currentIdentity: @escaping @MainActor () -> KnowledgePresentationIdentity
    ) async {
        guard instance.definitionId == "knowledge.x", instance.health == "ready",
              presentationActive(), !Task.isCancelled else { return }
        requestGeneration &+= 1
        let ticket = requestGeneration
        activeRequests[instance.id] = ticket
        loadingIDs.insert(instance.id)
        func admits() -> Bool {
            !Task.isCancelled && activeRequests[instance.id] == ticket
                && identity == currentIdentity() && presentationActive()
        }
        defer {
            if admits() { loadingIDs.remove(instance.id); activeRequests[instance.id] = nil }
        }
        do {
            let value = try await client.xCredits(connectionID: instance.id)
            guard admits() else { return }
            balances[instance.id] = value
        } catch {
            guard admits() else { return }
            balances[instance.id] = nil
        }
    }
}
