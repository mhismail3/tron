import Foundation

enum SessionSearchCoveragePresentation {
    static func state(for response: SessionSearchResponse) -> String {
        response.coverage.state == "complete" ? "ready" : "partial"
    }

    static func message(for response: SessionSearchResponse) -> String? {
        response.coverage.state == "complete" ? nil : "Some conversations could not be searched"
    }

    static func rankingWarning(for ranking: SessionSearchResponse.Ranking) -> String? {
        // Successful semantic or Jev ranking is not a fallback. Warnings concern
        // only unavailable enrichment; locally retrieved matches remain usable.
        if ranking.state == "jev" { return nil }
        let reason: String
        switch ranking.jev {
        case "consentRequired": reason = "Remote ranking needs permission"
        case "notConfigured": reason = "Remote ranking is not configured"
        case "uncertain": reason = "Remote ranking did not finish"
        default:
            switch ranking.state {
            case "budgetLimited": reason = "Remote ranking spending limit reached"
            case "jevUnavailable": reason = "Remote ranking is unavailable"
            default: return nil
            }
        }
        return "\(reason). Local results are shown."
    }
}

/// Presentation owner for search-as-you-type. Transport admission is captured
/// before every request so a reconnect cannot silently move work to a successor
/// connection. The selected profile uses the lifecycle-owned client; background
/// profiles use the disposable dashboard pool.
@MainActor
final class SessionSearchCoordinator {
    private var latestRequest = 0
    private var activeFanoutTasks: [Task<SessionSearchProfileStatus, Never>] = []

    func search(
        query: String,
        profileID: String,
        connections: DashboardGatewayConnectionPool,
        maxResults: Int = 25,
        remoteRanking: Bool = false,
        remoteConsent: Bool = false,
        lifecycle: GatewayLifecycleCoordinator? = nil
    ) async throws -> SessionSearchResponse? {
        cancelActiveRequests()
        latestRequest += 1
        return try await searchSingle(query: query, profileID: profileID, connections: connections, maxResults: maxResults, remoteRanking: remoteRanking, remoteConsent: remoteConsent, requestID: latestRequest, lifecycle: lifecycle)
    }

    private func searchSingle(
        query: String,
        profileID: String,
        connections: DashboardGatewayConnectionPool,
        maxResults: Int,
        remoteRanking: Bool,
        remoteConsent: Bool,
        requestID: Int,
        lifecycle: GatewayLifecycleCoordinator? = nil
    ) async throws -> SessionSearchResponse? {
        let selected = lifecycle?.selectedProfileID == profileID
        let poolAdmission = selected ? nil : connections.requestAdmission(for: profileID)
        let lifecycleAdmission = selected ? lifecycle?.admission : nil
        guard (selected && lifecycleAdmission?.connectionID != nil) || (!selected && poolAdmission != nil) else { return nil }
        let params: JSONValue = .object([
            "query": .string(query),
            "scope": .string("user"),
            "maxResults": .number(Double(maxResults)),
            "remoteRanking": .bool(remoteRanking),
            "remoteConsent": .bool(remoteConsent),
        ])
        let value: JSONValue
        if let lifecycle, let admission = lifecycleAdmission {
            try lifecycle.requireConnection(admission)
            value = try await lifecycle.client.requestValue("session.search", params, expectedConnection: GatewayConnectionAdmission(connectionID: admission.connectionID))
            guard lifecycle.admits(admission) else { return nil }
        } else if let admission = poolAdmission {
            value = try await connections.request(profileID: profileID, method: "session.search", params: params, expectedConnection: admission)
            guard connections.requestAdmission(for: profileID) == admission else { return nil }
        } else { return nil }
        guard requestID == latestRequest else { return nil }
        let decoded = try JSONDecoder().decode(SessionSearchResponse.self, from: JSONEncoder().encode(value))
        return SessionSearchResponse(
            query: decoded.query, queryRevision: decoded.queryRevision, corpusRevision: decoded.corpusRevision,
            indexRevision: decoded.indexRevision, coverage: decoded.coverage, semantic: decoded.semantic,
            ranking: decoded.ranking,
            results: decoded.results.map { result in
                SessionSearchResult(sessionId: result.sessionId, gatewayProfileID: profileID, title: result.title, cwd: result.cwd, updatedAt: result.updatedAt, entryId: result.entryId, parentEntryId: result.parentEntryId, ordinal: result.ordinal, passageKind: result.passageKind, snippet: result.snippet, lexicalScore: result.lexicalScore, semanticScore: result.semanticScore, jevScore: result.jevScore, anchorRevision: result.anchorRevision)
            }
        )
    }

