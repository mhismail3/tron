import Foundation
import Observation
import UniformTypeIdentifiers

struct ComposerDraftScope: Hashable, Sendable {
    let profileID: String
    let sessionID: String
}

struct PendingAttachment: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let size: Int
    let previewData: Data?
    let fullPreviewData: Data?
    /// Cached when the attachment is admitted. Handoff identity must not hash
    /// the payload again while the view recomputes its projection tag.
    let previewIdentity: UInt64?

    init(
        id: String,
        name: String,
        mimeType: String,
        size: Int,
        previewData: Data?,
        fullPreviewData: Data? = nil,
        previewIdentity: UInt64? = nil
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.size = size
        let boundedPreview = previewData.map {
            $0.count <= ComposerAttachmentPreviewPolicy.maximumEncodedBytes
                ? $0
                : Data($0.prefix(ComposerAttachmentPreviewPolicy.maximumEncodedBytes))
        }
        self.previewData = boundedPreview
        self.fullPreviewData = fullPreviewData
        self.previewIdentity = previewIdentity ?? boundedPreview.map(Self.identity)
    }

    /// A frozen handoff owns only the bounded thumbnail used by the row. The
    /// upload's full bytes remain available only to the live composer until
    /// this source is admitted to transcript presentation.
    func frozenForHandoff() -> Self {
        Self(
            id: id,
            name: name,
            mimeType: mimeType,
            size: size,
            previewData: previewData,
            fullPreviewData: nil,
            previewIdentity: previewIdentity
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.mimeType == rhs.mimeType
            && lhs.size == rhs.size
            && lhs.previewData == rhs.previewData
            && lhs.previewIdentity == rhs.previewIdentity
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(mimeType)
        hasher.combine(size)
        hasher.combine(previewIdentity)
        // `previewData` is bounded thumbnail data; fullPreviewData is
        // deliberately excluded from value identity and hashing.
    }

    private static func identity(_ data: Data) -> UInt64 {
        var value: UInt64 = 14695981039346656037
        for byte in data {
            value ^= UInt64(byte)
            value &*= 1099511628211
        }
        value ^= UInt64(data.count)
        return value
    }
}

struct ComposerEditorRequest: Identifiable, Hashable, Sendable {
    let sessionID: String
    let presentationGeneration: Int
    let revision: Int
    let action: SessionEditorAction
    let text: String
    let fullText: String

    var id: String { "\(sessionID):\(presentationGeneration):\(revision)" }
}

enum ComposerEditorDisposition: Sendable {
    case use
    case keep
}

enum ComposerEditorRequestPolicy {
    static let confirmationTitle = "Replace the current draft?"
    static let useActionTitle = "Use Extension Text"
    static let keepActionTitle = "Keep Current Draft"
    static let confirmationMessage = "An extension requested a composer change. Tron will not overwrite what you typed without confirmation."

    static func appliesAutomatically(to draft: String) -> Bool {
        draft.isEmpty
    }
}

enum ComposerAttachmentPolicy {
    static let maximumCount = 10
    static let maximumTotalBytes = 25 * 1_048_576

    static func admits(existing: [Int], active: [Int], candidate: Int) -> Bool {
        guard candidate > 0, existing.count + active.count < maximumCount else { return false }
        var total = candidate
        for size in existing + active {
            let (next, overflow) = total.addingReportingOverflow(size)
            guard !overflow else { return false }
            total = next
        }
        return total <= maximumTotalBytes
    }
}

struct ComposerSubmissionSnapshot: Equatable, Sendable {
    let target: SessionPresentationIdentity
    let textRevision: Int
    let localNonce: UInt64?
    let outgoingText: String
    let attachmentIDs: [String]
    let behavior: String?
    let baselineQueuedMessageIDs: Set<String>

    init(
        target: SessionPresentationIdentity,
        textRevision: Int,
        outgoingText: String,
        attachmentIDs: [String],
        behavior: String?,
        baselineQueuedMessageIDs: Set<String> = [],
        localNonce: UInt64? = nil
    ) {
        self.target = target
        self.textRevision = textRevision
        self.localNonce = localNonce
        self.outgoingText = outgoingText
        self.attachmentIDs = attachmentIDs
        self.behavior = behavior
        self.baselineQueuedMessageIDs = baselineQueuedMessageIDs
    }

    /// Stable only for the owning presentation and admitted submission. This
    /// is a presentation identity, never a transcript/event ID. Test fixtures
    /// may omit the nonce and retain the historical deterministic identity.
    var presentationID: String {
        let suffix = localNonce.map(String.init) ?? String(textRevision)
        return "outgoing-submission:\(target.sessionID):\(target.generation):\(suffix)"
    }
}

typealias ComposerUploadOperation = @MainActor @Sendable (
    _ name: String,
    _ mimeType: String,
    _ data: Data
) async throws -> String

typealias ComposerFileUploadOperation = @MainActor @Sendable (
    _ name: String,
    _ mimeType: String,
    _ fileURL: URL,
    _ byteCount: Int
) async throws -> String

@MainActor
struct ComposerAttachmentFileAccess {
    let startAccessing: (URL) -> Bool
    let size: (URL) throws -> Int
    let copy: (URL, URL, Int) async throws -> Void
    let previewData: (URL, Int) async throws -> Data
    let stopAccessing: (URL) -> Void

