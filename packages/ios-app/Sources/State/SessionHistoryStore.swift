import Foundation
import Observation

struct SessionHistoryCursor: Codable, Hashable, Sendable {
    let ordinal: Int
    let entryId: String
    let direction: String
}

struct SessionHistoryPage: Codable, Sendable {
    let runtimeGeneration: String
    let nodes: [SessionTreeNode]
    let older: SessionHistoryCursor?
    let newer: SessionHistoryCursor?
    let totalEntries: Int

    /// One-based canonical append ordinals, not a page number inferred from a
    /// moving total. Appends can leave a cursor window off a 100-row boundary.
    var entryRange: ClosedRange<Int>? {
        guard !nodes.isEmpty, totalEntries >= nodes.count else { return nil }
        let upper: Int
        if let newer {
            guard newer.ordinal >= 0, newer.ordinal < totalEntries else { return nil }
            upper = newer.ordinal + 1
        } else { upper = totalEntries }
        guard upper >= nodes.count else { return nil }
        return (upper - nodes.count + 1)...upper
    }

    var rangeDescription: String {
        guard let range = entryRange else { return "No recorded entries" }
        return "Entries \(range.lowerBound.formatted())–\(range.upperBound.formatted()) of \(totalEntries.formatted())"
    }

    func admitted(runtime: String, cursor: SessionHistoryCursor? = nil) throws -> Self {
        guard runtimeGeneration == runtime, nodes.count <= 100, totalEntries >= nodes.count else {
            throw SessionHistoryReadError.invalidPage
        }
        _ = try SessionTreePolicy.admit(nodes)
        if nodes.isEmpty {
            guard totalEntries == 0, older == nil, newer == nil, cursor == nil else { throw SessionHistoryReadError.invalidPage }
        } else {
            guard let range = entryRange,
                  older?.ordinal == (range.lowerBound > 1 ? range.lowerBound - 1 : nil),
                  newer?.ordinal == (range.upperBound < totalEntries ? range.upperBound - 1 : nil) else {
                throw SessionHistoryReadError.invalidPage
            }
        }
        for (cursor, direction, node) in [(older, "older", nodes.last), (newer, "newer", nodes.first)] {
            if let cursor {
                guard cursor.direction == direction, cursor.ordinal >= 0, cursor.ordinal < totalEntries,
                      cursor.entryId == node?.id else { throw SessionHistoryReadError.invalidPage }
            }
        }
        if let cursor {
            guard cursor.ordinal >= 0, cursor.ordinal < Int.max,
                  cursor.direction == "older" || cursor.direction == "newer" else { throw SessionHistoryReadError.invalidPage }
            if cursor.direction == "older" {
                guard newer?.ordinal == cursor.ordinal - 1 else { throw SessionHistoryReadError.invalidPage }
            } else {
                guard cursor.ordinal < Int.max, older?.ordinal == cursor.ordinal + 1 else { throw SessionHistoryReadError.invalidPage }
            }
        }
        return self
    }
}

struct SessionHistoryEntryPage: Codable, Sendable {
    let runtimeGeneration: String
    let entryId: String
    let text: String
    let offset: Int
    let nextOffset: Int?
    let previousOffset: Int?
    let totalCharacters: Int
    let metadata: JSONValue

    func admitted(runtime: String, entry: String, requestedOffset: Int) throws -> Self {
        guard runtimeGeneration == runtime, entryId == entry, offset == requestedOffset,
              offset >= 0, offset <= Int.max - 24_000, text.utf16.count <= 24_000, totalCharacters >= offset + text.utf16.count,
              (try? JSONEncoder.gateway.encode(metadata).count).map({ $0 <= 32_000 }) == true,
              nextOffset == (offset + text.utf16.count < totalCharacters ? offset + text.utf16.count : nil),
              nextOffset == nil || nextOffset! > offset,
              previousOffset == nil ? offset == 0 : previousOffset! >= 0 && previousOffset! < offset else { throw SessionHistoryReadError.invalidPage }
        return self
    }
}

enum SessionHistoryReadError: LocalizedError {
    case invalidPage
    var errorDescription: String? { "History changed or returned an invalid page. Reload to try again." }
}

struct SessionHistoryReadIdentity: Hashable, Sendable {
    let profileID: String
    let target: SessionPresentationIdentity
    let runtimeGeneration: String
    let reconciliationGeneration: Int

