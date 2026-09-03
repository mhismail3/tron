import Foundation
import Observation

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
                self.errorMessage = "Pair and enable a Gateway to use Automations."
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

private enum AutomationTimelineTraversalPolicy {
    static let windowDuration: TimeInterval = 7 * 24 * 60 * 60
    static let maximumWindows = 8
    static let maximumPagesPerWindow = 42
    static let maximumRetainedBytes = 2 * 1_048_576
}

@MainActor
@Observable
final class AutomationTimelineCoordinator {
    private(set) var days: [AutomationAgendaDay] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var isStale = false
    private(set) var errorMessage: String?
    private(set) var canLoadMore = true
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var anchor = Date.now
    private var loadedThrough = Date.now
    private var loadedWindowCount = 0
    private var timezone = TimeZone.current
    private let endpoints: @MainActor () -> [AutomationGatewayEndpoint]

    init(endpoints: @escaping @MainActor () -> [AutomationGatewayEndpoint]) {
        self.endpoints = endpoints
    }

    func load(start: Date = .now, timezone: TimeZone = .current) {
        generation &+= 1
        loadTask?.cancel()
        anchor = max(start, .now)
        loadedThrough = anchor
        loadedWindowCount = 0
        self.timezone = timezone
        canLoadMore = true
        startWindow(reset: true)
    }

    func loadNext() {
        guard canLoadMore, !isLoading, !isLoadingMore else { return }
        generation &+= 1
        loadTask?.cancel()
        startWindow(reset: false)
    }

    func cancel() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        isLoadingMore = false
    }

    static func group(_ items: [AutomationTimelineItem], calendar: Calendar, timezone: TimeZone) -> [AutomationAgendaDay] {
        var calendar = calendar
        calendar.timeZone = timezone
        let grouped = Dictionary(grouping: items.compactMap { item -> (Date, AutomationTimelineItem)? in
            guard let date = GatewayTimestamp.parse(item.occurrence.presentationTimestamp) else { return nil }
            return (calendar.startOfDay(for: date), item)
        }, by: { $0.0 })
        return grouped.keys.sorted().map { date in
            let projected: [AutomationTimelineItem] = grouped[date, default: []].map { $0.1 }
            let dayItems = projected.sorted { left, right in
                let leftTimestamp = left.occurrence.presentationTimestamp
                let rightTimestamp = right.occurrence.presentationTimestamp
                if leftTimestamp != rightTimestamp { return leftTimestamp < rightTimestamp }
                return left.id < right.id
            }
            return AutomationAgendaDay(date: date, items: dayItems)
        }
    }

    private func startWindow(reset: Bool) {
        let requestGeneration = generation
        let start = loadedThrough
        let end = start.addingTimeInterval(AutomationTimelineTraversalPolicy.windowDuration)
        isLoading = reset
        isLoadingMore = !reset
        errorMessage = nil
        let requestedEndpoints = Array(endpoints().prefix(128))
        let existing = reset ? [] : days.flatMap(\.items)
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var additions: [AutomationTimelineItem] = []
            var failures: [String] = []
            var loadedAny = false
            var stale = false
            for endpoint in requestedEndpoints {
                guard !Task.isCancelled else { return }
                stale = stale || endpoint.profile.state != .connected
                guard endpoint.profile.capabilities.contains(AutomationAdmissionPolicy.timelineCapability) else {
                    failures.append("\(endpoint.profile.label) requires a Gateway update for Upcoming.")
                    continue
                }
                do {
                    let values = try await self.loadWindow(endpoint: endpoint, from: start, through: end)
                    additions.append(contentsOf: values)
                    loadedAny = true
                } catch is CancellationError {
                    return
                } catch {
                    failures.append("\(endpoint.profile.label): \((error as? GatewayFailure)?.message ?? "Upcoming unavailable")")
                }
            }
            guard !Task.isCancelled, requestGeneration == self.generation else { return }
            if !loadedAny, reset, !self.days.isEmpty {
                self.isStale = true
                self.errorMessage = failures.first ?? "Upcoming is temporarily unavailable. Showing the last bounded agenda."
                self.isLoading = false
                self.isLoadingMore = false
                return
            }
            let merged = existing + additions
            var seen = Set<String>()
            let unique = merged.filter { seen.insert($0.id).inserted }
            let retainedBytes = (try? JSONEncoder().encode(unique.map { $0.occurrence.presentationTimestamp }).count)
                ?? AutomationTimelineTraversalPolicy.maximumRetainedBytes + 1
            guard unique.count <= AutomationAdmissionPolicy.maximumTimelineRetainedCount,
                  retainedBytes <= AutomationTimelineTraversalPolicy.maximumRetainedBytes else {
                self.errorMessage = "Upcoming triggers exceed the iPhone's bounded agenda capacity. Choose a later date or reduce dense schedules."
                self.canLoadMore = false
                self.isLoading = false
                self.isLoadingMore = false
                return
            }
            self.days = Self.group(unique, calendar: Calendar(identifier: .gregorian), timezone: self.timezone)
            self.loadedThrough = end
            self.loadedWindowCount += 1
            self.canLoadMore = self.loadedWindowCount < AutomationTimelineTraversalPolicy.maximumWindows
            self.isStale = stale
            self.errorMessage = loadedAny
                ? (failures.isEmpty ? nil : failures.joined(separator: " "))
                : (failures.first ?? "No Gateway is available for Upcoming.")
            self.isLoading = false
            self.isLoadingMore = false
        }
    }

    private func loadWindow(
        endpoint: AutomationGatewayEndpoint,
        from: Date,
        through: Date
    ) async throws -> [AutomationTimelineItem] {
        for attempt in 0..<2 {
            do {
                var page = try await endpoint.client.timeline(
                    from: from,
                    through: through,
                    timezone: timezone.identifier
                )
                let expectedRevision = page.catalogRevision
                var items: [AutomationTimelineItem] = []
                var seenIDs = Set<String>()
                var seenCursors = Set<String>()
                var pages = 0
                while true {
                    pages += 1
                    guard pages <= AutomationTimelineTraversalPolicy.maximumPagesPerWindow,
                          page.catalogRevision == expectedRevision,
                          items.count <= AutomationAdmissionPolicy.maximumTimelineRetainedCount - page.items.count else {
                        throw GatewayFailure(code: "conflict", message: "Upcoming changed while loading.", retryable: true, details: nil)
                    }
                    for occurrence in page.items {
                        let item = AutomationTimelineItem(profileID: endpoint.profile.id, occurrence: occurrence)
                        guard seenIDs.insert(item.id).inserted else {
                            throw GatewayFailure(code: "invalid_response", message: "Upcoming contains a duplicate occurrence.", retryable: false, details: nil)
                        }
                        items.append(item)
                    }
                    guard let cursor = page.nextCursor else { return items }
                    guard seenCursors.insert(cursor).inserted else {
                        throw GatewayFailure(code: "invalid_response", message: "Upcoming returned a repeated cursor.", retryable: false, details: nil)
                    }
                    page = try await endpoint.client.timeline(
                        from: from,
                        through: through,
                        timezone: timezone.identifier,
                        cursor: cursor
                    )
                }
            } catch let failure as GatewayFailure where attempt == 0 && failure.retryable {
                continue
            }
        }
        throw GatewayFailure(code: "conflict", message: "Upcoming kept changing while loading. Try again.", retryable: true, details: nil)
    }
}