    static let live = ComposerAttachmentFileAccess(
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        size: { url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            return size
        },
        copy: { source, destination, expectedSize in
            try await BoundedFileCopy.copy(from: source, to: destination, expectedSize: expectedSize)
        },
        previewData: { file, expectedSize in
            let task = Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                guard data.count == expectedSize else { throw BoundedFileCopyError.changedSize }
                return data
            }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() }
    )
}

typealias ComposerSendOperation = @MainActor @Sendable (
    _ text: String,
    _ sessionID: String,
    _ uploadIDs: [String],
    _ behavior: String?
) async throws -> String

enum ComposerDraftTextPolicy {
    static func restoredDraft(outgoing: String, currentDraft: String) -> String {
        guard !outgoing.isEmpty else { return currentDraft }
        guard !currentDraft.isEmpty else { return outgoing }
        return "\(outgoing)\n\(currentDraft)"
    }
}

/// Owns bounded session-scoped composer drafts and exact-presentation transient
/// state. Gateway uploads and sessions remain canonical; staged upload IDs are
/// disposable and never survive presentation revocation.
@MainActor
@Observable
final class ComposerDraftCoordinator {
    static let maxInactiveDrafts = 24

    private struct Draft: Equatable {
        var text: String
        var revision: Int
        var lastAccess: UInt64
    }

    private struct PresentationLease: Equatable {
        let scope: ComposerDraftScope
        let target: SessionPresentationIdentity
        let lifecycleGeneration: Int
    }

    private struct PreparedOpen: Equatable {
        let id: UInt64
        let scope: ComposerDraftScope
        let lifecycleGeneration: Int
    }

    private struct UploadAdmission: Hashable {
        let id: UInt64
        let target: SessionPresentationIdentity
        let lifecycleGeneration: Int
        let bytes: Int
    }

    private enum SubmissionTransportState: Equatable {
        case sending
        case accepted
    }

    private struct SubmissionAdmission: Equatable {
        let id: UInt64
        let snapshot: ComposerSubmissionSnapshot
        let submittedAttachments: [PendingAttachment]
        let baselineTranscriptIDs: Set<String>
        let lifecycleGeneration: Int
        var transportState: SubmissionTransportState
        var operationID: String?
        var observedQueuedCandidateIDs: Set<String>
        var canonicalObserved: Bool
        var transcriptObserved: Bool
        var canonicalHandoffID: String?
    }

    private struct SettledQueueAlias: Equatable {
        let presentationID: String
        let baselineQueueIDs: Set<String>
    }

    private let uploadOperation: ComposerUploadOperation
    private let fileUploadOperation: ComposerFileUploadOperation
    private let attachmentFileAccess: ComposerAttachmentFileAccess
    private let sendOperation: ComposerSendOperation
    @ObservationIgnored private let admitsLifecycleGeneration: @MainActor (Int) -> Bool

    private var drafts: [ComposerDraftScope: Draft] = [:]
    private var preparedOpenBySession: [String: PreparedOpen] = [:]
    private var lease: PresentationLease?
    private var attachmentsByTarget: [SessionPresentationIdentity: [PendingAttachment]] = [:]
    private var editorRequestByTarget: [SessionPresentationIdentity: ComposerEditorRequest] = [:]
    private var uploadAdmissions = Set<UploadAdmission>()
    private var uploadTasks: [UploadAdmission: Task<String, Error>] = [:]
    private var submissionByTarget: [SessionPresentationIdentity: SubmissionAdmission] = [:]
    private var canonicalHandoffReceipts: [SessionPresentationIdentity: [String]] = [:]
    private static let maximumSettledQueueAliases = SessionSnapshot.maximumQueuedMessages
    private var settledQueueAliases: [SessionPresentationIdentity: [String: SettledQueueAlias]] = [:]
    private var sequence: UInt64 = 0

    init(
        upload: @escaping ComposerUploadOperation,
        fileUpload: @escaping ComposerFileUploadOperation,
        attachmentFileAccess: ComposerAttachmentFileAccess = .live,
        send: @escaping ComposerSendOperation,
        admitsLifecycleGeneration: @escaping @MainActor (Int) -> Bool
    ) {
        uploadOperation = upload
        fileUploadOperation = fileUpload
        self.attachmentFileAccess = attachmentFileAccess
        sendOperation = send
        self.admitsLifecycleGeneration = admitsLifecycleGeneration
    }

    func prepareDraft(
        profileID: String,
        sessionID: String,
        initialText: String?
    ) -> ComposerDraftScope {
        let scope = ComposerDraftScope(profileID: profileID, sessionID: sessionID)
        touch(scope, installing: initialText)
        return scope
    }

    func text(for scope: ComposerDraftScope) -> String {
        drafts[scope]?.text ?? ""
    }

    func revision(for scope: ComposerDraftScope) -> Int {
        drafts[scope]?.revision ?? 0
    }

