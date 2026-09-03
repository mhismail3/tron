import Foundation
import Observation

struct AutomationGatewayEndpoint: Identifiable, Sendable {
    let profile: AutomationDashboardProfile
    let client: AutomationRPCClient
    var id: String { profile.id }
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
    private let endpoints: @MainActor () -> [AutomationGatewayEndpoint]

    func endpoint(for profileID: String) -> AutomationGatewayEndpoint? {
        endpoints().first { $0.id == profileID }
    }

    func allEndpoints() -> [AutomationGatewayEndpoint] { endpoints() }

    init(endpoints: @escaping @MainActor () -> [AutomationGatewayEndpoint]) {
        self.endpoints = endpoints
    }

    var summaries: [(profile: AutomationDashboardProfile, summary: GatewayAutomationSummary)] {
        buckets.flatMap { bucket in bucket.summaries.map { (bucket.profile, $0) } }
    }

    func reload() {
        generation &+= 1
        let requestGeneration = generation
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        let endpoints = self.endpoints()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var next: [AutomationProfileCatalog] = []
            await withTaskGroup(of: AutomationProfileCatalog.self) { group in
                for endpoint in endpoints {
                    group.addTask {
                        do {
                            let status = try await endpoint.client.status()
                            guard endpoint.profile.capabilities.contains(AutomationAdmissionPolicy.capability) else {
                                return AutomationProfileCatalog(profile: endpoint.profile, failure: "This Gateway does not support Automations.")
                            }
                            var page = try await endpoint.client.list()
                            var summaries = page.items
                            var seen = Set(summaries.map(\.id))
                            var cursor = page.nextCursor
                            var pages = 1
                            while let nextCursor = cursor, pages < 16 {
                                page = try await endpoint.client.list(cursor: nextCursor)
                                guard page.catalogRevision == status.catalogRevision else {
                                    throw GatewayFailure(code: "conflict", message: "Automations changed while loading.", retryable: true, details: nil)
                                }
                                let newItems = page.items.filter { seen.insert($0.id).inserted }
                                summaries.append(contentsOf: newItems)
                                cursor = page.nextCursor
                                pages += 1
                            }
                            return AutomationProfileCatalog(profile: endpoint.profile, catalogRevision: status.catalogRevision, summaries: summaries)
                        } catch is CancellationError {
                            return AutomationProfileCatalog(profile: endpoint.profile, failure: "Loading cancelled.")
                        } catch {
                            return AutomationProfileCatalog(profile: endpoint.profile, failure: (error as? GatewayFailure)?.message ?? "Unable to load Automations.")
                        }
                    }
                }
                for await bucket in group { next.append(bucket) }
            }
            guard !Task.isCancelled, requestGeneration == self.generation else { return }
            self.buckets = next.sorted { $0.profile.label.localizedStandardCompare($1.profile.label) == .orderedAscending }
            self.hasLoaded = true
            self.isLoading = false
            let failures = next.compactMap(\.failure)
            self.errorMessage = failures.count == next.count ? failures.first : nil
        }
    }

    func invalidate(profileID: String? = nil) {
        if let profileID, let index = buckets.firstIndex(where: { $0.id == profileID }) {
            buckets[index].failure = nil
        }
        reload()
    }

    func cancel() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
    }
}

@MainActor
@Observable
final class AutomationTimelineCoordinator {
    private(set) var days: [AutomationAgendaDay] = []
    private(set) var isLoading = false
    private(set) var isStale = false
    private(set) var errorMessage: String?
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private let endpoints: @MainActor () -> [AutomationGatewayEndpoint]

    init(endpoints: @escaping @MainActor () -> [AutomationGatewayEndpoint]) { self.endpoints = endpoints }

    func load(start: Date = .now, timezone: TimeZone = .current) {
        generation &+= 1
        let requestGeneration = generation
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        let end = Calendar(identifier: .gregorian).date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86_400)
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let endpoints = self.endpoints()
            var items: [AutomationTimelineItem] = []
            var failures: [String] = []
            var loadedAny = false
            var stale = false
            for endpoint in endpoints {
                guard !Task.isCancelled else { return }
                stale = stale || endpoint.profile.state != .connected
                guard endpoint.profile.capabilities.contains(AutomationAdmissionPolicy.timelineCapability) else {
                    failures.append("\(endpoint.profile.label) requires a Gateway update for Upcoming.")
                    continue
                }
                do {
                    var page = try await endpoint.client.timeline(from: start, through: end, timezone: timezone.identifier)
                    let catalogRevision = page.catalogRevision
                    items.append(contentsOf: page.items.map { AutomationTimelineItem(profileID: endpoint.profile.id, occurrence: $0) })
                    var cursor = page.nextCursor
                    var pages = 1
                    while let next = cursor, pages < 4 {
                        page = try await endpoint.client.timeline(from: start, through: end, timezone: timezone.identifier, cursor: next)
                        guard page.catalogRevision == catalogRevision else { break }
                        items.append(contentsOf: page.items.map { AutomationTimelineItem(profileID: endpoint.profile.id, occurrence: $0) })
                        cursor = page.nextCursor
                        pages += 1
                    }
                    loadedAny = true
                } catch is CancellationError { return }
                catch { failures.append("\(endpoint.profile.label): \((error as? GatewayFailure)?.message ?? "Upcoming unavailable")") }
            }
            guard requestGeneration == self.generation else { return }
            self.days = AutomationTimelineCoordinator.group(items, calendar: Calendar(identifier: .gregorian), timezone: timezone)
            self.isStale = stale
            self.errorMessage = loadedAny ? (failures.isEmpty ? nil : failures.joined(separator: " ")) : (failures.first ?? "No Gateway is available for Upcoming.")
            self.isLoading = false
        }
    }

    static func group(_ items: [AutomationTimelineItem], calendar: Calendar, timezone: TimeZone) -> [AutomationAgendaDay] {
        var calendar = calendar
        calendar.timeZone = timezone
        let grouped = Dictionary(grouping: items.compactMap { item -> (Date, AutomationTimelineItem)? in
            guard let date = GatewayTimestamp.parse(item.occurrence.scheduledFor) else { return nil }
            return (calendar.startOfDay(for: date), item)
        }, by: { $0.0 })
        return grouped.keys.sorted().map { date in
            let dayItems: [AutomationTimelineItem] = grouped[date, default: []].map { $0.1 }.sorted { $0.occurrence.scheduledFor < $1.occurrence.scheduledFor }
            return AutomationAgendaDay(date: date, items: dayItems)
        }
    }

    func cancel() { generation &+= 1; loadTask?.cancel(); loadTask = nil }
}