    func searchAll(
        query: String,
        targets: [SessionSearchProfileTarget],
        connections: DashboardGatewayConnectionPool,
        maxResults: Int = 25,
        remoteRanking: Bool = false,
        consentByProfile: [String: Bool] = [:],
        lifecycle: GatewayLifecycleCoordinator? = nil
    ) async -> SessionSearchAggregate {
        cancelActiveRequests()
        latestRequest += 1
        let requestID = latestRequest
        let boundedTargets = Array(targets.prefix(8))
        let omittedStatuses = targets.dropFirst(8).map { target in
            SessionSearchProfileStatus(profileID: target.profileID, label: target.label, state: "skipped", response: nil, message: "Search fanout limit reached")
        }
        let tasks: [Task<SessionSearchProfileStatus, Never>] = boundedTargets.map { target in
            Task { @MainActor in
                await self.profileStatus(target: target, query: query, connections: connections, maxResults: maxResults, remoteRanking: remoteRanking, remoteConsent: consentByProfile[target.profileID] ?? false, requestID: requestID, lifecycle: lifecycle)
            }
        }
        activeFanoutTasks = tasks
        var statuses = Array(omittedStatuses)
        for task in tasks { statuses.append(await task.value) }
        if requestID == latestRequest { activeFanoutTasks.removeAll() }
        guard requestID == latestRequest else { return SessionSearchAggregate(groups: [], profiles: []) }
        let groups = statuses.compactMap { status -> [SessionSearchSessionGroup]? in
            guard let response = status.response else { return nil }
            let bySession = Dictionary(grouping: response.results, by: \.sessionId)
            return bySession.map { sessionID, passages in
                guard let first = passages.first else { return SessionSearchSessionGroup(profileID: status.profileID, profileLabel: status.label, sessionId: sessionID, title: sessionID, cwd: "", updatedAt: "", passages: [], isLocalMatch: false) }
                let ordered = passages.sorted { left, right in
                    left.ordinal != right.ordinal ? left.ordinal < right.ordinal : left.id < right.id
                }
                return SessionSearchSessionGroup(profileID: status.profileID, profileLabel: status.label, sessionId: sessionID, title: first.title, cwd: first.cwd, updatedAt: first.updatedAt, passages: ordered, isLocalMatch: false)
            }
        }.flatMap { $0 }.sorted { left, right in
            left.updatedAt != right.updatedAt ? left.updatedAt > right.updatedAt : (left.profileID, left.sessionId) < (right.profileID, right.sessionId)
        }
        return SessionSearchAggregate(groups: groups, profiles: statuses.sorted { left, right in left.label != right.label ? left.label < right.label : left.profileID < right.profileID })
    }

    private func profileStatus(
        target: SessionSearchProfileTarget,
        query: String,
        connections: DashboardGatewayConnectionPool,
        maxResults: Int,
        remoteRanking: Bool,
        remoteConsent: Bool,
        requestID: Int,
        lifecycle: GatewayLifecycleCoordinator?
    ) async -> SessionSearchProfileStatus {
        guard !Task.isCancelled else { return SessionSearchProfileStatus(profileID: target.profileID, label: target.label, state: "cancelled", response: nil, message: nil) }
        if !target.capabilities.isEmpty && !target.capabilities.contains("session-search.v1") {
            return SessionSearchProfileStatus(profileID: target.profileID, label: target.label, state: "unsupported", response: nil, message: "Gateway does not support SessionSearch")
        }
        guard connectionsCurrent(target, connections: connections, lifecycle: lifecycle) else {
            return SessionSearchProfileStatus(profileID: target.profileID, label: target.label, state: "offline", response: nil, message: "Gateway is offline")
        }
        do {
            let response = try await searchSingle(query: query, profileID: target.profileID, connections: connections, maxResults: maxResults, remoteRanking: remoteRanking, remoteConsent: remoteConsent, requestID: requestID, lifecycle: lifecycle)
            // Lexical results are the baseline product capability. Semantic and
            // Jev ranking are optional enrichments and must not make a usable
            // search look broken or partial.
            let state = response.map(SessionSearchCoveragePresentation.state(for:)) ?? "offline"
            let message = response.map(SessionSearchCoveragePresentation.message(for:)) ?? "Gateway is offline"
            return SessionSearchProfileStatus(profileID: target.profileID, label: target.label, state: state, response: response, message: message)
        } catch is CancellationError {
            return SessionSearchProfileStatus(profileID: target.profileID, label: target.label, state: "cancelled", response: nil, message: nil)
        } catch {
            return SessionSearchProfileStatus(profileID: target.profileID, label: target.label, state: "error", response: nil, message: "Search unavailable")
        }
    }

    private func connectionsCurrent(_ target: SessionSearchProfileTarget, connections: DashboardGatewayConnectionPool, lifecycle: GatewayLifecycleCoordinator?) -> Bool {
        if target.isSelected, let lifecycle { return lifecycle.selectedProfileID == target.profileID && lifecycle.admission?.connectionID != nil }
        return connections.requestAdmission(for: target.profileID) != nil
    }

