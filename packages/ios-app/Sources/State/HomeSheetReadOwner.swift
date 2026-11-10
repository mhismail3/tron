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
            && Self.isDigest(sourceDigest)
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct HomeMemoryItemDTO: Decodable, Equatable, Hashable, Sendable, Identifiable {
    enum Kind: String, Decodable, Sendable { case user, talk, echo, event }
    enum Attribution: String, Decodable, Sendable { case user, assistant, tool, event }
    struct Display: Decodable, Equatable, Hashable, Sendable {
        enum Kind: String, Decodable, Sendable { case message; case toolCall = "tool-call"; case toolResult = "tool-result" }
        let kind: Kind
        let toolName: String?
        let target: String?
        let toolCount: Int?
        let status: String?
    }
    struct Projection: Decodable, Equatable, Hashable, Sendable {
        let format: String
        let text: String
        let omitted: Bool
        let omissions: [String]
    }
    struct Summary: Decodable, Equatable, Hashable, Sendable {
        let format: String
        let text: String
        let truncated: Bool
    }
    let index: Int
    let kind: Kind
    let attribution: Attribution
    let timestamp: String?
    let evidence: HomeMemoryEvidenceDTO
    let display: Display?
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

struct HomeMemoryViewDTO: Decodable, Equatable, Sendable {
    struct Line: Decodable, Equatable, Hashable, Sendable, Identifiable {
        let start: Int
        let span: Int
        let text: String?
        let truncated: Bool
        let inCurrentView: Bool
        let startsIndividualMessages: Bool
        let kind: HomeMemoryItemDTO.Kind?
        let firstAt: String?
        let lastAt: String?
        let item: HomeMemoryItemDTO?
        var id: String { "\(start)+\(span)" }
        var isSummary: Bool { span > 1 }
        var valid: Bool {
            start >= 0 && span >= 1 && span & (span - 1) == 0 && start % span == 0
                && (!startsIndividualMessages || (inCurrentView && span == 1 && start > 0))
                && (text?.utf16.count ?? 0) <= 4096
                && [firstAt ?? "", lastAt ?? ""].allSatisfy { $0.utf8.count <= 64 }
                && (span == 1 ? item.map { $0.valid && $0.index == start && $0.kind == kind } == true : item == nil && kind == nil)
        }
    }
    let homeId: String
    let revision: String
    let totalMessages: Int
    let lines: [Line]
    let nextCursor: String?

    struct Continuation: Hashable, Sendable {
        let cursor: String
        let revision: String
        let homeId: String
    }

    static func decode(_ value: JSONValue, continuation: Continuation?, part: Line? = nil) throws -> Self {
        let data = try JSONEncoder.gateway.encode(value)
        let view = try JSONDecoder.gateway.decode(Self.self, from: data)
        guard data.count <= 128 * 1024, !view.homeId.isEmpty, view.homeId.utf8.count <= 200,
              HomeMemoryEvidenceDTO.isDigest(view.revision), view.totalMessages >= 0, view.lines.count <= 50,
              view.lines.allSatisfy(\.valid),
              view.nextCursor.map({ !$0.isEmpty && $0.utf8.count <= 1024 && !view.lines.isEmpty }) ?? true else {
            throw invalidHomeRead()
        }
        if let continuation {
            guard view.homeId == continuation.homeId, view.revision == continuation.revision,
                  view.nextCursor != continuation.cursor else { throw invalidHomeRead() }
        }
        if let part {
            let half = part.span / 2
            guard view.nextCursor == nil, view.lines.map(\.start) == [part.start, part.start + half],
                  view.lines.allSatisfy({ $0.span == half }) else { throw invalidHomeRead() }
        } else {
            guard zip(view.lines, view.lines.dropFirst()).allSatisfy({ $0.start >= $1.start + $1.span }) else { throw invalidHomeRead() }
        }
        return view
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

struct HomeChapterListDTO: Decodable, Equatable, Sendable {
    struct Chapter: Decodable, Equatable, Sendable, Identifiable {
        enum State: String, Decodable, Sendable { case active, sealed, reserved, materializing }
        let sessionId: String
        let ordinal: Int
        let state: State
        let createdAt: String
        let activationStarted: Bool
        let sessionPresent: Bool
        let sealedAt: String?
        let bytes: Int?
        let entries: Int?
        let contents: Contents?
        var id: Int { ordinal }
        var valid: Bool {
            !sessionId.isEmpty && sessionId.utf8.count <= 512 && ordinal > 0
                && [createdAt, sealedAt ?? ""].allSatisfy { $0.utf8.count <= 64 }
                && (bytes ?? 0) >= 0 && (entries ?? 0) >= 0
                && (contents.map(\.valid) ?? true)
        }
    }
    struct Contents: Decodable, Equatable, Sendable {
        let firstAt: String?
        let lastAt: String?
        let userMessages: Int?
        let homeReplies: Int?
        let tasksDelegated: Int?
        let topics: [String]?
        var valid: Bool {
            [userMessages, homeReplies, tasksDelegated].allSatisfy { ($0 ?? 0) >= 0 }
                && (topics?.count ?? 0) <= 8 && (topics ?? []).allSatisfy { $0.count <= 1000 }
        }
    }
    struct Limits: Decodable, Equatable, Sendable {
        let softBytes: Int
        let softEntries: Int
        let hardBytes: Int
        let hardEntries: Int
    }
    let homeId: String
    let generation: Int
    let enabled: Bool
    let limits: Limits
    let chapters: [Chapter]

    static func decode(_ value: JSONValue) throws -> Self {
        let list = try value.decode(Self.self)
        guard !list.homeId.isEmpty, list.homeId.utf8.count <= 200, list.generation >= 0,
              list.limits.softBytes > 0, list.limits.softEntries > 0,
              list.limits.hardBytes >= list.limits.softBytes, list.limits.hardEntries >= list.limits.softEntries,
              !list.chapters.isEmpty, list.chapters.count <= 100_000,
              list.chapters.allSatisfy(\.valid),
              zip(list.chapters, list.chapters.dropFirst()).allSatisfy({ $0.ordinal < $1.ordinal }) else {
            throw invalidHomeRead()
        }
        return list
    }
}

struct HomeContextDTO: Equatable, Sendable {
    struct Breakdown: Decodable, Equatable, Sendable {
        struct Activation: Decodable, Equatable, Sendable {
            enum State: String, Decodable, Sendable { case running, settled }
            enum Kind: String, Decodable, Sendable { case user, wake }
            let state: State
            let kind: Kind
            let startedAt: String
        }
        struct Section: Decodable, Equatable, Sendable, Identifiable {
            enum ID: String, Decodable, Sendable { case instructions, profile, memory, chapter, results, input }
            let id: ID
            let tokens: Int
            let count: Int?
        }
        let activation: Activation
        let contextWindow: Int
        let effectiveTokens: Int
        let sections: [Section]
    }

    let activation: HomeStatusDTO.Activation
    let breakdown: Breakdown?

    private struct Wire: Decodable { let breakdown: Breakdown? }

    static func decode(_ value: JSONValue) throws -> Self {
        let activation = try value.decode(HomeStatusDTO.Activation.self)
        let wire = try value.decode(Wire.self)
        if let breakdown = wire.breakdown {
            guard breakdown.sections.count <= 6, breakdown.effectiveTokens >= 0, breakdown.contextWindow > 0,
                  breakdown.sections.allSatisfy({ $0.tokens >= 0 && ($0.count ?? 0) >= 0 }),
                  Set(breakdown.sections.map(\.id)).count == breakdown.sections.count else { throw invalidHomeRead() }
        }
        return Self(activation: activation, breakdown: wire.breakdown)
    }
}

struct HomeManageDTO: Equatable, Sendable {
    let status: HomeStatusDTO
    let context: HomeContextDTO
    let chapters: HomeChapterListDTO?
    let tasks: HomeTaskPageDTO?
    let permissions: HomeTaskPermissionsDTO?
    var profile: HomeProfileListDTO? = nil
}

struct HomeProfileChange: Encodable, Equatable, Sendable {
    enum Action: String, Encodable, Sendable { case confirm, refine, supersede, retire }
    let action: Action
    let id: String
    let expectedRevision: String
    var text: String? = nil
    var kind: HomeProfileListDTO.Item.Kind? = nil
    var reason: String? = nil
}

struct HomeProfileChangeResultDTO: Decodable, Sendable {
    struct Change: Decodable, Sendable { let changeId: String }
    let changes: [Change]
    let items: [HomeProfileListDTO.Item]
}

struct HomeProfileListDTO: Decodable, Equatable, Sendable {
    struct Item: Decodable, Equatable, Hashable, Sendable, Identifiable {
        enum Kind: String, Codable, Sendable, CaseIterable {
            case preference, standingDecision = "standing-decision", delegationDefault = "delegation-default", fact, correction
        }
        enum Status: String, Decodable, Sendable { case active, superseded, retired }
        let id: String
        let revisionId: String
        let path: String
        let kind: Kind
        let text: String
        let confirmed: Bool
        let status: Status
        let createdAt: String
        let updatedAt: String
        var valid: Bool {
            !id.isEmpty && id.utf8.count <= 200 && !revisionId.isEmpty && revisionId.utf8.count <= 200
                && !path.isEmpty && path.utf8.count <= 131 && text.utf16.count <= 4096 && [createdAt, updatedAt].allSatisfy { $0.utf8.count <= 64 }
        }
    }
    let items: [Item]
    let unclassified: Int

    var active: [Item] { items.filter { $0.status == .active } }

    static func decode(_ value: JSONValue) throws -> Self {
        let list = try value.decode(Self.self)
        guard list.unclassified >= 0, list.items.count <= 10_000, list.items.allSatisfy(\.valid),
              Set(list.items.map(\.id)).count == list.items.count else { throw invalidHomeRead() }
        return list
    }
}

enum HomeChapterPresentation {
    static func topicPreview(_ topic: String, limit: Int = 140) -> String {
        let line = topic.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^(?:[-*+]|\d+[.)]|#{1,6})\s+"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        let plain = MarkdownPresentation.Inline(source: line).attributedString.map { String($0.characters) } ?? line
        guard plain.count > limit else { return plain }
        let prefix = String(plain.prefix(limit))
        let cut = prefix.lastIndex(of: " ").map { String(prefix[..<$0]) } ?? prefix
        return cut.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }

    static func manageSubtitle(_ chapter: HomeStatusDTO.Chapter) -> String {
        let count = chapter.count == 1 ? "1 chapter" : "\(chapter.count.formatted()) chapters"
        switch chapter.recoveryDecision {
        case .none: return count
        case .reserved: return "\(count) · Successor reserved"
        case .materializing: return "\(count) · Materializing"
        }
    }

    static func stateLabel(_ state: HomeChapterListDTO.Chapter.State) -> String {
        switch state {
        case .active: "Active"
        case .sealed: "Sealed"
        case .reserved: "Reserved"
        case .materializing: "Materializing"
        }
    }

    static func softPercent(_ chapter: HomeChapterListDTO.Chapter, limits: HomeChapterListDTO.Limits) -> Int? {
        guard let bytes = chapter.bytes, let entries = chapter.entries else { return nil }
        return max(ratio(bytes, limits.softBytes), ratio(entries, limits.softEntries))
    }

    static func limitPercent(_ chapter: HomeChapterListDTO.Chapter, limits: HomeChapterListDTO.Limits) -> Int? {
        guard let bytes = chapter.bytes, let entries = chapter.entries else { return nil }
        let soft = max(ratio(bytes, limits.softBytes), ratio(entries, limits.softEntries))
        return soft < 100 ? soft : max(ratio(bytes, limits.hardBytes), ratio(entries, limits.hardEntries))
    }

    static func contentsLines(_ contents: HomeChapterListDTO.Contents) -> [(icon: String, text: String)] {
        var lines: [(icon: String, text: String)] = []
        if let messages = contents.userMessages { lines.append(("person", "\(messages.formatted()) \(messages == 1 ? "user message" : "user messages")")) }
        if let replies = contents.homeReplies { lines.append(("house", "\(replies.formatted()) Home \(replies == 1 ? "reply" : "replies")")) }
        if let delegated = contents.tasksDelegated { lines.append(("checklist", "\(delegated.formatted()) \(delegated == 1 ? "task" : "tasks") delegated")) }
        return lines
    }

    static func dateRange(_ chapter: HomeChapterListDTO.Chapter) -> String {
        guard let start = GatewayTimestamp.parse(chapter.createdAt) else { return "Dates unavailable" }
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        guard let sealed = chapter.sealedAt else { return "Since \(start.formatted(style))" }
        guard let end = GatewayTimestamp.parse(sealed) else { return "Dates unavailable" }
        let from = start.formatted(style)
        let to = end.formatted(style)
        return from == to ? from : "\(from) – \(to)"
    }

    static func sizeLine(_ chapter: HomeChapterListDTO.Chapter, limits: HomeChapterListDTO.Limits) -> String {
        guard let bytes = chapter.bytes, let entries = chapter.entries else { return "Not measured" }
        let size = "\(entries.formatted()) entries · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary))"
        let soft = max(ratio(bytes, limits.softBytes), ratio(entries, limits.softEntries))
        guard soft < 100 else {
            let hard = max(ratio(bytes, limits.hardBytes), ratio(entries, limits.hardEntries))
            return "\(size) · \(hard)% of hard limit"
        }
        return "\(size) · \(soft)% of soft limit"
    }

    private static func ratio(_ value: Int, _ limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        return Int((Double(value) / Double(limit) * 100).rounded())
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
    case manage
    case status
    case tasks(String?, filter: HomeTaskFilter = .open), task(String), permissions
    case taskHistory(String, cursor: String?)
    case chapters
    case profile
    case memory(sessionID: String?, continuation: HomeMemoryViewDTO.Continuation?)
    case memoryPart(sessionID: String?, HomeMemoryViewDTO.Line)
    case evidence(HomeMemoryEvidenceDTO, offset: Int)
}

enum HomeSheetContent {
    case manage(HomeManageDTO)
    case status(HomeStatusDTO)
    case tasks(HomeTaskPageDTO?, HomeStatusDTO), task(HomeTaskDTO?, HomeStatusDTO), permissions(HomeTaskPermissionsDTO?, HomeStatusDTO)
    case taskHistory(HomeTaskHistoryPageDTO)
    case chapters(HomeChapterListDTO)
    case profile(HomeProfileListDTO)
    case memory(HomeMemoryViewDTO)
    case evidence(HomeMemoryEvidencePageDTO)
}

@MainActor @Observable
final class HomeSheetReadOwner {
    struct Read: Equatable {
        let requestID: UUID
        let loadID: UUID
        let identity: HomeSheetReadIdentity
    }
    enum State {
        case idle, loading(Read, HomeSheetContent?), loaded(Read, HomeSheetContent), failed(Read, String)
    }
    private(set) var state: State = .idle
    @ObservationIgnored private var inFlight: Read?

    func retire() { state = .idle; inFlight = nil }

    func retireLoading() {
        inFlight = nil
        if case .loading(let read, let installed) = state {
            state = installed.map { .loaded(read, $0) } ?? .idle
        }
    }

    func holds(requestID: UUID, identity: HomeSheetReadIdentity) -> Bool {
        if case .loaded(let read, _) = state { return read.requestID == requestID && read.identity == identity }
        return false
    }

    func load(requestID: UUID, identity: HomeSheetReadIdentity, coordinator: PresentationActivityCoordinator,
              isCurrent: @escaping @MainActor () -> Bool,
              fetch: @escaping @MainActor () async throws -> HomeSheetContent) async {
        guard isCurrent(), coordinator.activity(for: identity.surfaceToken).allowsPresentationPublication else {
            retire(); return
        }
        let installed: HomeSheetContent?
        if case .loaded(let previous, let content) = state, previous.requestID == requestID, identity.retainsContent(from: previous.identity) {
            installed = content
        } else { installed = nil }
        let read = Read(requestID: requestID, loadID: UUID(), identity: identity)
        if case .failed(let previous, _) = state, previous.requestID == requestID, identity.retainsContent(from: previous.identity) {
        } else { state = .loading(read, installed) }
        inFlight = read
        let outcome: Result<HomeSheetContent, Error>
        do { outcome = .success(try await fetch()) }
        catch { outcome = .failure(error) }
        guard inFlight == read else { return }
        inFlight = nil
        guard !Task.isCancelled, isCurrent(), coordinator.activity(for: identity.surfaceToken).allowsPresentationPublication else {
            retireLoading(); return
        }
        switch outcome {
        case .success(let content): state = .loaded(read, content)
        case .failure(let error):
            if error is CancellationError { retire() }
            else { state = .failed(read, error.localizedDescription) }
        }
    }
}
