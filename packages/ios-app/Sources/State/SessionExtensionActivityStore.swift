import Foundation
import Observation

struct ExtensionActivityHistoryPage: Codable, Hashable, Sendable {
    let activities: [ExtensionRunActivity]
    let historyRevision: String
    let nextCursor: String?
    let omissions: ExtensionActivityOmissions?
    let aggregateBytes: Int?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try values.decode([JSONValue].self, forKey: .activities)
        guard raw.count <= 50 else { throw DecodingError.dataCorruptedError(forKey: .activities, in: values, debugDescription: "History page exceeds its bound") }
        let decoded = raw.compactMap { try? $0.decode(ExtensionRunActivity.self) }
        var seenIDs = Set<String>()
        let admitted = decoded.filter { ExtensionActivityAdmissionPolicy.admits($0) && seenIDs.insert($0.stableID).inserted }
        guard admitted.count == decoded.filter(ExtensionActivityAdmissionPolicy.admits).count else {
            throw DecodingError.dataCorruptedError(forKey: .activities, in: values, debugDescription: "History page contains malformed or duplicate activity IDs")
        }
        activities = admitted
        let encodedActivities = (try? JSONEncoder.gateway.encode(admitted))?.count ?? Int.max
        guard encodedActivities <= ExtensionActivityAdmissionPolicy.maximumEncodedBytes else {
            throw DecodingError.dataCorruptedError(forKey: .activities, in: values, debugDescription: "History page exceeds its aggregate byte bound")
        }
        let revision = try values.decode(String.self, forKey: .historyRevision)
        guard !revision.isEmpty, revision.utf8.count <= 128 else {
            throw DecodingError.dataCorruptedError(forKey: .historyRevision, in: values, debugDescription: "Invalid history revision")
        }
        historyRevision = revision
        nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
        if let cursor = nextCursor, cursor.isEmpty || cursor.utf8.count > 256 {
            throw DecodingError.dataCorruptedError(forKey: .nextCursor, in: values, debugDescription: "Invalid history cursor")
        }
        omissions = try values.decodeIfPresent(ExtensionActivityOmissions.self, forKey: .omissions)
        if let omissions, omissions.count < 0 || omissions.bytes < 0 || omissions.bytes > ExtensionActivityAdmissionPolicy.maximumEncodedBytes
            || !["count", "bytes", "countAndBytes"].contains(omissions.reason) {
            throw DecodingError.dataCorruptedError(forKey: .omissions, in: values, debugDescription: "Invalid history omissions")
        }
        aggregateBytes = try values.decodeIfPresent(Int.self, forKey: .aggregateBytes)
        if let aggregateBytes, aggregateBytes < 0 || aggregateBytes > ExtensionActivityAdmissionPolicy.maximumEncodedBytes {
            throw DecodingError.dataCorruptedError(forKey: .aggregateBytes, in: values, debugDescription: "Invalid history aggregate bytes")
        }
    }

    private enum CodingKeys: String, CodingKey { case activities, historyRevision, nextCursor, omissions, aggregateBytes }
}

struct ExtensionActivityHistoryDetail: Codable, Hashable, Sendable {
    let activity: ExtensionRunActivity
}

struct ExtensionActivityHistoryFilter: Hashable, Sendable {
    let ownerID: String?
    let runID: String?
    let state: ExtensionActivityLifecycleState?
}

@MainActor
@Observable
final class SessionExtensionActivityStore {
    enum Status: Equatable, Sendable { case idle, loading, loaded, unavailable, disconnected, conflict, failed(String) }

    private let client: GatewayClient
    private var pageGeneration = 0
    private var detailGenerationCounter = 0
    private var pageTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?

