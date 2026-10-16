import Foundation
import Observation
import TronMobileCore

struct AutomationGatewayEndpoint: Identifiable, Sendable {
    let profile: AutomationDashboardProfile
    let client: AutomationRPCClient
    var id: String { profile.id }
}

private enum AutomationCatalogTraversalPolicy {
    static let maximumPages = 16
    static let maximumProfiles = 128
    static let maximumRetainedItems = 4_096
    static let maximumRetainedBytes = 8 * 1_048_576
}

@MainActor
@Observable
final class AutomationCatalogCoordinator {
    private(set) var buckets: [AutomationProfileCatalog] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var isActive = false
    private var isDirty = true
    private let endpoints: @MainActor () -> [AutomationGatewayEndpoint]

    init(endpoints: @escaping @MainActor () -> [AutomationGatewayEndpoint]) {
        self.endpoints = endpoints
    }

    var summaries: [(profile: AutomationDashboardProfile, summary: GatewayAutomationSummary)] {
        buckets.flatMap { bucket in bucket.summaries.map { (bucket.profile, $0) } }
    }

    func endpoint(for profileID: String) -> AutomationGatewayEndpoint? {
        endpoints().first { $0.id == profileID }
    }

    func allEndpoints() -> [AutomationGatewayEndpoint] {
        Array(endpoints().prefix(AutomationCatalogTraversalPolicy.maximumProfiles))
    }

    func activate() {
        isActive = true
        if isDirty || !hasLoaded { reload() }
    }

    func deactivate() {
        isActive = false
        isDirty = true
        cancel()
    }

    func reload() {
        isDirty = false
        generation &+= 1
        let requestGeneration = generation
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        let requestedEndpoints = allEndpoints()
        let previous = Dictionary(uniqueKeysWithValues: buckets.map { ($0.id, $0) })
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !requestedEndpoints.isEmpty else {
                self.buckets = []
                self.hasLoaded = true
                self.isLoading = false
                self.errorMessage = nil
                return
            }
            var next: [AutomationProfileCatalog] = []
            next.reserveCapacity(requestedEndpoints.count)
            for endpoint in requestedEndpoints {
                guard !Task.isCancelled else { return }
                let loaded = await self.load(endpoint)
                if loaded.failure != nil, let retained = previous[endpoint.id], !retained.summaries.isEmpty {
                    next.append(AutomationProfileCatalog(
                        profile: endpoint.profile,
                        catalogRevision: retained.catalogRevision,
                        summaries: retained.summaries,
                        failure: loaded.failure
                    ))
                } else {
                    next.append(loaded)
                }
            }
            guard !Task.isCancelled, requestGeneration == self.generation else { return }
            let totalCount = next.reduce(0) { $0 + $1.summaries.count }
            let totalBytes = next.reduce(0) { result, bucket in
                result + ((try? JSONEncoder().encode(bucket.summaries).count) ?? AutomationCatalogTraversalPolicy.maximumRetainedBytes + 1)
            }
            guard totalCount <= AutomationCatalogTraversalPolicy.maximumRetainedItems,
                  totalBytes <= AutomationCatalogTraversalPolicy.maximumRetainedBytes else {
                self.errorMessage = "The combined Automation catalog exceeds the iPhone's bounded display capacity. Filter or remove Automations on a Gateway."
                self.hasLoaded = true
                self.isLoading = false
                return
            }
            self.buckets = next.sorted {
                $0.profile.label.localizedStandardCompare($1.profile.label) == .orderedAscending
            }
            self.hasLoaded = true
            self.isLoading = false
            let failures = next.compactMap(\.failure)
            self.errorMessage = failures.count == next.count && !next.isEmpty ? failures.first : nil
        }
    }

    func invalidate(profileID: String? = nil) {
        isDirty = true
        if let profileID, let index = buckets.firstIndex(where: { $0.id == profileID }) {
            buckets[index].failure = nil
        }
        if isActive { reload() }
    }

    func cancel() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    private func load(_ endpoint: AutomationGatewayEndpoint) async -> AutomationProfileCatalog {
        guard endpoint.profile.capabilities.contains(AutomationAdmissionPolicy.capability) else {
            return AutomationProfileCatalog(
                profile: endpoint.profile,
                failure: "\(endpoint.profile.label) requires a Gateway update for Automations."
            )
        }
        do {
            let status = try await endpoint.client.status()
            guard status.ready else {
                return AutomationProfileCatalog(profile: endpoint.profile, failure: "Automations are still recovering on \(endpoint.profile.label).")
            }
            for attempt in 0..<2 {
                do {
                    var page = try await endpoint.client.list()
                    let expectedRevision = page.catalogRevision
                    var summaries: [GatewayAutomationSummary] = []
                    summaries.reserveCapacity(min(status.automationCount, AutomationAdmissionPolicy.maximumRetainedCount))
                    var seenIDs = Set<String>()
                    var seenCursors = Set<String>()
                    var pageCount = 0
                    var retainedBytes = 0
                    while true {
                        pageCount += 1
                        guard pageCount <= AutomationCatalogTraversalPolicy.maximumPages,
                              page.catalogRevision == expectedRevision,
                              summaries.count <= AutomationAdmissionPolicy.maximumRetainedCount - page.items.count else {
                            throw GatewayFailure(code: "conflict", message: "Automations changed while loading.", retryable: true, details: nil)
                        }
                        let pageBytes = try JSONEncoder().encode(page.items).count
                        guard retainedBytes <= AutomationAdmissionPolicy.maximumAggregateBytes - pageBytes else {
                            throw GatewayFailure(code: "invalid_response", message: "The Automation catalog exceeds its bounded display capacity.", retryable: false, details: nil)
                        }
                        retainedBytes += pageBytes
                        for summary in page.items {
                            guard seenIDs.insert(summary.id).inserted else {
                                throw GatewayFailure(code: "invalid_response", message: "The Automation catalog contains a duplicate identity.", retryable: false, details: nil)
                            }
                            summaries.append(summary)
                        }
                        guard let cursor = page.nextCursor else { break }
                        guard seenCursors.insert(cursor).inserted else {
                            throw GatewayFailure(code: "invalid_response", message: "The Automation catalog cursor repeated.", retryable: false, details: nil)
                        }
                        page = try await endpoint.client.list(cursor: cursor)
                    }
                    guard summaries.count == status.automationCount || status.catalogRevision != expectedRevision else {
                        throw GatewayFailure(code: "invalid_response", message: "The Automation catalog ended before every definition was returned.", retryable: true, details: nil)
                    }
                    return AutomationProfileCatalog(
                        profile: endpoint.profile,
                        catalogRevision: expectedRevision,
                        summaries: summaries,
                        failure: status.degraded ? "Some malformed Automation records were quarantined on this Gateway." : nil
                    )
                } catch let failure as GatewayFailure where attempt == 0 && failure.retryable {
                    continue
                }
            }
            throw GatewayFailure(code: "conflict", message: "Automations kept changing while loading. Try again.", retryable: true, details: nil)
        } catch is CancellationError {
            return AutomationProfileCatalog(profile: endpoint.profile, failure: "Loading cancelled.")
        } catch {
            return AutomationProfileCatalog(
                profile: endpoint.profile,
                failure: (error as? GatewayFailure)?.message ?? "Unable to load Automations from \(endpoint.profile.label)."
            )
        }
    }
}
