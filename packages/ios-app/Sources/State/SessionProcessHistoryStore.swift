import Foundation
import Observation

struct SessionProcessHistoryPage: Codable, Hashable, Sendable {
    let activities: [SessionProcessActivity]
    let historyRevision: String
    let nextCursor: String?
    let omissions: SessionProcessOmissions?
    let aggregateBytes: Int?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try values.decode([JSONValue].self, forKey: .activities)
        guard raw.count <= 50 else {
            throw DecodingError.dataCorruptedError(forKey: .activities, in: values, debugDescription: "Process history page exceeds 50 rows")
        }
        let decoded = raw.compactMap { try? $0.decode(SessionProcessActivity.self) }
        guard decoded.count == raw.count else {
            throw DecodingError.dataCorruptedError(forKey: .activities, in: values, debugDescription: "Malformed process history row")
        }
        var seen = Set<String>()
        let admitted = decoded.filter {
            SessionProcessAdmissionPolicy.admits($0) && seen.insert($0.processId).inserted
        }
        guard admitted.count == decoded.count else {
            throw DecodingError.dataCorruptedError(forKey: .activities, in: values, debugDescription: "Malformed or duplicate process history row")
        }
        let encodedBytes = (try? JSONEncoder.gateway.encode(admitted))?.count ?? .max
        guard encodedBytes <= SessionProcessAdmissionPolicy.maximumEncodedBytes else {
            throw DecodingError.dataCorruptedError(forKey: .activities, in: values, debugDescription: "Process history page exceeds byte bound")
        }
        activities = admitted
        let revision = try values.decode(String.self, forKey: .historyRevision)
        guard !revision.isEmpty, revision.utf8.count <= 128 else {
            throw DecodingError.dataCorruptedError(forKey: .historyRevision, in: values, debugDescription: "Invalid process history revision")
        }
        historyRevision = revision
        nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
        if let nextCursor, nextCursor.isEmpty || nextCursor.utf8.count > 256 {
            throw DecodingError.dataCorruptedError(forKey: .nextCursor, in: values, debugDescription: "Invalid process history cursor")
        }
        omissions = try values.decodeIfPresent(SessionProcessOmissions.self, forKey: .omissions)
        if let omissions, omissions.count < 0 || omissions.bytes < 0
            || omissions.bytes > SessionProcessAdmissionPolicy.maximumEncodedBytes
            || !["count", "bytes", "countAndBytes"].contains(omissions.reason) {
            throw DecodingError.dataCorruptedError(forKey: .omissions, in: values, debugDescription: "Invalid process history omissions")
        }
        aggregateBytes = try values.decodeIfPresent(Int.self, forKey: .aggregateBytes)
        if let aggregateBytes, aggregateBytes < 0 || aggregateBytes > SessionProcessAdmissionPolicy.maximumEncodedBytes {
            throw DecodingError.dataCorruptedError(forKey: .aggregateBytes, in: values, debugDescription: "Invalid process history aggregate bytes")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case activities, historyRevision, nextCursor, omissions, aggregateBytes
    }
}

struct SessionProcessHistoryDetail: Codable, Hashable, Sendable {
    let activity: SessionProcessActivity
}

@MainActor
@Observable
final class SessionProcessHistoryStore {
    enum Status: Equatable, Sendable {
        case idle, loading, loaded, unavailable, disconnected, conflict, failed(String)
    }

    private let client: GatewayClient
    private var pageGeneration = 0
    private var detailGenerationCounter = 0
    private var pageTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var retainedHistoryBytes = 0
    private var seenCursors = Set<String>()
    private var seenProcessIDs = Set<String>()

    private(set) var status: Status = .idle
    private(set) var sessionID: String?
    private(set) var presentationGeneration: Int?
    private(set) var historyRevision: String?
    private(set) var pages: [SessionProcessHistoryPage] = []
    private(set) var detail: SessionProcessActivity?
    private(set) var detailGeneration: Int?
    private(set) var detailRouteID: String?
    private(set) var nextCursor: String?

    init(client: GatewayClient) { self.client = client }

    var processes: [SessionProcessActivity] { pages.flatMap(\.activities) }

    var supportsHistory: Bool {
        get async {
            await client.info?.capabilities.contains(SessionProcessAdmissionPolicy.historyCapability) == true
        }
    }

    func reset(sessionID: String, presentationGeneration: Int) {
        pageGeneration &+= 1
        detailGenerationCounter &+= 1
        pageTask?.cancel(); pageTask = nil
        detailTask?.cancel(); detailTask = nil
        self.sessionID = sessionID
        self.presentationGeneration = presentationGeneration
        historyRevision = nil
        pages.removeAll()
        retainedHistoryBytes = 0
        detail = nil
        detailGeneration = nil
        detailRouteID = nil
        nextCursor = nil
        seenCursors.removeAll()
        seenProcessIDs.removeAll()
        status = .idle
    }