    func getPolicy(profileID: String, connections: DashboardGatewayConnectionPool, lifecycle: GatewayLifecycleCoordinator? = nil, admission: GatewayLifecycleCoordinator.Admission? = nil, expectedConnection: GatewayConnectionAdmission? = nil) async throws -> SessionSearchPolicy {
        let params: JSONValue = .object([:])
        let value: JSONValue
        if let lifecycle, let admission {
            try lifecycle.requireConnection(admission)
            value = try await lifecycle.client.requestValue("session.search.policy.get", params, expectedConnection: GatewayConnectionAdmission(connectionID: admission.connectionID))
            guard lifecycle.admits(admission) else { throw CancellationError() }
        } else if let admission = expectedConnection ?? connections.requestAdmission(for: profileID) {
            value = try await connections.request(profileID: profileID, method: "session.search.policy.get", params: params, expectedConnection: admission)
            guard connections.requestAdmission(for: profileID) == admission else { throw CancellationError() }
        } else { throw CancellationError() }
        return try JSONDecoder().decode(SessionSearchPolicy.self, from: JSONEncoder().encode(value))
    }

    func setPolicy(profileID: String, enabled: Bool, connections: DashboardGatewayConnectionPool, lifecycle: GatewayLifecycleCoordinator? = nil, admission: GatewayLifecycleCoordinator.Admission? = nil) async throws -> SessionSearchPolicy {
        let params: JSONValue = .object([
            "enabled": .bool(enabled), "perQueryMicroCents": .number(268_800), "dailyMicroCents": .number(2_688_000), "policyRevision": .number(1),
        ])
        let value: JSONValue
        if let lifecycle, let admission {
            try lifecycle.requireConnection(admission)
            value = try await lifecycle.client.requestValue("session.search.policy.set", params, expectedConnection: GatewayConnectionAdmission(connectionID: admission.connectionID))
            guard lifecycle.admits(admission) else { throw CancellationError() }
        } else if let admission = connections.requestAdmission(for: profileID) {
            value = try await connections.request(profileID: profileID, method: "session.search.policy.set", params: params, expectedConnection: admission)
        } else { throw CancellationError() }
        return try JSONDecoder().decode(SessionSearchPolicy.self, from: JSONEncoder().encode(value))
    }

    func anchor(
        result: SessionSearchResult,
        profileID: String,
        runtimeGeneration: String?,
        leafEntryID: String?,
        connections: DashboardGatewayConnectionPool,
        lifecycle: GatewayLifecycleCoordinator? = nil,
        windowEnd: Int? = nil
    ) async throws -> SessionSearchAnchorResponse {
        let selected = lifecycle?.selectedProfileID == profileID
        let poolAdmission = selected ? nil : connections.requestAdmission(for: profileID)
        let lifecycleAdmission = selected ? lifecycle?.admission : nil
        guard (selected && lifecycleAdmission?.connectionID != nil) || (!selected && poolAdmission != nil) else { throw CancellationError() }
        let revision: [String: JSONValue] = ["indexRevision": .string(result.anchorRevision.indexRevision), "fileIdentity": .string(result.anchorRevision.fileIdentity), "branchDigest": .string(result.anchorRevision.branchDigest), "entryOrdinal": .number(Double(result.anchorRevision.entryOrdinal))]
        var revisionValue = revision
        if let leaf = result.anchorRevision.leafEntryId { revisionValue["leafEntryId"] = .string(leaf) }
        if let boundary = result.anchorRevision.forkBoundary { revisionValue["forkBoundary"] = .object(["kind": .string(boundary.kind), "inheritedEntryId": .string(boundary.inheritedEntryId), "gapOrdinal": .number(Double(boundary.gapOrdinal))]) }
        var params: [String: JSONValue] = ["sessionId": .string(result.sessionId), "entryId": .string(result.entryId), "anchorRevision": .object(revisionValue)]
        if let runtimeGeneration { params["expectedRuntimeGeneration"] = .string(runtimeGeneration) }
        if let leafEntryID { params["expectedLeafEntryId"] = .string(leafEntryID) }
        if let windowEnd { params["windowEnd"] = .number(Double(windowEnd)) }
        let paramsValue: JSONValue = .object(params)
        let value: JSONValue
        if let lifecycle, let admission = lifecycleAdmission {
            try lifecycle.requireConnection(admission)
            value = try await lifecycle.client.requestValue("session.search.anchor", paramsValue, expectedConnection: GatewayConnectionAdmission(connectionID: admission.connectionID))
            guard lifecycle.admits(admission) else { throw CancellationError() }
        } else if let admission = poolAdmission {
            value = try await connections.request(profileID: profileID, method: "session.search.anchor", params: paramsValue, expectedConnection: admission)
            guard connections.requestAdmission(for: profileID) == admission else { throw CancellationError() }
        } else { throw CancellationError() }
        return try JSONDecoder().decode(SessionSearchAnchorResponse.self, from: JSONEncoder().encode(value))
    }

    func dismiss() {
        latestRequest += 1
        cancelActiveRequests()
    }

    private func cancelActiveRequests() {
        activeFanoutTasks.forEach { $0.cancel() }
        activeFanoutTasks.removeAll()
    }
}
