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

/// Typed projection of `home.chapterList` (#740): the whole chapter ledger in
/// ledger order with the Gateway's shared soft and hard rollover limits. Absent
/// sizes mean unmeasured, never zero; decode fails closed on protocol drift.
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
        /// What the chapter holds, from the Gateway's bounded ledger; absent on an older Gateway.
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
        /// At most five of the chapter's newest memory summaries, each at most 120 characters.
        let topics: [String]?
        var valid: Bool {
            [userMessages, homeReplies, tasksDelegated].allSatisfy { ($0 ?? 0) >= 0 }
                && (topics?.count ?? 0) <= 5 && (topics ?? []).allSatisfy { $0.count <= 120 }
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

/// Typed projection of `home.context`: the activation's request sizes, plus the
/// body-free breakdown of the context window when the Gateway reports one. An
/// older Gateway omits `breakdown`, and the sheet keeps the plain fields.
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
            /// Notes, summary lines, entries or results, when the section has a count.
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

/// The Manage Home main sheet's one owner load: every read it presents, admitted
/// by the same status. Task and permission reads are absent while task recovery
/// is closed, and chapters are absent on a Gateway without the chapter list.
struct HomeManageDTO: Equatable, Sendable {
    let status: HomeStatusDTO
    let context: HomeContextDTO
    let chapters: HomeChapterListDTO?
    let tasks: HomeTaskPageDTO?
    let permissions: HomeTaskPermissionsDTO?
}

/// The Home context and memory text the sheets show, derived in one owner so the
/// rows and their tests describe the same meanings.
enum HomeContextPresentation {
    static func sectionLabel(_ id: HomeContextDTO.Breakdown.Section.ID, input: HomeContextDTO.Breakdown.Activation.Kind) -> String {
        switch id {
        case .instructions: "Instructions"
        case .profile: "About you"
        case .memory: "Memory"
        case .chapter: "This chapter"
        case .results: "Task results"
        case .input: input == .wake ? "Wake" : "Your message"
        }
    }

    static func meaning(_ id: HomeContextDTO.Breakdown.Section.ID, input: HomeContextDTO.Breakdown.Activation.Kind) -> String {
        switch id {
        case .instructions: "Tron's base instructions and Home's operating context"
        case .profile: "What Home has learned about you"
        case .memory: "Summaries of earlier conversation Home can recall"
        case .chapter: "This chapter's recent turns, sent live"
        case .results: "Finished task results delivered in this activation"
        case .input: input == .wake ? "The trigger that started this activation" : "The message you sent"
        }
    }

    /// The count the section names, in the words of its meaning ("3 notes").
    static func countLine(_ section: HomeContextDTO.Breakdown.Section) -> String? {
        guard let count = section.count else { return nil }
        switch section.id {
        case .profile: return "\(count.formatted()) \(count == 1 ? "note" : "notes")"
        case .memory: return "\(count.formatted()) \(count == 1 ? "summary" : "summaries")"
        case .chapter: return "\(count.formatted()) \(count == 1 ? "entry" : "entries")"
        case .results: return "\(count.formatted()) delivered"
        case .instructions, .input: return nil
        }
    }

    /// Activation header: what started it, how long ago, and whether it still runs.
    static func activationLine(_ activation: HomeContextDTO.Breakdown.Activation, now: Date = .now) -> String {
        let kind = activation.kind == .wake ? "Wake" : "Your message"
        let state = activation.state == .running ? "Running" : "Settled"
        guard let started = HomeChapterPresentation.parse(activation.startedAt) else { return "\(kind) · \(state)" }
        let relative = RelativeDateTimeFormatter().localizedString(for: started, relativeTo: now)
        return "\(kind) · \(relative) · \(state)"
    }
}

/// One owner of the chapter rows' derived text, so the sheet and its tests
/// describe the same ledger identically.
enum HomeChapterPresentation {
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

    /// The soft-limit share of a chapter, the larger of its bytes and entries, so
    /// the size bar and the row's subtitle read the same measurement.
    static func softPercent(_ chapter: HomeChapterListDTO.Chapter, limits: HomeChapterListDTO.Limits) -> Int? {
        guard let bytes = chapter.bytes, let entries = chapter.entries else { return nil }
        return max(ratio(bytes, limits.softBytes), ratio(entries, limits.softEntries))
    }

    /// Contents as rows: counts the Gateway measured, and topics it named.
    static func contentsLines(_ contents: HomeChapterListDTO.Contents) -> [String] {
        var lines: [String] = []
        if let messages = contents.userMessages { lines.append("\(messages.formatted()) \(messages == 1 ? "user message" : "user messages")") }
        if let replies = contents.homeReplies { lines.append("\(replies.formatted()) Home \(replies == 1 ? "reply" : "replies")") }
        if let delegated = contents.tasksDelegated { lines.append("\(delegated.formatted()) \(delegated == 1 ? "task" : "tasks") delegated") }
        return lines
    }

    /// `createdAt` to `sealedAt`, or open-ended for the chapter still being written.
    static func dateRange(_ chapter: HomeChapterListDTO.Chapter) -> String {
        guard let start = parse(chapter.createdAt) else { return "Dates unavailable" }
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        guard let sealed = chapter.sealedAt else { return "Since \(start.formatted(style))" }
        guard let end = parse(sealed) else { return "Dates unavailable" }
        let from = start.formatted(style)
        let to = end.formatted(style)
        return from == to ? from : "\(from) – \(to)"
    }

    /// Measured size against the shared rollover limits; unmeasured is named,
    /// never shown as zero.
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

    static func parse(_ timestamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: timestamp) { return date }
        return ISO8601DateFormatter().date(from: timestamp)
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
    case context
    case tasks(String?), task(String), permissions
    case chapters
    /// One chapter's memory when `sessionID` is set; otherwise the whole memory view.
    case memory(sessionID: String?, continuation: HomeMemoryPageDTO.Continuation?)
    case evidence(HomeMemoryEvidenceDTO, offset: Int)
}

enum HomeSheetContent {
    case manage(HomeManageDTO)
    case context(HomeContextDTO)
    case tasks(HomeTaskPageDTO?, HomeStatusDTO), task(HomeTaskDTO?, HomeStatusDTO), permissions(HomeTaskPermissionsDTO?, HomeStatusDTO)
    case chapters(HomeChapterListDTO)
    /// The page, and the chapter ordinal of each session it names, from the chapter list.
    case memory(HomeMemoryPageDTO, chapterOrdinals: [String: Int])
    case evidence(HomeMemoryEvidencePageDTO)
}

/// One page, one request, one sheet lifetime. Keeping the request in the state
/// makes replacement/retirement invalidate all outcomes, not just successes.
@MainActor @Observable
final class HomeSheetReadOwner {
    /// `requestID` is the caller's request. `loadID` is this single `load` call,
    /// so a rerun of the same request is never equal to the run it replaces.
    struct Read: Equatable {
        let requestID: UUID
        let loadID: UUID
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
        let read = Read(requestID: requestID, loadID: UUID(), identity: identity)
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