    func setText(_ text: String, for scope: ComposerDraftScope) {
        sequence &+= 1
        var draft = drafts[scope] ?? Draft(text: "", revision: 0, lastAccess: sequence)
        guard draft.text != text else {
            draft.lastAccess = sequence
            drafts[scope] = draft
            return
        }
        draft.text = text
        draft.revision &+= 1
        draft.lastAccess = sequence
        drafts[scope] = draft
        evictInactiveDraftsIfNeeded()
    }

    func openMountedPresentation(
        scope: ComposerDraftScope,
        lifecycleGeneration: Int,
        open: () async throws -> Int,
        finalAdmission: (SessionPresentationIdentity) throws -> Void,
        revokePresentation: (SessionPresentationIdentity) -> Void,
        closePresentation: (SessionPresentationIdentity) async -> Void
    ) async throws -> Int {
        let openID = beginOpening(scope: scope, lifecycleGeneration: lifecycleGeneration)
        do {
            let generation = try await open()
            let target = SessionPresentationIdentity(
                sessionID: scope.sessionID,
                generation: generation
            )
            do {
                try finalAdmission(target)
                guard admits(target) else { throw CancellationError() }
            } catch {
                revoke(target)
                revokePresentation(target)
                await closePresentation(target)
                throw error
            }
            return generation
        } catch {
            cancelOpening(sessionID: scope.sessionID, id: openID)
            throw error
        }
    }

    @discardableResult
    func beginOpening(
        scope: ComposerDraftScope,
        lifecycleGeneration: Int
    ) -> UInt64 {
        sequence &+= 1
        let prepared = PreparedOpen(
            id: sequence,
            scope: scope,
            lifecycleGeneration: lifecycleGeneration
        )
        preparedOpenBySession[scope.sessionID] = prepared
        return prepared.id
    }

    func cancelOpening(sessionID: String, id: UInt64) {
        guard preparedOpenBySession[sessionID]?.id == id else { return }
        preparedOpenBySession[sessionID] = nil
    }

    /// Promotes the newest prepared open before deferred editor effects publish.
    @discardableResult
    func mountPreparedPresentation(_ target: SessionPresentationIdentity) -> Bool {
        guard let prepared = preparedOpenBySession[target.sessionID],
              admitsLifecycleGeneration(prepared.lifecycleGeneration) else {
            return false
        }
        revokePresentation()
        preparedOpenBySession[target.sessionID] = nil
        lease = PresentationLease(
            scope: prepared.scope,
            target: target,
            lifecycleGeneration: prepared.lifecycleGeneration
        )
        touch(prepared.scope, installing: nil)
        return true
    }

    func admits(_ target: SessionPresentationIdentity) -> Bool {
        guard let lease, lease.target == target else { return false }
        return admitsLifecycleGeneration(lease.lifecycleGeneration)
    }

    func scope(for target: SessionPresentationIdentity) -> ComposerDraftScope? {
        guard admits(target) else { return nil }
        return lease?.scope
    }

    func pendingAttachments(for target: SessionPresentationIdentity) -> [PendingAttachment] {
        guard admits(target) else { return [] }
        return attachmentsByTarget[target] ?? []
    }

    func submittedAttachments(for target: SessionPresentationIdentity) -> [PendingAttachment] {
        guard admits(target) else { return [] }
        return submissionByTarget[target]?.submittedAttachments ?? []
    }

    /// Consumes the one-shot canonical replacement receipt created before a
    /// submission admission is retired. The receipt is presentation-only;
    /// canonical transcript IDs remain authoritative.
    func consumeCanonicalSubmissionHandoff(
        target: SessionPresentationIdentity
    ) -> String? {
        guard admits(target), var receipts = canonicalHandoffReceipts[target],
              !receipts.isEmpty else { return nil }
        let receipt = receipts.removeFirst()
        canonicalHandoffReceipts[target] = receipts.isEmpty ? nil : receipts
        return receipt
    }

    func canonicalSubmissionIDs(
        target: SessionPresentationIdentity,
        canonicalTranscript: [TranscriptItem]
    ) -> Set<String> {
        guard admits(target), let admission = submissionByTarget[target] else { return [] }
        let matches = canonicalTranscript.compactMap { item in
            Self.canonicalUserMessage(
                item,
                matches: admission.snapshot,
                submittedAttachments: admission.submittedAttachments,
                baselineTranscriptIDs: admission.baselineTranscriptIDs
            ) ? item.id : nil
        }
        // Presentation suppression is fail-closed for the same reason as
        // reconciliation: never suppress multiple identical canonical rows.
        guard matches.count == 1 else { return [] }
        return Set(matches)
    }

    func editorRequest(for target: SessionPresentationIdentity) -> ComposerEditorRequest? {
        guard admits(target) else { return nil }
        return editorRequestByTarget[target]
    }

    func isSending(target: SessionPresentationIdentity) -> Bool {
        guard admits(target) else { return false }
        return submissionByTarget[target]?.transportState == .sending
    }

    /// The outgoing row is intentionally separate from canonical transcript
    /// projection. It remains visible after transport acknowledgement until a
    /// matching canonical user message is observed for this exact target.
    func outgoingSubmission(for target: SessionPresentationIdentity) -> ComposerSubmissionSnapshot? {
        guard admits(target) else { return nil }
        return submissionByTarget[target]?.snapshot
    }

