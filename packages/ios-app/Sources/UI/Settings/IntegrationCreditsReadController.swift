import Foundation
import Observation
import TronMobileCore

/// Owns disposable X balance reads; cancelling a batch also releases every pending row.
@MainActor
@Observable
final class IntegrationCreditsReadController {
    private(set) var balances: [String: IntegrationXCredits] = [:]
    private(set) var loadingIDs: Set<String> = []
    private(set) var requestGeneration = 0
    private var loop: Task<Void, Never>?
    private var activeRequests: [String: Int] = [:]

    func begin(clear: Bool = false) {
        requestGeneration &+= 1
        loop?.cancel()
        loop = nil
        activeRequests.removeAll()
        loadingIDs.removeAll()
        if clear { balances.removeAll() }
    }

    func start(
        instances: [IntegrationInstance],
        identity: KnowledgePresentationIdentity,
        client: IntegrationsRPCClient,
        presentationActive: @escaping @MainActor () -> Bool,
        currentIdentity: @escaping @MainActor () -> KnowledgePresentationIdentity
    ) {
        begin(clear: true)
        let ticket = requestGeneration
        loop = Task { @MainActor in
            for instance in instances where instance.definitionId == "knowledge.x" && instance.health == "ready" {
                guard admits(ticket, identity: identity, presentationActive: presentationActive, currentIdentity: currentIdentity) else { return }
                await read(instance: instance, ticket: ticket, identity: identity, client: client,
                           presentationActive: presentationActive, currentIdentity: currentIdentity)
            }
            if requestGeneration == ticket { loop = nil }
        }
    }

    private func read(
        instance: IntegrationInstance,
        ticket: Int,
        identity: KnowledgePresentationIdentity,
        client: IntegrationsRPCClient,
        presentationActive: @escaping @MainActor () -> Bool,
        currentIdentity: @escaping @MainActor () -> KnowledgePresentationIdentity
    ) async {
        guard instance.definitionId == "knowledge.x", instance.health == "ready",
              admits(ticket, identity: identity, presentationActive: presentationActive, currentIdentity: currentIdentity) else { return }
        activeRequests[instance.id] = ticket
        loadingIDs.insert(instance.id)
        func requestAdmits() -> Bool {
            admits(ticket, identity: identity, presentationActive: presentationActive, currentIdentity: currentIdentity)
                && activeRequests[instance.id] == ticket
        }
        defer {
            if requestGeneration == ticket && activeRequests[instance.id] == ticket {
                loadingIDs.remove(instance.id)
                activeRequests[instance.id] = nil
            }
        }
        do {
            guard requestAdmits() else { return }
            let value = try await client.xCredits(connectionID: instance.id)
            guard requestAdmits() else { return }
            balances[instance.id] = value
        } catch {
            guard requestAdmits() else { return }
            balances[instance.id] = nil
        }
    }

    private func admits(
        _ ticket: Int,
        identity: KnowledgePresentationIdentity,
        presentationActive: @escaping @MainActor () -> Bool,
        currentIdentity: @escaping @MainActor () -> KnowledgePresentationIdentity
    ) -> Bool {
        !Task.isCancelled && requestGeneration == ticket && identity == currentIdentity() && presentationActive()
    }
}