    @MainActor static func current(model: AppModel, sessionID: String) -> Self? {
        guard model.connectionState == .connected, !model.isReconcilingForeground,
              let profile = model.selectedGatewayProfileID(),
              let target = model.presentationTarget(for: sessionID), model.hasMountedSessionAuthority(target),
              let snapshot = model.authoritativeSnapshot(for: sessionID) else { return nil }
        return Self(profileID: profile, target: target, runtimeGeneration: snapshot.runtimeGeneration,
                    reconciliationGeneration: model.foregroundReconciliationGeneration)
    }
}

/// A presentation-owned page, never a session mirror. Explicit Older/Newer
/// navigation replaces one bounded window only at the reader's request.
@MainActor @Observable
final class SessionHistoryStore {
    private(set) var page: SessionHistoryPage?
    private(set) var pageCursor: SessionHistoryCursor?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var identity: SessionHistoryReadIdentity?
    /// A new explicit batch owns a fresh native scroll viewport. Refreshes and
    /// failures never advance this identity or discard the reader's position.
    private(set) var viewportGeneration = 0
    private var generation = 0
    private var requestedCursor: SessionHistoryCursor?

    func suspend() { generation &+= 1; loading = false }

    func load(identity: SessionHistoryReadIdentity, cursor: SessionHistoryCursor?, resetViewport: Bool = false,
              request: @Sendable (String, JSONValue) async throws -> JSONValue,
              isCurrent: @MainActor () -> Bool) async -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        guard !loading || self.identity != identity || requestedCursor != cursor else { return false }
        requestedCursor = cursor
        generation &+= 1
        let ticket = generation
        if self.identity != identity { page = nil; pageCursor = nil }
        self.identity = identity
        loading = true; error = nil
        do {
            var params: [String: JSONValue] = ["sessionId": .string(identity.target.sessionID),
                "runtimeGeneration": .string(identity.runtimeGeneration)]
            if let cursor { params["cursor"] = try JSONValue.encode(cursor) }
            let raw = try await request("session.history.list", .object(params))
            guard !Task.isCancelled, ticket == generation, isCurrent() else { return false }
            let loaded = try raw.decode(SessionHistoryPage.self).admitted(runtime: identity.runtimeGeneration, cursor: cursor)
            // Publish the page and its viewport identity in the same MainActor
            // turn: no scroll command can race the lazy rows' installation.
            page = loaded
            pageCursor = cursor
            if resetViewport { viewportGeneration &+= 1 }
            loading = false
            return true
        } catch {
            guard !Task.isCancelled, ticket == generation, isCurrent() else { return false }
            self.error = error.localizedDescription; loading = false
            return false
        }
    }
}

@MainActor @Observable
final class SessionHistoryEntryStore {
    private(set) var page: SessionHistoryEntryPage?
    private(set) var loading = false
    private(set) var error: String?
    private var generation = 0
    private var identity: SessionHistoryReadIdentity?
    private var entryID: String?
    private var requestedOffset = 0

    func suspend() { generation &+= 1; loading = false }

    func load(identity: SessionHistoryReadIdentity, entryID: String, offset: Int,
              request: @Sendable (String, JSONValue) async throws -> JSONValue,
              isCurrent: @MainActor () -> Bool) async {
        guard !Task.isCancelled, isCurrent() else { return }
        guard !loading || self.identity != identity || self.entryID != entryID || requestedOffset != offset else { return }
        requestedOffset = offset
        generation &+= 1
        let ticket = generation
        if self.identity != identity || self.entryID != entryID { page = nil }
        self.identity = identity; self.entryID = entryID
        loading = true; error = nil
        do {
            let raw = try await request("session.history.entry", .object([
                "sessionId": .string(identity.target.sessionID), "runtimeGeneration": .string(identity.runtimeGeneration),
                "entryId": .string(entryID), "offset": .number(Double(offset))
            ]))
            guard !Task.isCancelled, ticket == generation, isCurrent() else { return }
            page = try raw.decode(SessionHistoryEntryPage.self).admitted(runtime: identity.runtimeGeneration, entry: entryID, requestedOffset: offset)
            loading = false
        } catch {
            guard !Task.isCancelled, ticket == generation, isCurrent() else { return }
            self.error = error.localizedDescription; loading = false
        }
    }
}