    func hasPendingSubmission(target: SessionPresentationIdentity) -> Bool {
        outgoingSubmission(for: target) != nil
    }

    /// Returns the exact optimistic identity only when the Gateway queue item
    /// is the admitted operation for this presentation. Arbitrary matching
    /// queue rows never borrow a local identity.
    func queuedSubmissionPresentationID(
        target: SessionPresentationIdentity,
        message: SessionSnapshot.QueuedMessage
    ) -> String? {
        guard admits(target) else { return nil }
        if let admission = submissionByTarget[target],
           let operationID = admission.operationID,
           operationID == message.id,
           admission.snapshot.behavior != nil,
           !admission.snapshot.baselineQueuedMessageIDs.contains(message.id) {
            return admission.snapshot.presentationID
        }
        if let alias = settledQueueAliases[target]?[message.id],
           !alias.baselineQueueIDs.contains(message.id) {
            return alias.presentationID
        }
        return nil
    }

    func hasQueuedSubmission(
        target: SessionPresentationIdentity,
        queuedMessages: [SessionSnapshot.QueuedMessage]
    ) -> Bool {
        queuedMessages.contains {
            queuedSubmissionPresentationID(target: target, message: $0) != nil
        }
    }

    /// Reconciles exactly once against authoritative user-message state. A
    /// transport acknowledgement alone is not enough: canonical JSONL/events
    /// remain the sole source of transcript truth.
    func reconcileSubmission(
        target: SessionPresentationIdentity,
        canonicalTranscript: [TranscriptItem],
        queuedMessages: [SessionSnapshot.QueuedMessage] = []
    ) {
        let queueIDs = queuedMessages.map(\.id)
        guard Set(queueIDs).count == queueIDs.count,
              queuedMessages.count <= SessionSnapshot.maximumQueuedMessages else {
            // Malformed authoritative queue data must not settle a submission
            // or retire an already-settled alias. The projection store rejects
            // the same invalid commit at installation, leaving the current
            // lifecycle row visible while recovery obtains a valid snapshot.
            return
        }
        guard admits(target), var admission = submissionByTarget[target] else {
            retireSettledQueueAliases(
                target: target,
                authoritativeQueueIDs: Set(queuedMessages.map(\.id))
            )
            return
        }
        let canonicalMatches = canonicalTranscript.compactMap { item in
            Self.canonicalUserMessage(
                item,
                matches: admission.snapshot,
                submittedAttachments: admission.submittedAttachments,
                baselineTranscriptIDs: admission.baselineTranscriptIDs
            ) ? item.id : nil
        }
        // A repeated prompt can produce multiple new canonical matches in one
        // snapshot. Keep the admission alive until the authoritative stream
        // makes exactly one causal candidate available; ambiguity must not
        // retire the outgoing row or create a handoff receipt.
        let transcriptObserved = canonicalMatches.count == 1
        admission.canonicalHandoffID = transcriptObserved ? canonicalMatches[0] : nil
        let queuedCandidates = queuedMessages.filter { message in
            guard !admission.snapshot.baselineQueuedMessageIDs.contains(message.id) else {
                return false
            }
            if let operationID = admission.operationID {
                return message.id == operationID
            }
            guard let behavior = admission.snapshot.behavior else { return false }
            return message.behavior.rawValue == behavior
                && message.text == admission.snapshot.outgoingText
                && message.attachmentCount == admission.submittedAttachments.count
        }
        admission.observedQueuedCandidateIDs.formUnion(queuedCandidates.map(\.id))
        admission.transcriptObserved = admission.transcriptObserved || transcriptObserved
        retireSettledQueueAliases(
            target: target,
            authoritativeQueueIDs: Set(queuedMessages.map(\.id))
        )
        if canonicalMatches.count > 1 {
            // Do not let an independent queue observation settle an admission
            // while canonical identity is ambiguous in this snapshot.
            submissionByTarget[target] = admission
            return
        }
        let queuedObserved = admission.operationID.map {
            admission.observedQueuedCandidateIDs.contains($0)
        } ?? false
        guard transcriptObserved || queuedObserved else {
            submissionByTarget[target] = admission
            return
        }
        admission.canonicalObserved = true
        if admission.transportState == .accepted {
            // Publish the enriched local admission before retirement so the
            // exact canonical ID receipt survives this synchronous boundary.
            submissionByTarget[target] = admission
            finishSubmission(admission)
        } else {
            submissionByTarget[target] = admission
        }
    }

    func submissionSnapshot(for target: SessionPresentationIdentity) -> ComposerSubmissionSnapshot? {
        guard admits(target) else { return nil }
        return submissionByTarget[target]?.snapshot
    }

    func upload(
        name: String,
        mimeType: String,
        data: Data,
        target: SessionPresentationIdentity
    ) async throws {
        let admission = try beginUpload(target: target, bytes: data.count)
        defer { uploadAdmissions.remove(admission) }
        let task = Task { try await uploadOperation(name, mimeType, data) }
        uploadTasks[admission] = task
        defer { uploadTasks[admission] = nil }
        let id: String
        do {
            id = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            try require(admission)
            throw error
        }
        let previewData = await ComposerAttachmentPreviewPolicy.prepare(
            data,
            mimeType: mimeType,
            name: name
        )
        try require(admission)
        attachmentsByTarget[target, default: []].append(PendingAttachment(
            id: id,
            name: name,
            mimeType: mimeType,
            size: data.count,
            previewData: previewData,
            fullPreviewData: mimeType.hasPrefix("image/") && previewData != nil ? data : nil
        ))
    }