    func loadNext(sessionID: String, presentationGeneration: Int) {
        guard self.sessionID == sessionID,
              self.presentationGeneration == presentationGeneration,
              pageTask == nil else { return }
        pageGeneration &+= 1
        let generation = pageGeneration
        let cursor = nextCursor
        status = .loading
        pageTask = Task { [weak self, client] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self, self.pageGeneration == generation else { return }
                    self.pageTask = nil
                }
            }
            do {
                guard await client.info?.capabilities.contains(SessionProcessAdmissionPolicy.historyCapability) == true else {
                    await MainActor.run { [weak self] in
                        guard let self, self.pageGeneration == generation else { return }
                        self.status = .unavailable
                    }
                    return
                }
                struct Params: Encodable { let sessionId: String; let cursor: String?; let limit: Int }
                let page: SessionProcessHistoryPage = try await client.request(
                    "session.processHistory.list",
                    Params(sessionId: sessionID, cursor: cursor, limit: 50),
                    timeout: .seconds(15)
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.pageGeneration == generation,
                          self.sessionID == sessionID,
                          self.presentationGeneration == presentationGeneration else { return }
                    if let installedRevision = self.historyRevision,
                       installedRevision != page.historyRevision {
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
                    let incomingIDs = page.activities.map(\.processId)
                    guard Set(incomingIDs).count == incomingIDs.count,
                          incomingIDs.allSatisfy({ self.seenProcessIDs.insert($0).inserted }) else {
                        self.status = .conflict
                        return
                    }
                    let bytes = page.aggregateBytes
                        ?? (try? JSONEncoder.gateway.encode(page.activities).count)
                        ?? .max
                    guard self.pages.count < Self.maximumRetainedPages,
                          self.seenProcessIDs.count <= Self.maximumRetainedItems,
                          self.retainedHistoryBytes <= Self.maximumRetainedBytes - bytes else {
                        self.nextCursor = nil
                        self.status = .loaded
                        return
                    }
                    self.historyRevision = page.historyRevision
                    self.pages.append(page)
                    self.retainedHistoryBytes += bytes
                    self.nextCursor = page.nextCursor
                    self.status = .loaded
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.pageGeneration == generation else { return }
                    if let failure = error as? GatewayFailure, failure.code == "disconnected" {
                        self.status = .disconnected
                    } else if let failure = error as? GatewayFailure,
                              failure.code == "conflict", failure.retryable {
                        self.status = .conflict
                    } else {
                        self.status = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    func retryReload(sessionID: String, presentationGeneration: Int) {
        guard self.sessionID == sessionID,
              self.presentationGeneration == presentationGeneration else { return }
        pageTask?.cancel(); pageTask = nil
        pageGeneration &+= 1
        historyRevision = nil
        pages.removeAll()
        retainedHistoryBytes = 0
        nextCursor = nil
        seenCursors.removeAll()
        seenProcessIDs.removeAll()
        status = .idle
        loadNext(sessionID: sessionID, presentationGeneration: presentationGeneration)
    }

    func loadDetail(
        sessionID: String,
        processID: String,
        presentationGeneration: Int,
        routeID: String
    ) {
        guard self.sessionID == sessionID,
              self.presentationGeneration == presentationGeneration else { return }
        detailTask?.cancel()
        detailGenerationCounter &+= 1
        let generation = detailGenerationCounter
        let revision = historyRevision
        detail = nil; detailGeneration = nil; detailRouteID = nil
        detailTask = Task { [weak self, client] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self, self.detailGenerationCounter == generation else { return }
                    self.detailTask = nil
                }
            }
            do {
                struct Params: Encodable { let sessionId, processId: String; let historyRevision: String? }
                let response: SessionProcessHistoryDetail = try await client.request(
                    "session.processHistory.get",
                    Params(sessionId: sessionID, processId: processID, historyRevision: revision),
                    timeout: .seconds(15)
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.detailGenerationCounter == generation,
                          self.sessionID == sessionID,
                          self.presentationGeneration == presentationGeneration,
                          self.historyRevision == revision,
                          response.activity.processId == processID,
                          SessionProcessAdmissionPolicy.admits(response.activity) else { return }
                    self.detail = response.activity
                    self.detailGeneration = generation
                    self.detailRouteID = routeID
                }
            } catch { /* A disappearing canonical route remains unavailable. */ }
        }
    }

    private static let maximumRetainedPages = 8
    private static let maximumRetainedItems = 400
    private static let maximumRetainedBytes = 2 * 1_024 * 1_024
}
