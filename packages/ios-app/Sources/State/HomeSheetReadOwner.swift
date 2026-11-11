import Foundation
import Observation
import TronMobileCore

extension HomeMemoryEvidence {
    var valid: Bool {
        index >= 0 && [sessionId, entryId].allSatisfy { !$0.isEmpty && $0.utf8.count <= 200 }
            && Self.isDigest(sourceDigest)
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

extension HomeMemoryItem: Identifiable {
    package var id: Int { index }
    var valid: Bool {
        let expected: HomeMemoryItemAttribution = switch kind { case .user: .user; case .talk: .assistant; case .echo: .tool; case .event: .event }
        return evidence.valid && evidence.index == index && attribution == expected
            && projection.text.utf16.count <= 4096
            && (summary.value.map { $0.text.utf16.count <= 4096 } ?? true)
    }
}

extension HomeMemoryViewLine: Identifiable {
    package var id: String { "\(start)+\(span)" }
    var isSummary: Bool { span > 1 }
    var valid: Bool {
        start >= 0 && span >= 1 && span & (span - 1) == 0 && start % span == 0
            && (!startsIndividualMessages || (inCurrentView && span == 1 && start > 0))
            && (text.value?.utf16.count ?? 0) <= 4096
            && [firstAt ?? "", lastAt ?? ""].allSatisfy { $0.utf8.count <= 64 }
            && (span == 1 ? item.map { $0.valid && $0.index == start && $0.kind == kind } == true : item == nil && kind == nil)
    }
}

extension HomeMemoryView {
    struct Continuation: Hashable, Sendable {
        let cursor: String
        let revision: String
        let homeId: String
    }

    static func validated(_ value: JSONValue, continuation: Continuation?, part: HomeMemoryViewLine? = nil) throws -> Self {
        let data = try JSONEncoder.gateway.encode(value)
        let view = try value.decodeWire(Self.decode)
        guard data.count <= 128 * 1024, !view.homeId.isEmpty, view.homeId.utf8.count <= 200,
              HomeMemoryEvidence.isDigest(view.revision), view.totalMessages >= 0, view.lines.count <= 50,
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

extension HomeMemoryEvidencePage {
    static func validated(_ value: JSONValue, evidence identity: HomeMemoryEvidence, offset requestedOffset: Int) throws -> Self {
        let page = try value.decodeWire(Self.decode)
        guard identity.valid, page.evidence == identity,
              page.offset == requestedOffset, page.offset >= 0,
              page.text.utf16.count <= 24_000, page.totalCharacters >= page.offset,
              page.text.utf16.count <= page.totalCharacters - page.offset else { throw invalidHomeRead() }
        let end = page.offset + page.text.utf16.count
        guard (end < page.totalCharacters ? page.nextOffset == end && end > page.offset : page.nextOffset == nil),
              page.previousOffset.map({ $0 >= 0 && $0 < page.offset }) ?? (page.offset == 0) else { throw invalidHomeRead() }
        return page
    }
}

extension HomeChapterSummary: Identifiable {
    package var id: Int { ordinal }
    var valid: Bool {
        !sessionId.isEmpty && sessionId.utf8.count <= 512 && ordinal > 0
            && [createdAt, sealedAt ?? ""].allSatisfy { $0.utf8.count <= 64 }
            && (bytes ?? 0) >= 0 && (entries ?? 0) >= 0
            && (contents.map(\.valid) ?? true)
    }
}

extension HomeChapterContents {
    var valid: Bool {
        [userMessages, homeReplies, tasksDelegated].allSatisfy { $0 >= 0 }
            && topics.count <= 8 && topics.allSatisfy { $0.count <= 1000 }
    }
}

extension HomeChapterList {
    static func validated(_ value: JSONValue) throws -> Self {
        let list = try value.decodeWire(Self.decode)
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

extension HomeContextProjection {
    var breakdown: HomeContextBreakdown? {
        guard case .availableTrue(_, _, _, _, _, _, let breakdown, _, _) = self else { return nil }
        return breakdown
    }

    static func statesOpen(_ activation: JSONValue?) -> Bool {
        guard let object = activation?.objectValue, object["available"] == .bool(true) else { return true }
        return object["activationOpen"]?.boolValue != nil
    }

    static func validated(_ value: JSONValue) throws -> Self {
        let context = try value.decodeWire(Self.decode)
        guard statesOpen(value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Available activation must state whether it is open"))
        }
        if let breakdown = context.breakdown {
            guard breakdown.sections.count <= 6, breakdown.effectiveTokens >= 0, breakdown.contextWindow > 0,
                  breakdown.sections.allSatisfy({ $0.tokens >= 0 && ($0.count ?? 0) >= 0 }),
                  Set(breakdown.sections.map(\.id)).count == breakdown.sections.count else { throw invalidHomeRead() }
        }
        return context
    }
}

struct HomeManageDTO: Equatable, Sendable {
    let status: HomeStatus
    let context: HomeContextProjection
    let chapters: HomeChapterList?
    let tasks: HomeTaskPage?
    let permissions: HomeTaskPermissionsDTO?
    var profile: HomeProfileList? = nil
}

struct HomeProfileChange: Encodable, Equatable, Sendable {
    enum Action: String, Encodable, Sendable { case confirm, refine, supersede, retire }
    let action: Action
    let id: String
    let expectedRevision: String
    var text: String? = nil
    var kind: String? = nil
    var reason: String? = nil
}

struct HomeProfileChangeResultDTO: Decodable, Sendable {
    struct Change: Decodable, Sendable { let changeId: String }
    let changes: [Change]
}

extension HomeProfileListItem: Identifiable {
    var valid: Bool {
        !id.isEmpty && id.utf8.count <= 200 && !revisionId.isEmpty && revisionId.utf8.count <= 200
            && !path.isEmpty && path.utf8.count <= 131 && text.utf16.count <= 4096 && [createdAt, updatedAt].allSatisfy { $0.utf8.count <= 64 }
    }
}

extension HomeProfileList {
    var active: [HomeProfileListItem] { items.filter { $0.status == .active } }

    static func validated(_ value: JSONValue) throws -> Self {
        let list = try value.decodeWire(Self.decode)
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

    static func manageSubtitle(_ chapter: HomeStatusChapter) -> String {
        let count = chapter.count == 1 ? "1 chapter" : "\(chapter.count.formatted()) chapters"
        switch chapter.recoveryDecision {
        case .none: return count
        case .reserved: return "\(count) · Successor reserved"
        case .materializing: return "\(count) · Materializing"
        }
    }

    static func stateLabel(_ state: HomeChapterSummaryState) -> String {
        switch state {
        case .active: "Active"
        case .sealed: "Sealed"
        case .reserved: "Reserved"
        case .materializing: "Materializing"
        }
    }

    static func softPercent(_ chapter: HomeChapterSummary, limits: HomeChapterListLimits) -> Int? {
        guard let bytes = chapter.bytes, let entries = chapter.entries else { return nil }
        return max(ratio(bytes, limits.softBytes), ratio(entries, limits.softEntries))
    }

    static func limitPercent(_ chapter: HomeChapterSummary, limits: HomeChapterListLimits) -> Int? {
        guard let bytes = chapter.bytes, let entries = chapter.entries else { return nil }
        let soft = max(ratio(bytes, limits.softBytes), ratio(entries, limits.softEntries))
        return soft < 100 ? soft : max(ratio(bytes, limits.hardBytes), ratio(entries, limits.hardEntries))
    }

    static func contentsLines(_ contents: HomeChapterContents) -> [(icon: String, text: String)] {
        let messages = contents.userMessages, replies = contents.homeReplies, delegated = contents.tasksDelegated
        return [("person", "\(messages.formatted()) \(messages == 1 ? "user message" : "user messages")"),
                ("house", "\(replies.formatted()) Home \(replies == 1 ? "reply" : "replies")"),
                ("checklist", "\(delegated.formatted()) \(delegated == 1 ? "task" : "tasks") delegated")]
    }

    static func dateRange(_ chapter: HomeChapterSummary) -> String {
        guard let start = GatewayTimestamp.parse(chapter.createdAt) else { return "Dates unavailable" }
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        guard let sealed = chapter.sealedAt else { return "Since \(start.formatted(style))" }
        guard let end = GatewayTimestamp.parse(sealed) else { return "Dates unavailable" }
        let from = start.formatted(style)
        let to = end.formatted(style)
        return from == to ? from : "\(from) – \(to)"
    }

    static func sizeLine(_ chapter: HomeChapterSummary, limits: HomeChapterListLimits) -> String {
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
    case memory(sessionID: String?, continuation: HomeMemoryView.Continuation?)
    case memoryPart(sessionID: String?, HomeMemoryViewLine)
    case evidence(HomeMemoryEvidence, offset: Int)
}

enum HomeSheetContent {
    case manage(HomeManageDTO)
    case status(HomeStatus)
    case tasks(HomeTaskPage?, HomeStatus), task(HomeTaskStatusResult?, HomeStatus), permissions(HomeTaskPermissionsDTO?, HomeStatus)
    case taskHistory(HomeTaskHistoryPage)
    case chapters(HomeChapterList)
    case profile(HomeProfileList)
    case memory(HomeMemoryView)
    case evidence(HomeMemoryEvidencePage)
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