    func uploadFile(
        _ source: URL,
        target: SessionPresentationIdentity
    ) async throws {
        guard admits(target) else { throw CancellationError() }
        let scoped = attachmentFileAccess.startAccessing(source)
        let size: Int
        do {
            size = try attachmentFileAccess.size(source)
        } catch {
            if scoped { attachmentFileAccess.stopAccessing(source) }
            if error is CancellationError { throw error }
            throw GatewayFailure(
                code: "upload_failed",
                message: "Attachments must be regular files containing 1 byte through 25 MiB.",
                retryable: false,
                details: nil
            )
        }
        guard size > 0, size <= ComposerAttachmentPolicy.maximumTotalBytes else {
            if scoped { attachmentFileAccess.stopAccessing(source) }
            throw GatewayFailure(
                code: "upload_failed",
                message: "Attachments must be regular files containing 1 byte through 25 MiB.",
                retryable: false,
                details: nil
            )
        }
        let admission: UploadAdmission
        do {
            admission = try beginUpload(target: target, bytes: size)
        } catch {
            if scoped { attachmentFileAccess.stopAccessing(source) }
            throw error
        }
        defer { uploadAdmissions.remove(admission) }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "tron-attachment-\(UUID().uuidString)", directoryHint: .isDirectory)
        let staged = directory.appending(path: "content", directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [
                    .posixPermissions: 0o700,
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                ]
            )
            try await attachmentFileAccess.copy(source, staged, size)
        } catch {
            if scoped { attachmentFileAccess.stopAccessing(source) }
            try? FileManager.default.removeItem(at: directory)
            try require(admission)
            if error is BoundedFileCopyError {
                throw GatewayFailure(
                    code: "upload_failed",
                    message: "The attachment changed size while it was being read.",
                    retryable: false,
                    details: nil
                )
            }
            throw error
        }
        if scoped { attachmentFileAccess.stopAccessing(source) }
        defer { try? FileManager.default.removeItem(at: directory) }
        try require(admission)

        let name = source.lastPathComponent
        let mimeType = UTType(filenameExtension: source.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let task = Task { try await fileUploadOperation(name, mimeType, staged, size) }
        uploadTasks[admission] = task
        defer { uploadTasks[admission] = nil }
        let id: String
        do {
            id = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            try require(admission)
            throw error
        }
        let data = try await attachmentFileAccess.previewData(staged, size)
        let previewData = await ComposerAttachmentPreviewPolicy.prepare(
            data,
            mimeType: mimeType,
            name: name
        )
        let fullPreviewData = mimeType.hasPrefix("image/") && previewData != nil ? data : nil
        try require(admission)
        attachmentsByTarget[target, default: []].append(PendingAttachment(
            id: id,
            name: name,
            mimeType: mimeType,
            size: size,
            previewData: previewData,
            fullPreviewData: previewData == nil ? nil : fullPreviewData
        ))
    }

    func removeAttachment(_ id: String, target: SessionPresentationIdentity) {
        guard admits(target), var attachments = attachmentsByTarget[target] else { return }
        attachments.removeAll { $0.id == id }
        attachmentsByTarget[target] = attachments.isEmpty ? nil : attachments
    }

    func send(
        target: SessionPresentationIdentity,
        behavior: String?,
        canonicalTranscript: [TranscriptItem] = [],
        queuedMessages: [SessionSnapshot.QueuedMessage] = []
    ) async throws {
        let submission = try beginSubmission(
            target: target,
            behavior: behavior,
            canonicalTranscript: canonicalTranscript,
            queuedMessages: queuedMessages
        )
        try await transmitSubmission(submission)
    }

    /// Admits the optimistic row, captured attachments, and draft clearing as
    /// one MainActor mutation. Transport is deliberately separate so the UI can
    /// dismiss the keyboard only after this presentation state is installed.
    func beginSubmission(
        target: SessionPresentationIdentity,
        behavior: String?,
        canonicalTranscript: [TranscriptItem] = [],
        queuedMessages: [SessionSnapshot.QueuedMessage] = []
    ) throws -> ComposerSubmissionSnapshot {
        try beginSubmissionAdmission(
            target: target,
            behavior: behavior,
            canonicalTranscript: canonicalTranscript,
            queuedMessages: queuedMessages
        ).snapshot
    }

    /// Sends an already-admitted submission without changing its presentation
    /// shape. A late transport result can only settle this exact admission.
    func transmitSubmission(_ submission: ComposerSubmissionSnapshot) async throws {
        guard let admission = submissionByTarget[submission.target],
              admission.snapshot == submission else {
            throw CancellationError()
        }
        let operationID: String
        do {
            operationID = try await sendOperation(
                admission.snapshot.outgoingText,
                submission.target.sessionID,
                admission.snapshot.attachmentIDs,
                admission.snapshot.behavior
            )
        } catch {
            try require(admission)
            if Self.isPossiblySent(error) {
                markTransportAccepted(admission)
            } else {
                restoreSubmission(admission)
            }
            throw error
        }
        try require(admission)
        markOperationAccepted(operationID, admission: admission)
        markTransportAccepted(admission)
    }

    /// Installs a target-routed editor request. Empty drafts accept immediately;
    /// nonempty drafts require an explicit use/keep disposition from the UI.
    func publishEditorRequest(_ request: ComposerEditorRequest, target: SessionPresentationIdentity) {
        guard admits(target), request.sessionID == target.sessionID,
              request.presentationGeneration == target.generation,
              let scope = lease?.scope else { return }
        if ComposerEditorRequestPolicy.appliesAutomatically(to: text(for: scope)) {
            apply(request, to: scope)
            editorRequestByTarget[target] = nil
        } else {
            editorRequestByTarget[target] = request
        }
    }

    func disposeEditorRequest(
        _ request: ComposerEditorRequest,
        disposition: ComposerEditorDisposition,
        target: SessionPresentationIdentity
    ) {
        guard admits(target), editorRequestByTarget[target]?.id == request.id,
              let scope = lease?.scope else { return }
        if disposition == .use { apply(request, to: scope) }
        editorRequestByTarget[target] = nil
    }

    /// Revokes every presentation-scoped fact synchronously while retaining the
    /// inactive text draft under its explicit profile/session scope.
    func revoke(_ target: SessionPresentationIdentity) {
        guard lease?.target == target else { return }
        revokePresentation()
    }

    func retireProfilePresentation() {
        preparedOpenBySession.removeAll()
        revokePresentation()
    }

    func removeSession(profileID: String, sessionID: String) {
        let scope = ComposerDraftScope(profileID: profileID, sessionID: sessionID)
        drafts[scope] = nil
        preparedOpenBySession[sessionID] = nil
        if lease?.scope == scope { revokePresentation() }
    }

    func removeProfile(_ profileID: String) {
        drafts = drafts.filter { $0.key.profileID != profileID }
        preparedOpenBySession = preparedOpenBySession.filter { $0.value.scope.profileID != profileID }
        if lease?.scope.profileID == profileID { revokePresentation() }
    }

    private func touch(_ scope: ComposerDraftScope, installing initialText: String?) {
        sequence &+= 1
        if var draft = drafts[scope] {
            // Route editor text seeds only a previously absent draft. Reopen or
            // repeated preparation can never replace retained user edits.
            draft.lastAccess = sequence
            drafts[scope] = draft
        } else {
            drafts[scope] = Draft(text: initialText ?? "", revision: initialText == nil ? 0 : 1, lastAccess: sequence)
        }
        evictInactiveDraftsIfNeeded()
    }

    private func beginUpload(target: SessionPresentationIdentity, bytes: Int) throws -> UploadAdmission {
        guard let lease, admits(target) else { throw CancellationError() }
        let existing = (attachmentsByTarget[target] ?? []).map(\.size)
        let active = uploadAdmissions.filter { $0.target == target }.map(\.bytes)
        guard ComposerAttachmentPolicy.admits(existing: existing, active: active, candidate: bytes) else {
            throw GatewayFailure(
                code: "upload_failed",
                message: "Attach at most 10 files totaling 25 MiB.",
                retryable: false,
                details: nil
            )
        }
        sequence &+= 1
        let admission = UploadAdmission(
            id: sequence,
            target: target,
            lifecycleGeneration: lease.lifecycleGeneration,
            bytes: bytes
        )
        uploadAdmissions.insert(admission)
        return admission
    }

    private func require(_ admission: UploadAdmission) throws {
        try Task.checkCancellation()
        guard uploadAdmissions.contains(admission), admits(admission.target),
              lease?.lifecycleGeneration == admission.lifecycleGeneration else {
            throw CancellationError()
        }
    }

    private func beginSubmissionAdmission(
        target: SessionPresentationIdentity,
        behavior: String?,
        canonicalTranscript: [TranscriptItem],
        queuedMessages: [SessionSnapshot.QueuedMessage]
    ) throws -> SubmissionAdmission {
        guard let lease, admits(target), submissionByTarget[target] == nil else {
            throw CancellationError()
        }
        let scope = lease.scope
        let draft = drafts[scope] ?? Draft(text: "", revision: 0, lastAccess: sequence)
        let outgoing = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedAttachments = attachmentsByTarget[target] ?? []
        let attachmentIDs = submittedAttachments.map(\.id)
        guard !outgoing.isEmpty || !attachmentIDs.isEmpty else { throw CancellationError() }
        sequence &+= 1
        let snapshot = ComposerSubmissionSnapshot(
            target: target,
            textRevision: draft.revision,
            outgoingText: outgoing,
            attachmentIDs: attachmentIDs,
            behavior: behavior,
            baselineQueuedMessageIDs: Set(queuedMessages.map(\.id)),
            localNonce: sequence
        )
        let admission = SubmissionAdmission(
            id: sequence,
            snapshot: snapshot,
            submittedAttachments: submittedAttachments,
            baselineTranscriptIDs: Set(canonicalTranscript.map(\.id)),
            lifecycleGeneration: lease.lifecycleGeneration,
            transportState: .sending,
            operationID: nil,
            observedQueuedCandidateIDs: [],
            canonicalObserved: false,
            transcriptObserved: false,
            canonicalHandoffID: nil
        )
        submissionByTarget[target] = admission
        setText("", for: scope)
        return admission
    }

    private func require(_ admission: SubmissionAdmission) throws {
        guard submissionByTarget[admission.snapshot.target]?.id == admission.id,
              admits(admission.snapshot.target),
              lease?.lifecycleGeneration == admission.lifecycleGeneration else {
            throw CancellationError()
        }
    }

    private func restoreSubmission(_ admission: SubmissionAdmission) {
        guard let currentAdmission = submissionByTarget[admission.snapshot.target],
              currentAdmission.id == admission.id,
              let scope = lease?.scope else { return }
        // A canonical event wins even if a late transport failure races it. A
        // definitive rejection without canonical evidence is the only path
        // that restores the draft and submitted attachments.
        guard !currentAdmission.canonicalObserved else {
            finishSubmission(currentAdmission)
            return
        }
        let current = text(for: scope)
        setText(
            ComposerDraftTextPolicy.restoredDraft(
                outgoing: currentAdmission.snapshot.outgoingText,
                currentDraft: current
            ),
            for: scope
        )
        let submittedIDs = Set(currentAdmission.snapshot.attachmentIDs)
        let newerAttachments = (attachmentsByTarget[currentAdmission.snapshot.target] ?? [])
            .filter { !submittedIDs.contains($0.id) }
        attachmentsByTarget[currentAdmission.snapshot.target] = currentAdmission.submittedAttachments + newerAttachments
        submissionByTarget[currentAdmission.snapshot.target] = nil
    }

    private func markOperationAccepted(_ operationID: String, admission: SubmissionAdmission) {
        guard var current = submissionByTarget[admission.snapshot.target],
              current.id == admission.id else { return }
        current.operationID = operationID
        if current.observedQueuedCandidateIDs.contains(operationID) {
            current.canonicalObserved = true
        }
        submissionByTarget[admission.snapshot.target] = current
    }

    private func markTransportAccepted(_ admission: SubmissionAdmission) {
        guard var accepted = submissionByTarget[admission.snapshot.target],
              accepted.id == admission.id else { return }
        accepted.transportState = .accepted
        // Keep the exact captured IDs addressable by the ephemeral row even if
        // the user edited the staged attachment strip while transport awaited
        // acknowledgement. They are removed only at canonical reconciliation.
        let retained = attachmentsByTarget[admission.snapshot.target] ?? []
        let retainedIDs = Set(retained.map(\.id))
        let captured = admission.submittedAttachments.filter { !retainedIDs.contains($0.id) }
        attachmentsByTarget[admission.snapshot.target] = captured + retained
        if accepted.canonicalObserved {
            finishSubmission(accepted)
        } else {
            submissionByTarget[admission.snapshot.target] = accepted
        }
    }

    private func finishSubmission(_ admission: SubmissionAdmission) {
        let target = admission.snapshot.target
        guard let current = submissionByTarget[target], current.id == admission.id else { return }
        if let canonicalHandoffID = current.canonicalHandoffID {
            var receipts = canonicalHandoffReceipts[target] ?? []
            if !receipts.contains(canonicalHandoffID) {
                receipts.append(canonicalHandoffID)
                if receipts.count > SessionSnapshot.maximumQueuedMessages {
                    receipts.removeFirst(receipts.count - SessionSnapshot.maximumQueuedMessages)
                }
                canonicalHandoffReceipts[target] = receipts
            }
        }
        if !current.transcriptObserved,
           let operationID = current.operationID,
           current.snapshot.behavior != nil {
            if !current.snapshot.baselineQueuedMessageIDs.contains(operationID) {
                var aliases = settledQueueAliases[target] ?? [:]
                aliases[operationID] = SettledQueueAlias(
                    presentationID: current.snapshot.presentationID,
                    baselineQueueIDs: current.snapshot.baselineQueuedMessageIDs
                )
                if aliases.count > Self.maximumSettledQueueAliases {
                    aliases.removeValue(forKey: aliases.keys.sorted().first!)
                }
                settledQueueAliases[target] = aliases
            }
        }
        let submitted = Set(current.snapshot.attachmentIDs)
        attachmentsByTarget[target]?.removeAll { submitted.contains($0.id) }
        if attachmentsByTarget[target]?.isEmpty == true { attachmentsByTarget[target] = nil }
        submissionByTarget[target] = nil
    }

    private func retireSettledQueueAliases(
        target: SessionPresentationIdentity,
        authoritativeQueueIDs: Set<String>
    ) {
        guard var aliases = settledQueueAliases[target] else { return }
        aliases = aliases.filter { authoritativeQueueIDs.contains($0.key) }
        settledQueueAliases[target] = aliases.isEmpty ? nil : aliases
    }

    private static func isPossiblySent(_ error: Error) -> Bool {
        if error is GatewayPossiblySentError { return true }
        return (error as? GatewayFailure)?.code == "outcome_unknown"
    }

    private static func canonicalUserMessage(
        _ item: TranscriptItem,
        matches snapshot: ComposerSubmissionSnapshot,
        submittedAttachments: [PendingAttachment],
        baselineTranscriptIDs: Set<String>
    ) -> Bool {
        guard item.kind == .message, item.role == .user,
              !baselineTranscriptIDs.contains(item.id) else { return false }
        let text = (item.content ?? []).compactMap { part -> String? in
            guard part.type == .text, part.attachment == nil else { return nil }
            return part.text
        }.joined()
        let isAttachmentOnlySubmission = snapshot.outgoingText.isEmpty && !submittedAttachments.isEmpty
        // Pi may persist bounded attachment-envelope context as canonical text
        // even though the user-facing steering/follow-up text was empty. Exact
        // attachment evidence below owns this fallback; text-only submissions
        // still require exact display-text equality.
        if isAttachmentOnlySubmission {
            guard ChatAttachmentEnvelopePolicy.isBounded(text) else { return false }
        } else {
            guard text == snapshot.outgoingText else { return false }
        }
        guard !submittedAttachments.isEmpty else { return true }

        let contents = item.content ?? []
        let imageAttachments = submittedAttachments.filter { $0.mimeType.hasPrefix("image/") }
        let canonicalImages = contents.filter { $0.type == .image }
        var unmatchedImages = canonicalImages
        let imageMetadataMatches = imageAttachments.count == canonicalImages.count
            && imageAttachments.allSatisfy { attachment in
                guard let index = unmatchedImages.firstIndex(where: { part in
                    guard attachment.mimeType == part.mimeType else { return false }
                    if let metadata = part.attachment {
                        return metadata.name == attachment.name
                            && metadata.mimeType == attachment.mimeType
                            && metadata.size == attachment.size
                    }
                    // Canonical image projection uses a content-hash blob ID rather
                    // than the client's upload ID. MIME multiplicity is the truthful
                    // bounded identity when the projection omits names.
                    return true
                }) else { return false }
                unmatchedImages.remove(at: index)
                return true
            }
        let nonImageAttachments = submittedAttachments.filter { !$0.mimeType.hasPrefix("image/") }
        let submittedNonImageKeys = nonImageAttachments.map {
            "\($0.name)\u{1F}\($0.mimeType)\u{1F}\($0.size)"
        }.sorted()
        let canonicalNonImageKeys = contents.compactMap { part -> String? in
            guard let metadata = part.attachment,
                  !metadata.mimeType.hasPrefix("image/") else { return nil }
            return "\(metadata.name)\u{1F}\(metadata.mimeType)\u{1F}\(metadata.size)"
        }.sorted()
        return imageMetadataMatches && submittedNonImageKeys == canonicalNonImageKeys
    }

    private func apply(_ request: ComposerEditorRequest, to scope: ComposerDraftScope) {
        let replacement: String
        switch request.action {
        case .set, .native:
            replacement = request.fullText
        case .paste:
            replacement = text(for: scope) + request.text
        }
        setText(replacement, for: scope)
    }

    private func revokePresentation() {
        guard let lease else { return }
        attachmentsByTarget[lease.target] = nil
        editorRequestByTarget[lease.target] = nil
        submissionByTarget[lease.target] = nil
        canonicalHandoffReceipts[lease.target] = nil
        settledQueueAliases[lease.target] = nil
        for (admission, task) in uploadTasks where admission.target == lease.target {
            task.cancel()
        }
        uploadAdmissions = uploadAdmissions.filter { $0.target != lease.target }
        self.lease = nil
        evictInactiveDraftsIfNeeded()
    }

    private func evictInactiveDraftsIfNeeded() {
        let activeScope = lease?.scope
        var inactive = Array(drafts.filter { $0.key != activeScope })
        guard inactive.count > Self.maxInactiveDrafts else { return }
        inactive.sort {
            if $0.value.lastAccess != $1.value.lastAccess {
                return $0.value.lastAccess < $1.value.lastAccess
            }
            if $0.key.profileID != $1.key.profileID { return $0.key.profileID < $1.key.profileID }
            return $0.key.sessionID < $1.key.sessionID
        }
        for (scope, _) in inactive.prefix(inactive.count - Self.maxInactiveDrafts) {
            drafts[scope] = nil
        }
    }

    #if HOSTED_TEST
    var hostedDraftCount: Int { drafts.count }
    var hostedUploadAdmissionCount: Int { uploadAdmissions.count }

    func installHostedPresentation(
        profileID: String,
        target: SessionPresentationIdentity,
        lifecycleGeneration: Int,
        initialText: String? = nil
    ) -> ComposerDraftScope {
        let scope = prepareDraft(profileID: profileID, sessionID: target.sessionID, initialText: initialText)
        _ = beginOpening(scope: scope, lifecycleGeneration: lifecycleGeneration)
        _ = mountPreparedPresentation(target)
        return scope
    }

    func installHostedAttachment(_ attachment: PendingAttachment, target: SessionPresentationIdentity) {
        guard admits(target) else { return }
        attachmentsByTarget[target, default: []].append(attachment)
    }
    #endif
}