    private(set) var status: Status = .idle
    private(set) var sessionID: String?
    private(set) var presentationGeneration: Int?
    private(set) var historyRevision: String?
    private(set) var pages: [ExtensionActivityHistoryPage] = []
    private(set) var detail: ExtensionRunActivity?
    private(set) var detailGeneration: Int?
    private(set) var detailRouteID: String?
    private(set) var nextCursor: String?
    private var retainedHistoryBytes = 0
    private var filter: ExtensionActivityHistoryFilter?
    private var seenCursors = Set<String>()
    private var seenActivityIDs = Set<String>()

    init(client: GatewayClient) { self.client = client }

    var activities: [ExtensionRunActivity] {
        pages.flatMap(\.activities).filter { activity in
            guard let filter else { return true }
            return (filter.ownerID == nil || filter.ownerID == activity.source.owner?.id)
                && (filter.runID == nil || filter.runID == activity.runId)
                && (filter.state == nil || filter.state == activity.lifecycle?.state)
        }
    }
    var supportsHistory: Bool {
        get async {
            guard let info = await client.info else { return false }
            return info.capabilities.contains(ExtensionActivityAdmissionPolicy.capability)
        }
    }

    func reset(sessionID: String, presentationGeneration: Int) {
        pageGeneration &+= 1; detailGenerationCounter &+= 1
        pageTask?.cancel(); pageTask = nil
        detailTask?.cancel(); detailTask = nil
        self.sessionID = sessionID
        self.presentationGeneration = presentationGeneration
        filter = nil
        historyRevision = nil; pages.removeAll(); retainedHistoryBytes = 0
        detail = nil; detailGeneration = nil; detailRouteID = nil; nextCursor = nil
        seenCursors.removeAll(); seenActivityIDs.removeAll()
        status = .idle
    }

    func loadNext(sessionID: String, presentationGeneration: Int, filter requestedFilter: ExtensionActivityHistoryFilter? = nil) {
        guard self.sessionID == sessionID, self.presentationGeneration == presentationGeneration else { return }
        // Load More does not pass a filter argument. Preserve the active
        // identity across that action; only an explicitly supplied filter
        // starts a new canonical cursor.
        if let requestedFilter, filter != requestedFilter {
            filter = requestedFilter
            pageGeneration &+= 1
            pageTask?.cancel(); pageTask = nil
            historyRevision = nil; pages.removeAll(); retainedHistoryBytes = 0; nextCursor = nil
            seenCursors.removeAll(); seenActivityIDs.removeAll()
            status = .idle
        }
        guard pageTask == nil else { return }
        pageGeneration &+= 1
        let generation = pageGeneration
        let cursor = nextCursor
        let filter = self.filter
        status = .loading
        pageTask = Task { [weak self, client] in
            defer { Task { @MainActor [weak self] in
                guard let self, self.pageGeneration == generation else { return }
                self.pageTask = nil
            } }
            do {
                guard await client.info?.capabilities.contains(ExtensionActivityAdmissionPolicy.capability) == true else {
                    await MainActor.run { [weak self] in
                        guard let self, self.pageGeneration == generation else { return }
                        self.status = .unavailable
                    }
                    return
                }
                struct Params: Encodable {
                    let sessionId: String; let cursor: String?; let limit: Int
                    let ownerId: String?; let runId: String?; let state: String?
                }
                let page: ExtensionActivityHistoryPage = try await client.request(
                    "session.extensionActivity.list",
                    Params(sessionId: sessionID, cursor: cursor, limit: 50,
                           ownerId: filter?.ownerID, runId: filter?.runID,
                           state: filter?.state.flatMap(Self.wireState)),
                    timeout: .seconds(15)
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.pageGeneration == generation,
                          self.sessionID == sessionID, self.presentationGeneration == presentationGeneration else { return }
                    if let revision = self.historyRevision, revision != page.historyRevision {
                        self.status = .conflict
                        return
                    }
                    if let cursor {
                        guard self.seenCursors.insert(cursor).inserted,
                              page.nextCursor != cursor else {
                            self.status = .conflict
                            return
                        }
                    }
                    let incomingIDs = page.activities.map(\.stableID)
                    guard Set(incomingIDs).count == incomingIDs.count,
                          incomingIDs.allSatisfy({ self.seenActivityIDs.insert($0).inserted }) else {
                        self.status = .conflict
                        return
                    }
                    let pageBytes = page.aggregateBytes
                        ?? (try? JSONEncoder.gateway.encode(page.activities).count)
                        ?? Int.max
                    guard self.pages.count < Self.maximumRetainedPages,
                          self.seenActivityIDs.count <= Self.maximumRetainedItems,
                          self.retainedHistoryBytes + pageBytes <= Self.maximumRetainedBytes else {
                        // Keep the already-authoritative rows and stop paging
                        // rather than allowing an unbounded history cache.
                        self.nextCursor = nil
                        self.status = .loaded
                        return
                    }
                    self.historyRevision = page.historyRevision
                    self.pages.append(page)
                    self.retainedHistoryBytes += pageBytes
                    self.nextCursor = page.nextCursor
                    self.status = .loaded
                }
            } catch is CancellationError { return }
            catch {
                await MainActor.run { [weak self] in
                    guard let self, self.pageGeneration == generation else { return }
                    if let failure = error as? GatewayFailure, failure.code == "disconnected" { self.status = .disconnected }
                    else if let failure = error as? GatewayFailure, failure.code == "conflict", failure.retryable { self.status = .conflict }
                    else { self.status = .failed(error.localizedDescription) }
                }
            }
        }
    }

