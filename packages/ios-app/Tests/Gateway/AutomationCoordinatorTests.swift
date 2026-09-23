import Foundation
import Testing
@testable import TronMobile

@MainActor
private final class AutomationRequestScript {
    var requests: [(String, JSONValue)] = []
    var handler: (String, JSONValue) throws -> JSONValue

    init(handler: @escaping (String, JSONValue) throws -> JSONValue) {
        self.handler = handler
    }

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        requests.append((method, params))
        return try handler(method, params)
    }
}

@MainActor
private final class DeferredTimelineRequest {
    var calls = 0
    var finished = 0
    var returnedFromCancelledTask = false
    var continuation: CheckedContinuation<JSONValue, Error>?

    func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        calls += 1
        defer {
            finished += 1
            returnedFromCancelledTask = Task.isCancelled
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(_ result: Result<JSONValue, Error>) {
        let current = continuation
        continuation = nil
        current?.resume(with: result)
    }
}

@Suite("Automation catalog ownership")
@MainActor
struct AutomationCoordinatorTests {
    @Test("timeline admission changes only for endpoint, connection, capability, or revision facts")
    func timelineAdmissionKey() {
        let base = AutomationTimelineAdmissionKey.Endpoint(
            profileID: "profile", connectionID: 7, state: .connected,
            capabilities: [AutomationAdmissionPolicy.capability, AutomationAdmissionPolicy.timelineCapability],
            catalogRevision: 3
        )
        let same = AutomationTimelineAdmissionKey(endpoints: [base])
        #expect(same == AutomationTimelineAdmissionKey(endpoints: [base]))
        #expect(same != AutomationTimelineAdmissionKey(endpoints: [
            .init(profileID: "profile", connectionID: 8, state: .connected, capabilities: base.capabilities, catalogRevision: 3)
        ]))
        #expect(same != AutomationTimelineAdmissionKey(endpoints: [
            .init(profileID: "profile", connectionID: 7, state: .connected, capabilities: base.capabilities, catalogRevision: 4)
        ]))
        #expect(same != AutomationTimelineAdmissionKey(endpoints: [
            .init(profileID: "profile", connectionID: 7, state: .connected, capabilities: [AutomationAdmissionPolicy.capability], catalogRevision: 3)
        ]))
    }

    @Test("only connected compatible Gateways enter Automation projections")
    func endpointAdmission() {
        let connected = profile()
        let disconnected = AutomationDashboardProfile(
            id: "profile-two",
            label: "Offline",
            state: .offline,
            capabilities: [AutomationAdmissionPolicy.capability, AutomationAdmissionPolicy.timelineCapability]
        )
        let outdated = AutomationDashboardProfile(
            id: "profile-three",
            label: "Outdated",
            state: .connected,
            capabilities: []
        )
        #expect(AutomationEndpointAdmissionPolicy.admits(connected))
        #expect(AutomationEndpointAdmissionPolicy.admitsTimeline(connected))
        #expect(!AutomationEndpointAdmissionPolicy.admits(disconnected))
        #expect(!AutomationEndpointAdmissionPolicy.admits(outdated))
        #expect(!AutomationEndpointAdmissionPolicy.admitsTimeline(outdated))
    }

    @Test("timeline loading retains stable content and delays compact refresh activity")
    func timelineLoadingPresentation() {
        #expect(AutomationTimelinePresentationPolicy.showsInitialLoading(
            mode: .all,
            catalogHasLoaded: false,
            timelineAvailable: false,
            timelineIsLoading: false,
            visibleDayCount: 0
        ))
        #expect(!AutomationTimelinePresentationPolicy.showsInitialLoading(
            mode: .all,
            catalogHasLoaded: true,
            timelineAvailable: false,
            timelineIsLoading: false,
            visibleDayCount: 0
        ))
        #expect(AutomationTimelinePresentationPolicy.showsInitialLoading(
            mode: .upcoming,
            catalogHasLoaded: true,
            timelineAvailable: true,
            timelineIsLoading: true,
            visibleDayCount: 0
        ))
        #expect(!AutomationTimelinePresentationPolicy.showsInitialLoading(
            mode: .upcoming,
            catalogHasLoaded: true,
            timelineAvailable: true,
            timelineIsLoading: true,
            visibleDayCount: 1
        ))
        #expect(AutomationTimelinePresentationPolicy.showsEmptyState(visibleDayCount: 0))
        #expect(!AutomationTimelinePresentationPolicy.showsEmptyState(visibleDayCount: 1))
        #expect(AutomationTimelinePresentationPolicy.emptyStateHeight(
            viewportHeight: 800,
            hasAttentionBanner: false
        ) == 696)
        #expect(AutomationTimelinePresentationPolicy.emptyStateHeight(
            viewportHeight: 800,
            hasAttentionBanner: true
        ) == 280)
        #expect(AutomationTimelinePresentationPolicy.emptyStateHeight(
            viewportHeight: 300,
            hasAttentionBanner: false
        ) == 280)
        #expect(!AutomationTimelinePresentationPolicy.showsRefreshIndicator(
            isLoading: true,
            delayElapsed: false
        ))
        #expect(AutomationTimelinePresentationPolicy.showsRefreshIndicator(
            isLoading: true,
            delayElapsed: true
        ))
        #expect(!AutomationTimelinePresentationPolicy.showsRefreshIndicator(
            isLoading: false,
            delayElapsed: true
        ))
        #expect(!AutomationTimelinePresentationPolicy.showsInventoryFilters(mode: .upcoming))
        #expect(AutomationTimelinePresentationPolicy.showsInventoryFilters(mode: .all))
    }

    @Test("no eligible Gateway produces a neutral empty projection")
    func emptyProjectionIsNeutral() async throws {
        let catalog = AutomationCatalogCoordinator(endpoints: { [] })
        catalog.activate()
        try await eventually { catalog.hasLoaded && !catalog.isLoading }
        #expect(catalog.buckets.isEmpty)
        #expect(catalog.errorMessage == nil)

        let timeline = AutomationTimelineCoordinator(endpoints: { [] })
        timeline.load()
        try await eventually { !timeline.isLoading }
        #expect(timeline.days.isEmpty)
        #expect(timeline.errorMessage == nil)
        #expect(!timeline.canLoadMore)
    }

    @Test("inactive invalidations defer reads and activation traverses one exact catalog revision")
    func deferredInvalidationAndTraversal() async throws {
        let first = automationSummary(id: "automation-one", name: "One")
        let second = automationSummary(id: "automation-two", name: "Two")
        let script = AutomationRequestScript { method, params in
            switch method {
            case "automation.status":
                return .object([
                    "ready": .bool(true), "degraded": .bool(false), "automationCount": .number(2),
                    "aggregateBytes": .number(1_024), "malformedRecordCount": .number(0), "catalogRevision": .number(7),
                ])
            case "automation.list":
                if params.objectValue?["cursor"] == .string("next-page") {
                    return .object(["catalogRevision": .number(7), "items": .array([second])])
                }
                return .object([
                    "catalogRevision": .number(7), "items": .array([first]), "nextCursor": .string("next-page"),
                ])
            default:
                throw GatewayFailure(code: "unexpected", message: method, retryable: false, details: nil)
            }
        }
        let endpoint = AutomationGatewayEndpoint(
            profile: profile(),
            client: AutomationRPCClient(request: script.request)
        )
        let coordinator = AutomationCatalogCoordinator(endpoints: { [endpoint] })

        coordinator.invalidate(profileID: endpoint.id)
        #expect(script.requests.isEmpty)
        coordinator.activate()
        try await eventually { coordinator.hasLoaded && !coordinator.isLoading }
        #expect(coordinator.buckets.first?.catalogRevision == 7)
        #expect(coordinator.buckets.first?.summaries.map(\.id) == ["automation-one", "automation-two"])
        #expect(script.requests.map(\.0) == ["automation.status", "automation.list", "automation.list"])

        coordinator.deactivate()
        let count = script.requests.count
        coordinator.invalidate(profileID: endpoint.id)
        await Task.yield()
        #expect(script.requests.count == count)
    }

    @Test("duplicate identities across pages fail closed")
    func duplicateFailsClosed() async throws {
        let value = automationSummary(id: "automation-one", name: "One")
        let script = AutomationRequestScript { method, params in
            if method == "automation.status" {
                return .object([
                    "ready": .bool(true), "degraded": .bool(false), "automationCount": .number(2),
                    "aggregateBytes": .number(1_024), "malformedRecordCount": .number(0), "catalogRevision": .number(7),
                ])
            }
            if params.objectValue?["cursor"] == .string("next-page") {
                return .object(["catalogRevision": .number(7), "items": .array([value])])
            }
            return .object([
                "catalogRevision": .number(7), "items": .array([value]), "nextCursor": .string("next-page"),
            ])
        }
        let endpoint = AutomationGatewayEndpoint(profile: profile(), client: AutomationRPCClient(request: script.request))
        let coordinator = AutomationCatalogCoordinator(endpoints: { [endpoint] })
        coordinator.activate()
        try await eventually { coordinator.hasLoaded && !coordinator.isLoading }
        #expect(coordinator.summaries.isEmpty)
        #expect(coordinator.buckets.first?.failure?.contains("duplicate") == true)
    }

    @Test("timeline coordinator admits a dense series and groups it by presentation day")
    func timelineSeries() async throws {
        let start = Date.now.addingTimeInterval(3_600)
        let first = GatewayTimestamp.string(from: start)
        let last = GatewayTimestamp.string(from: start.addingTimeInterval(3_300))
        let day = Calendar.current.startOfDay(for: start)
        let dayStart = GatewayTimestamp.string(from: day)
        let script = AutomationRequestScript { method, _ in
            guard method == "automation.timeline.list" else {
                throw GatewayFailure(code: "unexpected", message: method, retryable: false, details: nil)
            }
            return .object([
                "catalogRevision": .number(4),
                "items": .array([.object([
                    "kind": .string("series"), "automationId": .string("automation-one"),
                    "automationRevision": .number(2), "dayStart": .string(dayStart),
                    "firstAt": .string(first), "lastAt": .string(last), "count": .number(60),
                ])]),
            ])
        }
        let endpoint = AutomationGatewayEndpoint(profile: profile(), client: AutomationRPCClient(request: script.request))
        let coordinator = AutomationTimelineCoordinator(endpoints: { [endpoint] })
        coordinator.load(start: start)
        try await eventually { !coordinator.isLoading }
        #expect(coordinator.days.count == 1)
        #expect(coordinator.days.first?.items.first?.occurrence.kind == .series)
        #expect(coordinator.days.first?.items.first?.occurrence.count == 60)
    }

    @Test("revised timeline admission rejects a delayed predecessor and keeps one request per refresh")
    func revisedTimelineAdmissionFencesDelayedRead() async throws {
        let firstGate = TestReadGate()
        let secondGate = TestReadGate()
        var calls = 0
        var finished = 0
        var profile = self.profile(connectionID: 7)
        let catalogItem = automationSummary(id: "automation-catalog", name: "Catalog")
        let client = AutomationRPCClient { method, _ in
            switch method {
            case "automation.status":
                return .object([
                    "ready": .bool(true), "degraded": .bool(false),
                    "automationCount": .number(1), "aggregateBytes": .number(256),
                    "malformedRecordCount": .number(0),
                    "catalogRevision": .number(profile.connectionID == 7 ? 7 : 8),
                ])
            case "automation.list":
                return .object([
                    "catalogRevision": .number(profile.connectionID == 7 ? 7 : 8),
                    "items": .array([catalogItem]),
                ])
            case "automation.timeline.list":
                calls += 1
                let requestNumber = calls
                if requestNumber == 1 {
                    await firstGate.wait()
                } else {
                    await secondGate.wait()
                }
                finished += 1
                let id = requestNumber == 1 ? "automation-old" : "automation-new"
                return .object([
                    "catalogRevision": .number(requestNumber == 1 ? 7 : 8),
                    "items": .array([.object([
                        "kind": .string("series"), "automationId": .string(id),
                        "automationRevision": .number(1),
                        "dayStart": .string("2026-12-01T00:00:00.000Z"),
                        "firstAt": .string("2026-12-01T12:00:00.000Z"),
                        "lastAt": .string("2026-12-01T13:00:00.000Z"), "count": .number(60),
                    ])])
                ])
            default:
                throw GatewayFailure(code: "unexpected", message: method, retryable: false, details: nil)
            }
        }
        let catalog = AutomationCatalogCoordinator(endpoints: {
            [AutomationGatewayEndpoint(profile: profile, client: client)]
        })
        catalog.activate()
        try await eventually { catalog.hasLoaded && !catalog.isLoading }
        let originalAdmission = catalog.timelineAdmissionKey
        let timeline = AutomationTimelineCoordinator(endpoints: { catalog.allEndpoints() })
        timeline.load(start: Date(timeIntervalSince1970: 1_795_000_000))
        try await eventually { calls == 1 }

        // A revised authoritative catalog and a new connection change the
        // admission key; the dashboard then explicitly starts one successor.
        profile = self.profile(connectionID: 8)
        catalog.invalidate()
        try await eventually {
            catalog.hasLoaded && !catalog.isLoading && catalog.timelineAdmissionKey != originalAdmission
        }
        timeline.load(start: Date(timeIntervalSince1970: 1_795_000_000))
        try await eventually { calls == 2 }
        await firstGate.release()
        try await eventually { finished == 1 }
        #expect(timeline.days.isEmpty)
        await secondGate.release()
        try await eventually { !timeline.isLoading && finished == 2 }
        #expect(timeline.days.first?.items.first?.id.contains("automation-new") == true)
        #expect(calls == 2)
        timeline.cancel()
        catalog.deactivate()
    }

    @Test("covered Upcoming cancels reads, rejects late failures and restarts on return")
    func coveredTimelineOwnsReadLifetime() async throws {
        let request = DeferredTimelineRequest()
        let endpoint = AutomationGatewayEndpoint(profile: profile(), client: AutomationRPCClient(request: request.request))
        let coordinator = AutomationTimelineCoordinator(endpoints: { [endpoint] })
        defer { coordinator.cancel(); request.finish(.failure(CancellationError())) }
        coordinator.load()
        try await eventually { request.calls == 1 }
        coordinator.setPresentationActive(false)
        coordinator.load()
        coordinator.loadNext()
        #expect(request.calls == 1)
        #expect(!coordinator.isLoading)
        request.finish(.failure(GatewayPossiblySentError(failure: GatewayFailure(
            code: "possibly_sent", message: "A cancelled read may have reached the Mac.", retryable: false, details: nil
        ))))
        try await eventually { request.finished == 1 }
        #expect(request.returnedFromCancelledTask)
        #expect(coordinator.errorMessage == nil)
        #expect(coordinator.days.isEmpty)
        coordinator.setPresentationActive(true)
        coordinator.load()
        try await eventually { request.calls == 2 }
        #expect(coordinator.isLoading)
        request.finish(.success(.object(["catalogRevision": .number(1), "items": .array([])])))
        try await eventually { !coordinator.isLoading }
        #expect(coordinator.errorMessage == nil)
    }

    private func profile(connectionID: Int? = 1) -> AutomationDashboardProfile {
        AutomationDashboardProfile(
            id: "profile-one",
            label: "Mac",
            state: .connected,
            capabilities: [AutomationAdmissionPolicy.capability, AutomationAdmissionPolicy.timelineCapability],
            connectionID: connectionID
        )
    }

    private func automationSummary(id: String, name: String) -> JSONValue {
        .object([
            "id": .string(id), "revision": .number(1), "stateRevision": .number(1),
            "name": .string(name), "activation": .string("enabled"), "actionKind": .string("sessionPrompt"),
            "target": .object(["kind": .string("existingSession"), "sessionId": .string("session-one")]),
            "trigger": .object(["kind": .string("once"), "at": .string("2026-12-01T12:00:00.000Z")]),
            "nextOccurrenceAt": .string("2026-12-01T12:00:00.000Z"),
            "consecutiveFailureCount": .number(0),
            "createdAt": .string("2026-01-01T00:00:00.000Z"),
            "updatedAt": .string("2026-01-01T00:00:00.000Z"),
        ])
    }

    private func eventually(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for Automation coordinator")
    }
}
