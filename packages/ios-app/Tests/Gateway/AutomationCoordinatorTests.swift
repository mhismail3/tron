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

    func request(_ method: String, _ params: JSONValue, _ timeout: Duration) async throws -> JSONValue {
        requests.append((method, params))
        return try handler(method, params)
    }
}

@Suite("Automation catalog ownership")
@MainActor
struct AutomationCoordinatorTests {
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

    private func profile() -> AutomationDashboardProfile {
        AutomationDashboardProfile(
            id: "profile-one",
            label: "Mac",
            state: .connected,
            capabilities: [AutomationAdmissionPolicy.capability, AutomationAdmissionPolicy.timelineCapability]
        )
    }

    private func automationSummary(id: String, name: String) -> JSONValue {
        .object([
            "id": .string(id), "revision": .number(1), "stateRevision": .number(1),
            "name": .string(name), "activation": .string("enabled"), "actionKind": .string("sessionPrompt"),
            "targetSessionId": .string("session-one"),
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