    func retryReload(sessionID: String, presentationGeneration: Int) {
        guard self.sessionID == sessionID, self.presentationGeneration == presentationGeneration else { return }
        pageTask?.cancel(); pageTask = nil
        pageGeneration &+= 1
        historyRevision = nil; pages.removeAll(); retainedHistoryBytes = 0; nextCursor = nil
        seenCursors.removeAll(); seenActivityIDs.removeAll()
        status = .idle
        loadNext(sessionID: sessionID, presentationGeneration: presentationGeneration, filter: filter)
    }

    func loadDetail(sessionID: String, activityID: String, presentationGeneration: Int, routeID: String) {
        guard self.sessionID == sessionID, self.presentationGeneration == presentationGeneration else { return }
        detailTask?.cancel()
        detailGenerationCounter &+= 1
        let generation = detailGenerationCounter
        let historyRevision = self.historyRevision
        detail = nil; detailGeneration = nil; detailRouteID = nil
        detailTask = Task { [weak self, client] in
            defer { Task { @MainActor [weak self] in
                guard let self, self.detailGenerationCounter == generation else { return }
                self.detailTask = nil
            } }
            do {
                guard await client.info?.capabilities.contains(ExtensionActivityAdmissionPolicy.capability) == true else { return }
                struct Params: Encodable { let sessionId: String; let activityId: String; let historyRevision: String? }
                let response: ExtensionActivityHistoryDetail = try await client.request(
                    "session.extensionActivity.get",
                    Params(sessionId: sessionID, activityId: activityID, historyRevision: historyRevision),
                    timeout: .seconds(15)
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.detailGenerationCounter == generation,
                          self.sessionID == sessionID, self.presentationGeneration == presentationGeneration,
                          self.historyRevision == historyRevision else { return }
                    guard ExtensionActivityAdmissionPolicy.admits(response.activity),
                          response.activity.stableID == activityID else { return }
                    self.detail = response.activity
                    self.detailGeneration = generation
                    self.detailRouteID = routeID
                }
            } catch { /* route disappearance is represented by nil detail */ }
        }
    }

    private static let maximumRetainedPages = 8
    private static let maximumRetainedItems = 400
    private static let maximumRetainedBytes = 2 * 1_024 * 1_024

    private static func wireState(_ state: ExtensionActivityLifecycleState) -> String? {
        switch state { case .completed, .failed, .stopped, .rejected: state.rawValue; default: nil }
    }
}
