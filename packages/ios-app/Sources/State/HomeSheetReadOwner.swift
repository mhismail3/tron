import Foundation
import Observation
import TronMobileCore

struct HomeMemoryEvidenceDTO: Codable, Equatable, Hashable, Sendable {
    let index: Int
    let sessionId: String
    let entryId: String
    let sourceDigest: String

    var valid: Bool {
        index >= 0 && [sessionId, entryId].allSatisfy { !$0.isEmpty && $0.utf8.count <= 200 }
            && HomeMemoryPageDTO.isDigest(sourceDigest)
    }
}

struct HomeMemoryPageDTO: Decodable, Equatable, Sendable {
    struct Item: Decodable, Equatable, Sendable, Identifiable {
        enum Kind: String, Decodable, Sendable { case user, talk, echo, event }
        enum Attribution: String, Decodable, Sendable { case user, assistant, tool, event }
        struct Projection: Decodable, Equatable, Sendable {
            let format: String
            let text: String
            let omitted: Bool
            let omissions: [String]
        }
        struct Summary: Decodable, Equatable, Sendable {
            let format: String
            let text: String
            let truncated: Bool
        }
        let index: Int
        let kind: Kind
        let attribution: Attribution
        let timestamp: String?
        let evidence: HomeMemoryEvidenceDTO
        let projection: Projection
        let summary: Summary?
        var id: Int { index }
        var valid: Bool {
            let expected: Attribution = switch kind { case .user: .user; case .talk: .assistant; case .echo: .tool; case .event: .event }
            return evidence.valid && evidence.index == index && attribution == expected
                && projection.format == "memory-projection" && projection.text.utf16.count <= 4096
                && (summary.map { $0.format == "memory-summary" && $0.text.utf16.count <= 4096 } ?? true)
        }
    }
    let homeId: String
    let revision: String
    let totalItems: Int
    let items: [Item]
    let nextCursor: String?

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    struct Continuation: Hashable, Sendable {
        let cursor: String
        let revision: String
        let homeId: String
        let afterIndex: Int
    }

    static func decode(_ value: JSONValue, continuation: Continuation?) throws -> Self {
        let page = try decode(value, revision: continuation?.revision)
        if let continuation {
            guard page.homeId == continuation.homeId,
                  page.items.first.map({ $0.index > continuation.afterIndex }) ?? false,
                  page.nextCursor != continuation.cursor else { throw invalidHomeRead() }
        }
        return page
    }

    static func decode(_ value: JSONValue, revision expectedRevision: String?) throws -> Self {
        // Byte admission uses the wire encoder: Foundation's default escapes
        // slashes and can reject a valid page that the Gateway kept below its cap.
        let data = try JSONEncoder.gateway.encode(value)
        let page = try JSONDecoder.gateway.decode(Self.self, from: data)
        guard data.count <= 128 * 1024, !page.homeId.isEmpty, page.homeId.utf8.count <= 200,
              isDigest(page.revision), expectedRevision == nil || expectedRevision == page.revision,
              page.totalItems >= 0, page.items.count <= 50, page.items.count <= page.totalItems,
              page.items.allSatisfy(\.valid),
              zip(page.items, page.items.dropFirst()).allSatisfy({ $0.index < $1.index }),
              page.items.allSatisfy({ $0.index < page.totalItems }),
              page.nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 1024 && !page.items.isEmpty }) ?? true else {
            throw invalidHomeRead()
        }
        return page
    }
}

struct HomeMemoryEvidencePageDTO: Decodable, Equatable, Sendable {
    let format: String
    let evidence: HomeMemoryEvidenceDTO
    let text: String
    let offset: Int
    let nextOffset: Int?
    let previousOffset: Int?
    let totalCharacters: Int
    let metadata: [String: JSONValue]

    static func decode(_ value: JSONValue, evidence identity: HomeMemoryEvidenceDTO, offset requestedOffset: Int) throws -> Self {
        let page = try value.decode(Self.self)
        guard identity.valid, page.format == "canonical-history", page.evidence == identity,
              page.offset == requestedOffset, page.offset >= 0,
              page.text.utf16.count <= 24_000, page.totalCharacters >= page.offset,
              page.text.utf16.count <= page.totalCharacters - page.offset else { throw invalidHomeRead() }
        let end = page.offset + page.text.utf16.count
        guard (end < page.totalCharacters ? page.nextOffset == end && end > page.offset : page.nextOffset == nil),
              page.previousOffset.map({ $0 >= 0 && $0 < page.offset }) ?? (page.offset == 0) else { throw invalidHomeRead() }
        return page
    }
}

private func invalidHomeRead() -> GatewayFailure {
    GatewayFailure(code: "invalid_response", message: "Home returned an invalid bounded page. Reload from the first page.", retryable: false, details: nil)
}

struct HomeSheetReadIdentity: Hashable {
    let profileID: String
    let connectionID: Int
    let lifecycleGeneration: Int
    let surfaceToken: PresentationSurfaceToken
}

enum HomeSheetReadQuery: Hashable, Sendable {
    case status
    case tasks(String?), task(String), permissions
    case memory(HomeMemoryPageDTO.Continuation?)
    case evidence(HomeMemoryEvidenceDTO, offset: Int)
}

enum HomeSheetContent {
    case tasks(HomeTaskPageDTO?, HomeStatusDTO), task(HomeTaskDTO?, HomeStatusDTO), permissions(HomeTaskPermissionsDTO?, HomeStatusDTO)
    case status(HomeStatusDTO), memory(HomeMemoryPageDTO), evidence(HomeMemoryEvidencePageDTO)
}

/// One page, one request, one sheet lifetime. Keeping the request in the state
/// makes replacement/retirement invalidate all outcomes, not just successes.
@MainActor @Observable
final class HomeSheetReadOwner {
    struct Read: Equatable {
        let id: UUID
        let identity: HomeSheetReadIdentity
    }
    enum State {
        case idle, loading(Read, HomeSheetContent?), loaded(Read, HomeSheetContent), failed(Read, String)
    }
    private(set) var state: State = .idle

    func retire() { state = .idle }

    /// Keep an installed frame while its picker/evidence child covers it; only
    /// pending publication is disposable at that transition.
    func retireLoading() {
        if case .loading(let read, let installed) = state {
            state = installed.map { .loaded(read, $0) } ?? .idle
        }
    }

    func load(requestID: UUID, identity: HomeSheetReadIdentity, coordinator: PresentationActivityCoordinator,
              isCurrent: @escaping @MainActor () -> Bool,
              preserveInstalledFrame: Bool = false,
              fetch: @escaping @MainActor () async throws -> HomeSheetContent) async {
        guard isCurrent(), coordinator.activity(for: identity.surfaceToken).allowsPresentationPublication else {
            retire(); return
        }
        let installed: HomeSheetContent?
        if preserveInstalledFrame, case .loaded(let previous, let content) = state, previous.identity == identity {
            installed = content
        } else { installed = nil }
        let read = Read(id: requestID, identity: identity)
        state = .loading(read, installed)
        let outcome: Result<HomeSheetContent, Error>
        do { outcome = .success(try await fetch()) }
        catch { outcome = .failure(error) }
        guard case .loading(let current, _) = state, current == read else { return }
        guard !Task.isCancelled, isCurrent(), coordinator.activity(for: identity.surfaceToken).allowsPresentationPublication else {
            retire(); return
        }
        switch outcome {
        case .success(let content): state = .loaded(read, content)
        case .failure(let error):
            if error is CancellationError { retire() }
            else { state = .failed(read, error.localizedDescription) }
        }
    }
}
