import Foundation
import Observation

/// A sheet owns one immutable document and at most one parser. Replacement waits
/// for the cancelled parser to drain instead of accumulating detached work.
@MainActor
@Observable
final class ChatDetailDocumentPreparation {
    typealias Prepare = @Sendable (String) async throws -> MarkdownPresentation.Document
    private(set) var document: MarkdownPresentation.Document?
    private(set) var revision = 0
    private var task: Task<MarkdownPresentation.Document, Error>?
    private var request = 0
    private var mountedRevision: Int?
    private let prepare: Prepare
    private let clock: MonotonicClock

    init(clock: MonotonicClock = .continuous, prepare: @escaping Prepare = { source in
        try Task.checkCancellation()
        return MarkdownPresentation.Document(source: source)
    }) {
        self.clock = clock
        self.prepare = prepare
    }

    func load(
        source: String,
        isCurrent: @MainActor () -> Bool,
        record: @MainActor (String) -> Void
    ) async {
        guard isCurrent(), !Task.isCancelled else { return }
        if document?.source == source { return }
        request &+= 1
        let ticket = request
        let queuedAt = clock.now()
        record("phase=requested generation=\(ticket) sourceBytes=\(source.utf8.count)")
        let predecessor = task
        predecessor?.cancel()
        if let predecessor { _ = try? await predecessor.value }
        guard request == ticket, isCurrent(), !Task.isCancelled else {
            record("phase=discarded generation=\(ticket)")
            return
        }
        let started = clock.now()
        record("phase=prepare-start generation=\(ticket) queueMs=\(diagnosticMilliseconds(queuedAt.duration(to: started)))")
        let prepare = self.prepare
        let parser = Task.detached(priority: .userInitiated) { try await prepare(source) }
        task = parser
        do {
            let result = try await withTaskCancellationHandler {
                try await parser.value
            } onCancel: { parser.cancel() }
            let elapsed = diagnosticMilliseconds(started.duration(to: clock.now()))
            guard request == ticket, isCurrent(), !Task.isCancelled else {
                record("phase=discarded generation=\(ticket) parseMs=\(elapsed)")
                if request == ticket { task = nil }
                return
            }
            document = result
            revision = ticket
            task = nil
            record("phase=prepared generation=\(ticket) parseMs=\(elapsed) sourceBytes=\(source.utf8.count)")
        } catch {
            if request == ticket { task = nil }
            record("phase=cancelled generation=\(ticket)")
        }
    }

    func mounted(record: (String) -> Void) {
        guard document != nil, mountedRevision != revision else { return }
        mountedRevision = revision
        // SwiftUI mounting is not proof of a physically displayed/rendered frame.
        record("phase=content-mounted generation=\(revision)")
    }

    func retire(record: (String) -> Void) {
        request &+= 1
        task?.cancel()
        record("phase=dismissed generation=\(revision)")
    }
}
