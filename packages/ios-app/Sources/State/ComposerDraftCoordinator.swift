import Foundation
import Observation
import UniformTypeIdentifiers

struct ComposerDraftScope: Hashable, Sendable {
    let profileID: String
    let sessionID: String
}

struct PendingAttachment: Identifiable, Hashable, Sendable {
    /// Stable chip identity. Restored drafts use a local opaque value.
    let id: String
    /// Disposable exact-presentation Gateway identity. It is never durable.
    let gatewayUploadID: String?
    let name: String
    let mimeType: String
    let size: Int
    let previewData: Data?
    /// Exact bytes retained only by the live composer under its 25 MiB aggregate
    /// attachment bound. Frozen queue/canonical handoffs always strip them.
    let fullPreviewData: Data?
    /// The immutable decoded form of `previewData`, prepared off-main once.
    /// Equality and hashing deliberately use `previewIdentity`, not object identity.
    let preparedThumbnail: ComposerPreparedAttachmentThumbnail?
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
        previewIdentity: UInt64? = nil,
        preparedThumbnail: ComposerPreparedAttachmentThumbnail? = nil
    ) {
        self.init(
            id: id,
            gatewayUploadID: id,
            name: name,
            mimeType: mimeType,
            size: size,
            previewData: previewData,
            fullPreviewData: fullPreviewData,
            previewIdentity: previewIdentity,
            preparedThumbnail: preparedThumbnail
        )
    }

    init(
        id: String,
        gatewayUploadID: String?,
        name: String,
        mimeType: String,
        size: Int,
        previewData: Data?,
        fullPreviewData: Data? = nil,
        previewIdentity: UInt64? = nil,
        preparedThumbnail: ComposerPreparedAttachmentThumbnail? = nil
    ) {
        self.id = id
        self.gatewayUploadID = gatewayUploadID
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
        self.preparedThumbnail = preparedThumbnail.flatMap {
            $0.encodedData == boundedPreview ? $0 : nil
        }
    }

    /// Canonical upload blob identity. Local `id` remains the stable chip,
    /// removal, and morph identity even when a restored attachment is re-uploaded.
    var transportBlobID: String? {
        gatewayUploadID.map { "upload:\($0)" }
    }

    /// A frozen handoff owns only the bounded thumbnail used by the row. The
    /// upload's full bytes remain available only to the live composer until
    /// this source is admitted to transcript presentation.
    func frozenForHandoff() -> Self {
        Self(
            id: id,
            gatewayUploadID: gatewayUploadID,
            name: name,
            mimeType: mimeType,
            size: size,
            previewData: previewData,
            fullPreviewData: nil,
            previewIdentity: previewIdentity,
            preparedThumbnail: preparedThumbnail
        )
    }

    func requiringUpload() -> Self {
        Self(
            id: id,
            gatewayUploadID: nil,
            name: name,
            mimeType: mimeType,
            size: size,
            previewData: previewData,
            fullPreviewData: fullPreviewData,
            previewIdentity: previewIdentity,
            preparedThumbnail: preparedThumbnail
        )
    }

    func replacingGatewayUploadID(_ uploadID: String) -> Self {
        Self(
            id: id,
            gatewayUploadID: uploadID,
            name: name,
            mimeType: mimeType,
            size: size,
            previewData: previewData,
            fullPreviewData: fullPreviewData,
            previewIdentity: previewIdentity,
            preparedThumbnail: preparedThumbnail
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.gatewayUploadID == rhs.gatewayUploadID
            && lhs.name == rhs.name
            && lhs.mimeType == rhs.mimeType
            && lhs.size == rhs.size
            && lhs.previewData == rhs.previewData
            && lhs.previewIdentity == rhs.previewIdentity
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(gatewayUploadID)
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

struct CanonicalSubmissionHandoffReceipt: Equatable, Sendable {
    let canonicalID: String
    let attachments: [PendingAttachment]
    /// Exact Gateway operation identity when transport admission completed.
    /// Physical row aliasing requires this causal value for every prompt kind.
    let operationID: String?
    /// Presentation identity retained only until this one canonical replacement
    /// is installed. It never substitutes for the canonical transcript ID.
    let submission: ComposerSubmissionSnapshot?

    init(
        canonicalID: String,
        attachments: [PendingAttachment],
        operationID: String? = nil,
        submission: ComposerSubmissionSnapshot? = nil
    ) {
        self.canonicalID = canonicalID
        self.attachments = attachments
        self.operationID = operationID
        self.submission = submission
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

struct ComposerResourceInvocation: Codable, Equatable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case skill, prompt, `extension` }
    static let maximumNameBytes = 512
    static let maximumArgumentBytes = 5_000

    let source: Source
    let name: String
    let arguments: String

    var isExtensionCommand: Bool { source == .extension }
    var isTransportValid: Bool {
        !name.isEmpty
            && name.utf8.count <= Self.maximumNameBytes
            && !name.contains(where: \.isWhitespace)
            && arguments.utf8.count <= Self.maximumArgumentBytes
            && !arguments.unicodeScalars.contains(where: { scalar in
                (scalar.value < 0x20 && ![0x09, 0x0a, 0x0d].contains(scalar.value))
                    || scalar.value == 0x7f
            })
    }
}

struct ComposerSubmissionSnapshot: Equatable, Sendable {
    let target: SessionPresentationIdentity
    let textRevision: Int
    let localNonce: UInt64
    /// User-visible text. Skill transport metadata is deliberately separate so
    /// optimistic, queued, and canonical presentation never expose `/skill:`.
    let outgoingText: String
    let resourceInvocation: ComposerResourceInvocation?
    let attachmentIDs: [String]
    let behavior: String?
    let baselineQueuedMessageIDs: Set<String>

    init(
        target: SessionPresentationIdentity,
        textRevision: Int,
        outgoingText: String,
        resourceInvocation: ComposerResourceInvocation? = nil,
        attachmentIDs: [String],
        behavior: String?,
        baselineQueuedMessageIDs: Set<String> = [],
        localNonce: UInt64
    ) {
        self.target = target
        self.textRevision = textRevision
        self.localNonce = localNonce
        self.outgoingText = outgoingText
        self.resourceInvocation = resourceInvocation
        self.attachmentIDs = attachmentIDs
        self.behavior = behavior
        self.baselineQueuedMessageIDs = baselineQueuedMessageIDs
    }

    /// Stable only for the owning presentation and admitted submission. This
    /// is a presentation identity, never a transcript/event ID.
    var presentationID: String {
        "outgoing-submission:\(target.sessionID):\(target.generation):\(localNonce)"
    }
}

struct ChatSubmissionLifecycle: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case staged
        case committed
        case transported
        case canonical(String)
    }

    let phase: Phase
    let submission: ComposerSubmissionSnapshot?
    let attachments: [PendingAttachment]

    static let idle = Self(phase: .idle, submission: nil, attachments: [])

    var id: String? { submission?.presentationID }
}

struct ComposerAttachmentUploadCandidate: Sendable {
    let name: String
    let mimeType: String
    let data: Data
}

typealias ComposerUploadOperation = @MainActor @Sendable (
    _ name: String,
    _ mimeType: String,
    _ data: Data
) async throws -> String

typealias ComposerUploadDiscardOperation = @MainActor @Sendable (_ uploadID: String) async -> Void

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
    _ behavior: String?,
    _ resourceInvocation: ComposerResourceInvocation?
) async throws -> String

typealias ComposerAttachmentPreviewPreparation = @Sendable (
    _ data: Data,
    _ mimeType: String,
    _ name: String
) async -> ComposerPreparedAttachmentThumbnail?

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
        case rejected
    }

    private struct SubmissionAdmission: Equatable {
        let id: UInt64
        let snapshot: ComposerSubmissionSnapshot
        let submittedAttachments: [PendingAttachment]
        let scope: ComposerDraftScope
        let submittedResource: CommandInfo?
        let resourceMutationRevision: Int
        var canRestoreSubmittedResource: Bool
        let baselineTranscriptIDs: Set<String>
        let lifecycleGeneration: Int
        var transportState: SubmissionTransportState
        var operationID: String?
        var observedQueuedCandidateIDs: Set<String>
        /// Latest-snapshot-only visual continuity before the transport returns
        /// the exact operation ID. This never settles admission or canonical
        /// causality and is cleared on ambiguity or an ID mismatch.
        var provisionalQueuedCandidateID: String?
        var canonicalObserved: Bool
        var transcriptObserved: Bool
        var canonicalHandoffID: String?
    }

    private struct SettledQueueAlias: Equatable {
        let presentationID: String
        let baselineQueueIDs: Set<String>
    }

    private struct SettledQueueHandoff: Equatable {
        let operationID: String
        let snapshot: ComposerSubmissionSnapshot
        let submittedAttachments: [PendingAttachment]
        let baselineTranscriptIDs: Set<String>
    }

    private let uploadOperation: ComposerUploadOperation
    private let discardUploadOperation: ComposerUploadDiscardOperation
    private let fileUploadOperation: ComposerFileUploadOperation
    private let attachmentFileAccess: ComposerAttachmentFileAccess
    private let prepareAttachmentPreview: ComposerAttachmentPreviewPreparation
    private let sendOperation: ComposerSendOperation
    private let draftStore: ComposerDraftStore
    @ObservationIgnored private let admitsLifecycleGeneration: @MainActor (Int) -> Bool

    private var drafts: [ComposerDraftScope: Draft] = [:]
    private var selectedResourceByScope: [ComposerDraftScope: CommandInfo] = [:]
    private var resourceMutationRevisionByScope: [ComposerDraftScope: Int] = [:]
    private var preparedOpenBySession: [String: PreparedOpen] = [:]
    private var lease: PresentationLease?
    /// Unsent attachment payloads follow durable profile/session scope. Only
    /// their disposable upload work and IDs are presentation-bound.
    private var attachmentsByScope: [ComposerDraftScope: [PendingAttachment]] = [:]
    private var editorRequestByTarget: [SessionPresentationIdentity: ComposerEditorRequest] = [:]
    private var uploadAdmissions = Set<UploadAdmission>()
    private var uploadTasks: [UploadAdmission: Task<String, Error>] = [:]
    /// Exact local chip ownership for cancellable, presentation-scoped uploads.
    /// Removing a chip retires only its transport admission immediately.
    private var uploadAdmissionByAttachmentID: [String: UploadAdmission] = [:]
    /// One admitted transport lifecycle per durable profile/session scope. The
    /// snapshot retains its origin presentation only for source metadata; route
    /// replacement never changes ownership or resends the operation.
    private var submissionByScope: [ComposerDraftScope: SubmissionAdmission] = [:]
    /// Only the newest exact canonical handoff for the mounted presentation is
    /// retained. This bounds rich thumbnail payloads to one prompt lifecycle.
    private var canonicalHandoffReceipts: [SessionPresentationIdentity: CanonicalSubmissionHandoffReceipt] = [:]
    private static let maximumSettledQueueAliases = SessionSnapshot.maximumQueuedMessages
    private var settledQueueAliases: [SessionPresentationIdentity: [String: SettledQueueAlias]] = [:]
    /// At most one consumed queue lifecycle is retained for the mounted
    /// presentation until its canonical user entry resolves. Attachments may be
    /// empty; rich previews therefore remain bounded to one prompt lifecycle.
    private var settledQueueHandoffs: [SessionPresentationIdentity: SettledQueueHandoff] = [:]
    /// Scopes whose durable value and attachment thumbnails have completed one
    /// merge. Text edits alone never advance this boundary.
    @ObservationIgnored private var loadedScopes: Set<ComposerDraftScope> = []
    @ObservationIgnored private var textMutationRevisionByScope: [ComposerDraftScope: UInt64] = [:]
    @ObservationIgnored private var restoreTasks: [ComposerDraftScope: Task<ComposerDraftStore.Value?, Never>] = [:]
    @ObservationIgnored private var restoredUploadTasks: [SessionPresentationIdentity: Task<Void, Never>] = [:]
    @ObservationIgnored private var dirtyScopes: Set<ComposerDraftScope> = []
    @ObservationIgnored private var storageGenerationByScope: [ComposerDraftScope: UInt64] = [:]
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    private var sequence: UInt64 = 0

    init(
        upload: @escaping ComposerUploadOperation,
        discardUpload: @escaping ComposerUploadDiscardOperation = { _ in },
        fileUpload: @escaping ComposerFileUploadOperation,
        attachmentFileAccess: ComposerAttachmentFileAccess = .live,
        prepareAttachmentPreview: @escaping ComposerAttachmentPreviewPreparation = {
            await ComposerAttachmentPreviewPolicy.prepare($0, mimeType: $1, name: $2)
        },
        draftStore: ComposerDraftStore = ComposerDraftStore(),
        send: @escaping ComposerSendOperation,
        admitsLifecycleGeneration: @escaping @MainActor (Int) -> Bool
    ) {
        uploadOperation = upload
        discardUploadOperation = discardUpload
        fileUploadOperation = fileUpload
        self.attachmentFileAccess = attachmentFileAccess
        self.prepareAttachmentPreview = prepareAttachmentPreview
        self.draftStore = draftStore
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
        textMutationRevisionByScope[scope, default: 0] &+= 1
        schedulePersistence(for: scope)
        evictInactiveDraftsIfNeeded()
    }

    func selectedResource(for scope: ComposerDraftScope) -> CommandInfo? {
        selectedResourceByScope[scope]
    }

    func selectResource(_ command: CommandInfo, for scope: ComposerDraftScope) {
        guard !command.name.isEmpty else { return }
        selectedResourceByScope[scope] = command
        resourceMutationRevisionByScope[scope, default: 0] &+= 1
        touch(scope, installing: nil)
    }

    func removeSelectedResource(for scope: ComposerDraftScope) {
        selectedResourceByScope[scope] = nil
        resourceMutationRevisionByScope[scope, default: 0] &+= 1
    }

    /// Catalog replacement is authoritative. A retired or shadowed resource
    /// cannot remain staged or be resurrected by a late transport failure;
    /// metadata-only refreshes preserve the stable source/name selection.
    func reconcileSelectedResource(for scope: ComposerDraftScope, commands: [CommandInfo]) {
        if let selected = selectedResourceByScope[scope] {
            let matches = commands.filter {
                $0.source == selected.source && $0.name == selected.name
            }
            let shadowed = selected.source != .extension && commands.contains {
                $0.source == .extension && $0.name == selected.name
            }
            if matches.count == 1, !shadowed {
                selectedResourceByScope[scope] = matches[0]
            } else {
                selectedResourceByScope[scope] = nil
                resourceMutationRevisionByScope[scope, default: 0] &+= 1
            }
        }
        guard let scope = lease?.scope,
              var admission = submissionByScope[scope],
              let submitted = admission.submittedResource,
              !Self.resourceIsUnambiguous(submitted, in: commands) else { return }
        admission.canRestoreSubmittedResource = false
        submissionByScope[scope] = admission
    }

    private static func resourceIsUnambiguous(_ selected: CommandInfo, in commands: [CommandInfo]) -> Bool {
        // Source/name is the stable invocation identity. Descriptions, paths,
        // and resource metadata may legitimately change during reload.
        commands.filter { $0.source == selected.source && $0.name == selected.name }.count == 1
            && (selected.source == .extension
                || !commands.contains { $0.source == .extension && $0.name == selected.name })
    }

    func openMountedPresentation(
        scope: ComposerDraftScope,
        lifecycleGeneration: Int,
        open: () async throws -> Int,
        finalAdmission: (SessionPresentationIdentity) throws -> Void,
        revokePresentation: (SessionPresentationIdentity) -> Void,
        closePresentation: (SessionPresentationIdentity) async -> Void
    ) async throws -> Int {
        await restoreDraftIfNeeded(scope)
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
        if let stale = submissionByScope[prepared.scope],
           stale.lifecycleGeneration != prepared.lifecycleGeneration {
            retireSubmissionForLifecycleReset(stale)
        }
        lease = PresentationLease(
            scope: prepared.scope,
            target: target,
            lifecycleGeneration: prepared.lifecycleGeneration
        )
        restoreRejectedSubmissionIfNeeded(scope: prepared.scope, target: target)
        touch(prepared.scope, installing: nil)
        beginRestoredAttachmentUploads(scope: prepared.scope, target: target)
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
        guard admits(target), let scope = lease?.scope else { return [] }
        return attachmentsByScope[scope] ?? []
    }

    func submittedAttachments(for target: SessionPresentationIdentity) -> [PendingAttachment] {
        guard let scope = scope(for: target) else { return [] }
        return submissionByScope[scope]?.submittedAttachments ?? []
    }

    /// Reads the one-shot canonical replacement receipt without consuming it.
    /// Queue mutation ordering uses this to defer an ambiguous projection until
    /// the command outcome determines whether the receipt remains causal.
    func canonicalSubmissionHandoff(
        target: SessionPresentationIdentity
    ) -> CanonicalSubmissionHandoffReceipt? {
        guard admits(target) else { return nil }
        return canonicalHandoffReceipts[target]
    }

    /// Consumes the one-shot canonical replacement receipt created before a
    /// submission admission is retired. The receipt is presentation-only;
    /// canonical transcript IDs remain authoritative.
    func consumeCanonicalSubmissionHandoff(
        target: SessionPresentationIdentity
    ) -> CanonicalSubmissionHandoffReceipt? {
        guard admits(target) else { return nil }
        return canonicalHandoffReceipts.removeValue(forKey: target)
    }

    /// A confirmed local edit/removal owns retirement of its exact queue
    /// lineage. Unrelated queue mutations must not disturb the one retained
    /// consumed-operation handoff.
    func invalidateSettledQueueHandoff(
        target: SessionPresentationIdentity,
        affectedOperationIDs: Set<String>
    ) {
        guard admits(target) else { return }
        if let handoff = settledQueueHandoffs[target],
           affectedOperationIDs.contains(handoff.operationID) {
            settledQueueHandoffs[target] = nil
        }
        if let receipt = canonicalHandoffReceipts[target],
           let operationID = receipt.operationID,
           affectedOperationIDs.contains(operationID) {
            canonicalHandoffReceipts[target] = nil
        }
    }

    func canonicalSubmissionIDs(
        target: SessionPresentationIdentity,
        canonicalTranscript: [TranscriptItem]
    ) -> Set<String> {
        guard let scope = scope(for: target),
              let admission = submissionByScope[scope] else { return [] }
        let exactMatches: [String] = admission.operationID.map { operationID in
            canonicalTranscript.compactMap { item in
                guard item.kind == .message,
                      item.role == .user,
                      (item.presentationId == operationID
                        || item.semantic?.operationId == operationID),
                      !admission.baselineTranscriptIDs.contains(item.id) else { return nil }
                return item.id
            }
        } ?? []
        let fallbackMatches = canonicalTranscript.compactMap { item in
            Self.canonicalUserMessage(
                item,
                matches: admission.snapshot,
                submittedAttachments: admission.submittedAttachments,
                baselineTranscriptIDs: admission.baselineTranscriptIDs
            ) ? item.id : nil
        }
        let matches = admission.operationID == nil ? fallbackMatches : exactMatches
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
        guard let scope = scope(for: target) else { return false }
        return submissionByScope[scope]?.transportState == .sending
    }

    /// The outgoing row is intentionally separate from canonical transcript
    /// projection. It remains visible after transport acknowledgement until a
    /// matching canonical user message is observed for this exact target.
    func outgoingSubmission(for target: SessionPresentationIdentity) -> ComposerSubmissionSnapshot? {
        guard let scope = scope(for: target) else { return nil }
        return submissionByScope[scope]?.snapshot
    }

    /// Matches the Gateway's sole foreground pending admission to the retained
    /// local lifecycle. Once transport returns, operation identity is decisive;
    /// before then, one target owns at most one bounded pending prompt.
    func matchesPendingPrompt(
        target: SessionPresentationIdentity,
        pending: SessionSnapshot.PendingPrompt
    ) -> Bool {
        guard let scope = scope(for: target),
              let admission = submissionByScope[scope] else { return false }
        if let operationID = admission.operationID { return operationID == pending.id }
        return admission.snapshot.outgoingText == pending.text
            && admission.snapshot.attachmentIDs.count == pending.attachmentCount
            && admission.snapshot.behavior == pending.behavior?.rawValue
    }

    func hasPendingSubmission(target: SessionPresentationIdentity) -> Bool {
        outgoingSubmission(for: target) != nil
    }

    /// One derived presentation read over the existing admission facts. Views
    /// use this value instead of racing transport, queue, and canonical queries.
    /// Canonical identity remains authoritative and is exposed only after the
    /// exact reconciliation receipt has been created.
    func submissionLifecycle(for target: SessionPresentationIdentity) -> ChatSubmissionLifecycle {
        guard let scope = scope(for: target) else { return .idle }
        if let admission = submissionByScope[scope] {
            let phase: ChatSubmissionLifecycle.Phase
            if let canonicalID = admission.canonicalHandoffID {
                phase = .canonical(canonicalID)
            } else if admission.transportState == .accepted {
                phase = .transported
            } else if admission.operationID != nil {
                phase = .committed
            } else {
                phase = .staged
            }
            return ChatSubmissionLifecycle(
                phase: phase,
                submission: admission.snapshot,
                attachments: admission.submittedAttachments.map { $0.frozenForHandoff() }
            )
        }
        if let receipt = canonicalHandoffReceipts[target], let submission = receipt.submission {
            return ChatSubmissionLifecycle(
                phase: .canonical(receipt.canonicalID),
                submission: submission,
                attachments: receipt.attachments
            )
        }
        return .idle
    }

    /// Returns the optimistic identity only for the exact accepted operation or
    /// one unique, current-snapshot provisional candidate. Provisional identity
    /// is visual continuity only: it never retires the admission or establishes
    /// canonical causality before the transport returns an operation ID.
    func queuedSubmissionPresentationID(
        target: SessionPresentationIdentity,
        message: SessionSnapshot.QueuedMessage
    ) -> String? {
        guard let scope = scope(for: target) else { return nil }
        if let admission = submissionByScope[scope],
           admission.snapshot.behavior != nil,
           !admission.snapshot.baselineQueuedMessageIDs.contains(message.id) {
            if admission.operationID == message.id
                || (admission.operationID == nil
                    && admission.provisionalQueuedCandidateID == message.id) {
                return admission.snapshot.presentationID
            }
        }
        if let alias = settledQueueAliases[target]?[message.id],
           !alias.baselineQueueIDs.contains(message.id) {
            return alias.presentationID
        }
        return nil
    }

    /// Freezes every attributable queue identity into one projection capture so
    /// rendering never re-reads mutable coordinator state against an older
    /// installed transcript.
    func queuedSubmissionPresentationIDs(
        target: SessionPresentationIdentity,
        queuedMessages: [SessionSnapshot.QueuedMessage]
    ) -> [String: String] {
        guard admits(target),
              queuedMessages.count <= SessionSnapshot.maximumQueuedMessages,
              Set(queuedMessages.map(\.id)).count == queuedMessages.count else { return [:] }
        var aliases: [String: String] = [:]
        var presentationIDs: Set<String> = []
        for message in queuedMessages {
            guard let presentationID = queuedSubmissionPresentationID(
                target: target,
                message: message
            ) else { continue }
            guard aliases[message.id] == nil,
                  presentationIDs.insert(presentationID).inserted else { return [:] }
            aliases[message.id] = presentationID
        }
        return aliases
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
        guard let scope = scope(for: target),
              var admission = submissionByScope[scope] else {
            retireSettledQueueAliases(
                target: target,
                authoritativeQueueIDs: Set(queuedMessages.map(\.id)),
                canonicalTranscript: canonicalTranscript
            )
            return
        }
        let exactOperationMatches: [String] = admission.operationID.map { operationID in
            canonicalTranscript.compactMap { item in
                guard item.kind == .message,
                      item.role == .user,
                      (item.presentationId == operationID
                        || item.semantic?.operationId == operationID),
                      !admission.baselineTranscriptIDs.contains(item.id) else { return nil }
                return item.id
            }
        } ?? []
        let fallbackMatches = canonicalTranscript.compactMap { item in
            Self.canonicalUserMessage(
                item,
                matches: admission.snapshot,
                submittedAttachments: admission.submittedAttachments,
                baselineTranscriptIDs: admission.baselineTranscriptIDs
            ) ? item.id : nil
        }
        // The Gateway's operation-bound presentation identity is causal and
        // wins over repeated-text ambiguity. Exact-content matching is allowed
        // only before the transport response supplies that identity.
        let canonicalMatches = admission.operationID == nil
            ? fallbackMatches
            : exactOperationMatches
        // A response-race snapshot can contain multiple same-text candidates.
        // Keep the admission alive until authoritative identity is unambiguous.
        let transcriptObserved = canonicalMatches.count == 1
        if transcriptObserved, admission.canonicalHandoffID == nil {
            admission.canonicalHandoffID = canonicalMatches[0]
        }
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
                && message.resourceInvocation == admission.snapshot.resourceInvocation
        }
        admission.provisionalQueuedCandidateID = if admission.operationID == nil,
                                                    queuedCandidates.count == 1 {
            queuedCandidates[0].id
        } else {
            nil
        }
        admission.observedQueuedCandidateIDs.formUnion(queuedCandidates.map(\.id))
        admission.transcriptObserved = admission.transcriptObserved || transcriptObserved
        retireSettledQueueAliases(
            target: target,
            authoritativeQueueIDs: Set(queuedMessages.map(\.id)),
            canonicalTranscript: canonicalTranscript
        )
        if canonicalMatches.count > 1 {
            // Do not let an independent queue observation settle an admission
            // while canonical identity is ambiguous in this snapshot.
            submissionByScope[scope] = admission
            return
        }
        let queuedObserved = admission.operationID.map {
            admission.observedQueuedCandidateIDs.contains($0)
        } ?? false
        guard transcriptObserved || queuedObserved else {
            submissionByScope[scope] = admission
            return
        }
        let newlySettled = !admission.canonicalObserved
        admission.canonicalObserved = true
        if newlySettled { schedulePersistence(for: admission.scope) }
        if admission.transportState == .accepted {
            // Publish the enriched local admission before retirement so the
            // exact canonical ID receipt survives this synchronous boundary.
            submissionByScope[scope] = admission
            finishSubmission(admission, settlementTarget: target)
        } else {
            submissionByScope[scope] = admission
        }
    }

    func submissionSnapshot(for target: SessionPresentationIdentity) -> ComposerSubmissionSnapshot? {
        guard let scope = scope(for: target) else { return nil }
        return submissionByScope[scope]?.snapshot
    }

    /// A sequenced Gateway failure is terminal for the exact accepted operation.
    /// Transport admission is not canonical settlement, so this explicit receipt
    /// is required to retire a row that can no longer produce canonical input.
    @discardableResult
    func failOperation(_ operationID: String, target: SessionPresentationIdentity) -> Bool {
        guard let scope = scope(for: target),
              let admission = submissionByScope[scope],
              admission.operationID == operationID else { return false }
        restoreSubmission(admission)
        return true
    }

    func upload(
        name: String,
        mimeType: String,
        data: Data,
        target: SessionPresentationIdentity
    ) async throws {
        let admission = try beginUpload(target: target, bytes: data.count)
        defer { uploadAdmissions.remove(admission) }
        let preparedThumbnail = await prepareAttachmentPreview(data, mimeType, name)
        try require(admission)
        guard let scope = scope(for: target) else { throw CancellationError() }
        let localID = "local:\(UUID().uuidString)"
        attachmentsByScope[scope, default: []].append(PendingAttachment(
            id: localID,
            gatewayUploadID: nil,
            name: name,
            mimeType: mimeType,
            size: data.count,
            previewData: preparedThumbnail?.encodedData,
            fullPreviewData: data,
            preparedThumbnail: preparedThumbnail
        ))
        uploadAdmissionByAttachmentID[localID] = admission
        defer {
            if uploadAdmissionByAttachmentID[localID] == admission {
                uploadAdmissionByAttachmentID[localID] = nil
            }
        }
        schedulePersistence(for: scope)

        let task = Task { try await uploadOperation(name, mimeType, data) }
        uploadTasks[admission] = task
        defer { uploadTasks[admission] = nil }
        let uploadID: String
        do {
            uploadID = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            try require(admission)
            // The local chip and bytes remain durable and explicitly require a
            // later upload; transport failure never discards user input.
            throw error
        }
        try require(admission)
        guard var attachments = attachmentsByScope[scope],
              let index = attachments.firstIndex(where: { $0.id == localID }) else {
            throw CancellationError()
        }
        attachments[index] = attachments[index].replacingGatewayUploadID(uploadID)
        attachmentsByScope[scope] = attachments
        schedulePersistence(for: scope)
    }

    /// Stages one PhotosPicker selection atomically in selection order, then
    /// uploads every member concurrently. Transport latency can never serialize
    /// chip publication or leave later selected photos invisible behind one
    /// active upload.
    func uploadBatch(
        _ candidates: [ComposerAttachmentUploadCandidate],
        target: SessionPresentationIdentity
    ) async throws {
        guard !candidates.isEmpty, let scope = scope(for: target) else {
            throw CancellationError()
        }

        var admissions: [UploadAdmission] = []
        do {
            for candidate in candidates {
                admissions.append(try beginUpload(target: target, bytes: candidate.data.count))
            }
        } catch {
            admissions.forEach { uploadAdmissions.remove($0) }
            throw error
        }

        var thumbnails: [ComposerPreparedAttachmentThumbnail?] = []
        do {
            thumbnails.reserveCapacity(candidates.count)
            for (index, candidate) in candidates.enumerated() {
                let thumbnail = await prepareAttachmentPreview(
                    candidate.data, candidate.mimeType, candidate.name
                )
                try require(admissions[index])
                thumbnails.append(thumbnail)
            }
            guard self.scope(for: target) == scope else { throw CancellationError() }
        } catch {
            admissions.forEach { uploadAdmissions.remove($0) }
            throw error
        }

        let localIDs = candidates.map { _ in "local:\(UUID().uuidString)" }
        for index in candidates.indices {
            let candidate = candidates[index]
            let thumbnail = thumbnails[index]
            let localID = localIDs[index]
            let admission = admissions[index]
            attachmentsByScope[scope, default: []].append(PendingAttachment(
                id: localID,
                gatewayUploadID: nil,
                name: candidate.name,
                mimeType: candidate.mimeType,
                size: candidate.data.count,
                previewData: thumbnail?.encodedData,
                fullPreviewData: candidate.data,
                preparedThumbnail: thumbnail
            ))
            uploadAdmissionByAttachmentID[localID] = admission
        }
        schedulePersistence(for: scope)

        // Preserve the pre-batch transport contract: one HTTP body at a time.
        // Every chip is already visible, so parallel network work adds no UI
        // benefit and can contend with the Gateway's global upload capacity.
        var predecessor: Task<String, Error>?
        let transportTasks = candidates.map { candidate in
            let precedingTransport = predecessor
            let task = Task { @MainActor [uploadOperation] in
                if let precedingTransport { _ = await precedingTransport.result }
                try Task.checkCancellation()
                return try await uploadOperation(
                    candidate.name,
                    candidate.mimeType,
                    candidate.data
                )
            }
            predecessor = task
            return task
        }
        for index in admissions.indices {
            uploadTasks[admissions[index]] = transportTasks[index]
        }
        defer {
            for index in admissions.indices {
                let admission = admissions[index]
                let localID = localIDs[index]
                uploadAdmissions.remove(admission)
                uploadTasks[admission] = nil
                if uploadAdmissionByAttachmentID[localID] == admission {
                    uploadAdmissionByAttachmentID[localID] = nil
                }
            }
        }

        try await withTaskCancellationHandler {
            var firstError: (any Error)?
            for index in transportTasks.indices {
                let admission = admissions[index]
                let localID = localIDs[index]
                do {
                    let uploadID = try await transportTasks[index].value
                    guard uploadAdmissions.contains(admission),
                          var attachments = attachmentsByScope[scope],
                          let attachmentIndex = attachments.firstIndex(where: {
                              $0.id == localID
                          }) else { continue }
                    attachments[attachmentIndex] = attachments[attachmentIndex]
                        .replacingGatewayUploadID(uploadID)
                    attachmentsByScope[scope] = attachments
                    schedulePersistence(for: scope)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    // Exact chip removal retires its admission and is not a
                    // batch failure. Transport failures retain upload-required
                    // bytes and surface one bounded error after siblings settle.
                    if uploadAdmissions.contains(admission), firstError == nil {
                        firstError = error
                    }
                }
            }
            try Task.checkCancellation()
            guard admits(target) else { throw CancellationError() }
            if let firstError { throw firstError }
        } onCancel: {
            transportTasks.forEach { $0.cancel() }
        }
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
        let data = try await attachmentFileAccess.previewData(staged, size)
        let preparedThumbnail = await prepareAttachmentPreview(data, mimeType, name)
        try require(admission)
        guard let scope = scope(for: target) else { throw CancellationError() }
        let localID = "local:\(UUID().uuidString)"
        attachmentsByScope[scope, default: []].append(PendingAttachment(
            id: localID,
            gatewayUploadID: nil,
            name: name,
            mimeType: mimeType,
            size: size,
            previewData: preparedThumbnail?.encodedData,
            fullPreviewData: data,
            preparedThumbnail: preparedThumbnail
        ))
        uploadAdmissionByAttachmentID[localID] = admission
        defer {
            if uploadAdmissionByAttachmentID[localID] == admission {
                uploadAdmissionByAttachmentID[localID] = nil
            }
        }
        schedulePersistence(for: scope)

        let task = Task { try await fileUploadOperation(name, mimeType, staged, size) }
        uploadTasks[admission] = task
        defer { uploadTasks[admission] = nil }
        let uploadID: String
        do {
            uploadID = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            try require(admission)
            throw error
        }
        try require(admission)
        guard var attachments = attachmentsByScope[scope],
              let index = attachments.firstIndex(where: { $0.id == localID }) else {
            throw CancellationError()
        }
        attachments[index] = attachments[index].replacingGatewayUploadID(uploadID)
        attachmentsByScope[scope] = attachments
        schedulePersistence(for: scope)
    }

    func removeAttachment(_ id: String, target: SessionPresentationIdentity) {
        guard admits(target), let scope = lease?.scope,
              var attachments = attachmentsByScope[scope],
              let removedAttachment = attachments.first(where: { $0.id == id }) else { return }
        if let admission = uploadAdmissionByAttachmentID.removeValue(forKey: id),
           admission.target == target {
            uploadAdmissions.remove(admission)
            uploadTasks.removeValue(forKey: admission)?.cancel()
        }
        attachments.removeAll { $0.id == id }
        attachmentsByScope[scope] = attachments.isEmpty ? nil : attachments
        if let uploadID = removedAttachment.gatewayUploadID {
            discardUpload(uploadID)
        }
        schedulePersistence(for: scope)
    }

    func hasActiveUploads(for target: SessionPresentationIdentity) -> Bool {
        admits(target) && (
            uploadAdmissions.contains { $0.target == target }
                || restoredUploadTasks[target] != nil
        )
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
        resourceInvocation: ComposerResourceInvocation? = nil,
        canonicalTranscript: [TranscriptItem] = [],
        queuedMessages: [SessionSnapshot.QueuedMessage] = []
    ) throws -> ComposerSubmissionSnapshot {
        try beginSubmissionAdmission(
            target: target,
            behavior: behavior,
            resourceInvocation: resourceInvocation,
            canonicalTranscript: canonicalTranscript,
            queuedMessages: queuedMessages
        ).snapshot
    }

    /// Sends an already-admitted submission without changing its presentation
    /// shape. A late transport result can only settle this exact admission.
    func transmitSubmission(_ submission: ComposerSubmissionSnapshot) async throws {
        guard let admission = submissionByScope.values.first(where: {
            $0.snapshot == submission
        }) else {
            throw CancellationError()
        }
        // Route remounts preserve the admission, but a profile/lifecycle
        // replacement must stop it before any mutation can enter the new
        // Gateway connection.
        // Lifecycle replacement or task cancellation must stop transport before
        // its first suspension. That boundary is provably not sent, so it must
        // also reject the local admission and restore the captured draft instead
        // of leaving a scope-owned `.sending` row with no transport owner.
        // Once transport is in flight, outcome-only admission intentionally lets
        // accepted work survive a route remount.
        let operationID: String
        do {
            try require(admission)
            operationID = try await sendOperation(
                admission.snapshot.outgoingText,
                submission.target.sessionID,
                admission.snapshot.attachmentIDs,
                admission.snapshot.behavior,
                admission.snapshot.resourceInvocation
            )
        } catch {
            // A route may disappear after admission. The exact submission
            // remains owned here until transport reaches a terminal outcome;
            // stale completions still require the same target/id below.
            try requireOutcome(admission)
            if Self.isPossiblySent(error) {
                markTransportAccepted(admission)
            } else {
                restoreSubmission(admission)
            }
            throw error
        }
        try requireOutcome(admission)
        markOperationAccepted(operationID, admission: admission)
        markTransportAccepted(admission)
        // Pi extension-command prompt completion means the handler has returned;
        // there is no canonical user message to reconcile. Retire only this
        // composer admission while the Gateway command receipt owns transcript
        // lifecycle and any downstream turns independently.
        if admission.snapshot.resourceInvocation?.isExtensionCommand == true,
           let accepted = submissionByScope[admission.scope],
           accepted.id == admission.id {
            retireSubmissionForLifecycleReset(accepted)
        }
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

    @discardableResult
    func removeSession(profileID: String, sessionID: String) -> Task<Void, Never> {
        let scope = ComposerDraftScope(profileID: profileID, sessionID: sessionID)
        dirtyScopes.remove(scope)
        storageGenerationByScope[scope, default: 0] &+= 1
        drafts[scope] = nil
        attachmentsByScope[scope] = nil
        loadedScopes.remove(scope)
        textMutationRevisionByScope[scope] = nil
        restoreTasks[scope]?.cancel()
        restoreTasks[scope] = nil
        selectedResourceByScope[scope] = nil
        resourceMutationRevisionByScope[scope] = nil
        preparedOpenBySession[sessionID] = nil
        submissionByScope[scope] = nil
        if lease?.scope == scope { revokePresentation() }
        return enqueuePersistence { store in await store.remove(scope) }
    }

    @discardableResult
    func removeProfile(_ profileID: String) -> Task<Void, Never> {
        let invalidatedScopes = Set(drafts.keys)
            .union(attachmentsByScope.keys)
            .union(restoreTasks.keys)
            .filter { $0.profileID == profileID }
        for scope in invalidatedScopes {
            storageGenerationByScope[scope, default: 0] &+= 1
            restoreTasks[scope]?.cancel()
        }
        dirtyScopes = dirtyScopes.filter { $0.profileID != profileID }
        drafts = drafts.filter { $0.key.profileID != profileID }
        attachmentsByScope = attachmentsByScope.filter { $0.key.profileID != profileID }
        loadedScopes = loadedScopes.filter { $0.profileID != profileID }
        textMutationRevisionByScope = textMutationRevisionByScope.filter {
            $0.key.profileID != profileID
        }
        restoreTasks = restoreTasks.filter { $0.key.profileID != profileID }
        selectedResourceByScope = selectedResourceByScope.filter { $0.key.profileID != profileID }
        resourceMutationRevisionByScope = resourceMutationRevisionByScope.filter { $0.key.profileID != profileID }
        preparedOpenBySession = preparedOpenBySession.filter { $0.value.scope.profileID != profileID }
        submissionByScope = submissionByScope.filter { $0.key.profileID != profileID }
        if lease?.scope.profileID == profileID { revokePresentation() }
        return enqueuePersistence { store in await store.removeProfile(profileID) }
    }

    /// Forces the latest coalesced local draft values to the owned store. The
    /// returned task lets lifecycle tests and teardown boundaries await the
    /// checkpoint without making ordinary keystrokes synchronous.
    @discardableResult
    func checkpointDrafts() -> Task<Void, Never> {
        let predecessor = persistenceTask
        predecessor?.cancel()
        let task = Task { @MainActor [weak self] in
            await predecessor?.value
            guard !Task.isCancelled, let self else { return }
            await self.flushDirtyDrafts()
        }
        persistenceTask = task
        return task
    }

    private func restoreDraftIfNeeded(_ scope: ComposerDraftScope) async {
        guard !loadedScopes.contains(scope) else { return }
        let startingStorageGeneration = storageGenerationByScope[scope, default: 0]
        let task: Task<ComposerDraftStore.Value?, Never>
        if let existing = restoreTasks[scope] {
            task = existing
        } else {
            let store = draftStore
            task = Task { await store.load(scope) }
            restoreTasks[scope] = task
        }
        let value = await task.value
        restoreTasks[scope] = nil
        guard !loadedScopes.contains(scope),
              storageGenerationByScope[scope, default: 0] == startingStorageGeneration else { return }

        var restoredAttachments: [PendingAttachment] = []
        if let value {
            restoredAttachments.reserveCapacity(value.attachments.count)
            for attachment in value.attachments {
                let thumbnail = await prepareAttachmentPreview(
                    attachment.data,
                    attachment.mimeType,
                    attachment.name
                )
                restoredAttachments.append(PendingAttachment(
                    id: "restored-\(UUID().uuidString)",
                    gatewayUploadID: nil,
                    name: attachment.name,
                    mimeType: attachment.mimeType,
                    size: attachment.data.count,
                    previewData: thumbnail?.encodedData,
                    fullPreviewData: attachment.data,
                    preparedThumbnail: thumbnail
                ))
            }
        }
        guard !loadedScopes.contains(scope),
              storageGenerationByScope[scope, default: 0] == startingStorageGeneration else { return }

        sequence &+= 1
        var draft = drafts[scope] ?? Draft(text: "", revision: 0, lastAccess: sequence)
        if let value,
           textMutationRevisionByScope[scope, default: 0] == 0,
           draft.text != value.text {
            draft.text = value.text
            draft.revision &+= 1
        }
        draft.lastAccess = sequence
        drafts[scope] = draft
        let liveAttachments = attachmentsByScope[scope] ?? []
        let mergedAttachments = restoredAttachments + liveAttachments
        attachmentsByScope[scope] = mergedAttachments.isEmpty ? nil : mergedAttachments
        // Persistence may now replace the durable directory because attachment
        // bytes have completed their merge. A newer text mutation remains dirty
        // and is checkpointed together with the restored payloads.
        loadedScopes.insert(scope)
        evictInactiveDraftsIfNeeded()
    }

    private func beginRestoredAttachmentUploads(
        scope: ComposerDraftScope,
        target: SessionPresentationIdentity
    ) {
        guard restoredUploadTasks[target] == nil,
              attachmentsByScope[scope]?.contains(where: { $0.gatewayUploadID == nil }) == true else {
            return
        }
        restoredUploadTasks[target] = Task { @MainActor [weak self] in
            guard let self else { return }
            let identities = self.attachmentsByScope[scope]?.compactMap {
                $0.gatewayUploadID == nil ? $0.id : nil
            } ?? []
            for identity in identities {
                guard !Task.isCancelled, self.admits(target), self.lease?.scope == scope,
                      let attachment = self.attachmentsByScope[scope]?.first(where: { $0.id == identity }),
                      let data = attachment.fullPreviewData else { continue }
                do {
                    let uploadID = try await self.uploadOperation(
                        attachment.name,
                        attachment.mimeType,
                        data
                    )
                    guard !Task.isCancelled, self.admits(target), self.lease?.scope == scope,
                          let index = self.attachmentsByScope[scope]?.firstIndex(where: {
                              $0.id == identity && $0.gatewayUploadID == nil
                          }) else { continue }
                    self.attachmentsByScope[scope]?[index] = attachment.replacingGatewayUploadID(uploadID)
                } catch {
                    // Payload and chip remain durable. A later exact mount retries;
                    // no restored draft is ever sent automatically.
                }
            }
            if self.lease?.target == target { self.restoredUploadTasks[target] = nil }
        }
    }

    private func discardUpload(_ uploadID: String) {
        let operation = discardUploadOperation
        Task { @MainActor in await operation(uploadID) }
    }

    private func schedulePersistence(for scope: ComposerDraftScope) {
        dirtyScopes.insert(scope)
        let predecessor = persistenceTask
        predecessor?.cancel()
        let task = Task { @MainActor [weak self] in
            await predecessor?.value
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            await self?.flushDirtyDrafts()
        }
        persistenceTask = task
    }

    @discardableResult
    private func enqueuePersistence(
        _ operation: @escaping @Sendable (ComposerDraftStore) async -> Void
    ) -> Task<Void, Never> {
        let predecessor = persistenceTask
        predecessor?.cancel()
        let store = draftStore
        let task = Task { @MainActor [weak self] in
            await predecessor?.value
            guard !Task.isCancelled, let self else { return }
            await self.flushDirtyDrafts()
            guard !Task.isCancelled else { return }
            await operation(store)
        }
        persistenceTask = task
        return task
    }

    private func flushDirtyDrafts() async {
        let candidates = dirtyScopes
        for scope in candidates where !loadedScopes.contains(scope) {
            await restoreDraftIfNeeded(scope)
        }
        let scopes = candidates.filter { loadedScopes.contains($0) }
        dirtyScopes.subtract(scopes)
        let checkpoints = scopes.map { ($0, persistentValue(for: $0)) }
        for (scope, value) in checkpoints {
            if let value {
                await draftStore.save(value, for: scope)
            } else {
                await draftStore.remove(scope)
            }
        }
    }

    private func persistentValue(for scope: ComposerDraftScope) -> ComposerDraftStore.Value? {
        var text = drafts[scope]?.text ?? ""
        let admission = submissionByScope[scope]
        let retainsInFlightSubmission = admission.map {
            $0.transportState == .sending && !$0.canonicalObserved
        } ?? false
        let submissionIsSettled = admission.map {
            $0.transportState == .accepted || $0.canonicalObserved
        } ?? false
        if let admission, retainsInFlightSubmission {
            text = ComposerDraftTextPolicy.restoredDraft(
                outgoing: admission.snapshot.outgoingText,
                currentDraft: text
            )
        }
        let settledAttachmentIDs = submissionIsSettled
            ? Set(admission?.submittedAttachments.map(\.id) ?? [])
            : Set<String>()
        let attachments = (attachmentsByScope[scope] ?? []).compactMap { attachment -> ComposerDraftStore.Attachment? in
            guard !settledAttachmentIDs.contains(attachment.id),
                  let data = attachment.fullPreviewData,
                  data.count == attachment.size else { return nil }
            return ComposerDraftStore.Attachment(
                name: attachment.name,
                mimeType: attachment.mimeType,
                data: data
            )
        }
        guard !text.isEmpty || !attachments.isEmpty else { return nil }
        return ComposerDraftStore.Value(text: text, attachments: attachments)
    }

    private func touch(_ scope: ComposerDraftScope, installing initialText: String?) {
        sequence &+= 1
        if var draft = drafts[scope] {
            // Route editor text seeds only a previously absent draft. Reopen or
            // repeated preparation can never replace retained user edits.
            draft.lastAccess = sequence
            drafts[scope] = draft
        } else {
            let seed = initialText ?? ""
            drafts[scope] = Draft(
                text: seed,
                revision: seed.isEmpty ? 0 : 1,
                lastAccess: sequence
            )
        }
        evictInactiveDraftsIfNeeded()
    }

    private func beginUpload(target: SessionPresentationIdentity, bytes: Int) throws -> UploadAdmission {
        guard let lease, admits(target) else { throw CancellationError() }
        let existing = (attachmentsByScope[lease.scope] ?? []).map(\.size)
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
        resourceInvocation: ComposerResourceInvocation?,
        canonicalTranscript: [TranscriptItem],
        queuedMessages: [SessionSnapshot.QueuedMessage]
    ) throws -> SubmissionAdmission {
        guard let lease, admits(target) else { throw CancellationError() }
        guard !uploadAdmissions.contains(where: { $0.target == target }),
              restoredUploadTasks[target] == nil else {
            throw GatewayFailure(
                code: "upload_in_progress",
                message: "Wait for attachments to finish uploading before sending.",
                retryable: true,
                details: nil
            )
        }
        let scope = lease.scope
        guard submissionByScope[scope] == nil else {
            throw GatewayFailure(
                code: "submission_in_progress",
                message: "The previous message is still reconciling. Wait for it to settle before sending again.",
                retryable: true,
                details: nil
            )
        }
        let draft = drafts[scope] ?? Draft(text: "", revision: 0, lastAccess: sequence)
        let rawOutgoing = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedAttachments = attachmentsByScope[scope] ?? []
        let submittedResource = selectedResourceByScope[scope]
        let selectedResource = resourceInvocation ?? submittedResource.map {
            let source: ComposerResourceInvocation.Source = switch $0.source {
            case .skill: .skill
            case .prompt: .prompt
            case .extension: .extension
            }
            return ComposerResourceInvocation(
                source: source,
                name: source == .skill && $0.name.hasPrefix("skill:")
                    ? String($0.name.dropFirst("skill:".count))
                    : $0.name,
                arguments: rawOutgoing
            )
        }
        // A manually typed leading invocation is normalized at the ChatView
        // boundary. Its arguments become the sole visible/executed prompt text.
        let outgoing = resourceInvocation?.arguments ?? rawOutgoing
        if let selectedResource, !selectedResource.isTransportValid {
            throw GatewayFailure(
                code: "invalid_request",
                message: "Resource names and arguments must fit the bounded Gateway invocation contract.",
                retryable: false,
                details: nil
            )
        }
        guard submittedAttachments.allSatisfy({ $0.gatewayUploadID != nil }) else {
            throw GatewayFailure(
                code: "upload_failed",
                message: "Some attachments could not be uploaded. Remove them or leave and reopen this chat to retry.",
                retryable: true,
                details: nil
            )
        }
        let attachmentIDs = submittedAttachments.compactMap(\.gatewayUploadID)
        if selectedResource?.isExtensionCommand == true, !attachmentIDs.isEmpty {
            throw GatewayFailure(
                code: "command_attachments_unsupported",
                message: "Extension commands cannot include attachments.",
                retryable: false,
                details: nil
            )
        }
        guard !outgoing.isEmpty || !attachmentIDs.isEmpty || selectedResource != nil else {
            throw CancellationError()
        }
        sequence &+= 1
        let snapshot = ComposerSubmissionSnapshot(
            target: target,
            textRevision: draft.revision,
            outgoingText: outgoing,
            resourceInvocation: selectedResource,
            attachmentIDs: attachmentIDs,
            behavior: behavior,
            baselineQueuedMessageIDs: Set(queuedMessages.map(\.id)),
            localNonce: sequence
        )
        let admission = SubmissionAdmission(
            id: sequence,
            snapshot: snapshot,
            submittedAttachments: submittedAttachments,
            scope: scope,
            submittedResource: submittedResource,
            resourceMutationRevision: resourceMutationRevisionByScope[scope, default: 0],
            canRestoreSubmittedResource: true,
            baselineTranscriptIDs: Set(canonicalTranscript.map(\.id)),
            lifecycleGeneration: lease.lifecycleGeneration,
            transportState: .sending,
            operationID: nil,
            observedQueuedCandidateIDs: [],
            provisionalQueuedCandidateID: nil,
            canonicalObserved: false,
            transcriptObserved: false,
            canonicalHandoffID: nil
        )
        // A newly admitted prompt is newer presentation ownership. Any
        // unresolved consumed-queue heuristic from the prior lifecycle can no
        // longer claim a future same-text canonical row.
        settledQueueHandoffs[target] = nil
        submissionByScope[scope] = admission
        setText("", for: scope)
        selectedResourceByScope[scope] = nil
        return admission
    }

    private func require(_ admission: SubmissionAdmission) throws {
        try Task.checkCancellation()
        guard submissionByScope[admission.scope]?.id == admission.id,
              admitsLifecycleGeneration(admission.lifecycleGeneration) else {
            throw CancellationError()
        }
    }

    private func requireOutcome(_ admission: SubmissionAdmission) throws {
        guard submissionByScope[admission.scope]?.id == admission.id else {
            throw CancellationError()
        }
    }

    private func restoreSubmission(_ admission: SubmissionAdmission) {
        guard let currentAdmission = submissionByScope[admission.scope],
              currentAdmission.id == admission.id else { return }
        let scope = currentAdmission.scope
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
        if let mounted = lease, mounted.scope == scope {
            attachmentsByScope[scope] = Self.restoredAttachments(
                captured: currentAdmission.submittedAttachments,
                current: attachmentsByScope[scope] ?? [],
                presentationWasReplaced: mounted.target != currentAdmission.snapshot.target
            )
            schedulePersistence(for: scope)
        }
        if currentAdmission.canRestoreSubmittedResource,
           resourceMutationRevisionByScope[scope, default: 0] == currentAdmission.resourceMutationRevision,
           selectedResourceByScope[scope] == nil {
            selectedResourceByScope[scope] = currentAdmission.submittedResource
        }
        if lease?.scope == scope {
            submissionByScope[scope] = nil
        } else {
            var rejected = currentAdmission
            rejected.transportState = .rejected
            submissionByScope[scope] = rejected
        }
    }

    private func restoreRejectedSubmissionIfNeeded(
        scope: ComposerDraftScope,
        target: SessionPresentationIdentity
    ) {
        guard let rejected = submissionByScope[scope],
              rejected.transportState == .rejected else { return }
        attachmentsByScope[scope] = Self.restoredAttachments(
            captured: rejected.submittedAttachments,
            current: attachmentsByScope[scope] ?? [],
            presentationWasReplaced: target != rejected.snapshot.target
        )
        submissionByScope[scope] = nil
        schedulePersistence(for: scope)
    }

    /// Captured upload identities belong to the presentation that submitted
    /// them. A newer chip with the same stable ID is authoritative, including
    /// its fresh or deliberately absent upload ID. Only a missing chip is
    /// restored from the capture, and route replacement makes that copy upload-
    /// required before it can be sent again.
    private static func restoredAttachments(
        captured: [PendingAttachment],
        current: [PendingAttachment],
        presentationWasReplaced: Bool
    ) -> [PendingAttachment] {
        var currentByID = Dictionary(
            current.map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        var restored: [PendingAttachment] = []
        restored.reserveCapacity(captured.count + current.count)
        for attachment in captured {
            if let current = currentByID.removeValue(forKey: attachment.id) {
                restored.append(current)
            } else {
                restored.append(presentationWasReplaced ? attachment.requiringUpload() : attachment)
            }
        }
        let capturedIDs = Set(captured.map(\.id))
        restored.append(contentsOf: current.filter { !capturedIDs.contains($0.id) })
        return restored
    }

    private func markOperationAccepted(_ operationID: String, admission: SubmissionAdmission) {
        guard var current = submissionByScope[admission.scope],
              current.id == admission.id else { return }
        current.operationID = operationID
        if current.provisionalQueuedCandidateID != operationID {
            current.provisionalQueuedCandidateID = nil
        }
        if current.observedQueuedCandidateIDs.contains(operationID) {
            current.canonicalObserved = true
        }
        submissionByScope[admission.scope] = current
    }

    private func markTransportAccepted(_ admission: SubmissionAdmission) {
        guard var accepted = submissionByScope[admission.scope],
              accepted.id == admission.id else { return }
        accepted.transportState = .accepted
        schedulePersistence(for: accepted.scope)
        // Keep the exact captured IDs addressable by the ephemeral row even if
        // the user edited the staged attachment strip while transport awaited
        // acknowledgement. They are removed only at canonical reconciliation.
        let retained = attachmentsByScope[admission.scope] ?? []
        let retainedIDs = Set(retained.map(\.id))
        let captured = admission.submittedAttachments.filter { !retainedIDs.contains($0.id) }
        attachmentsByScope[admission.scope] = captured + retained
        if accepted.canonicalObserved {
            finishSubmission(accepted)
        } else {
            submissionByScope[admission.scope] = accepted
        }
    }

    private func retireSubmissionForLifecycleReset(_ admission: SubmissionAdmission) {
        guard submissionByScope[admission.scope]?.id == admission.id else { return }
        let submitted = Set(admission.submittedAttachments.map(\.id))
        attachmentsByScope[admission.scope]?.removeAll { submitted.contains($0.id) }
        if attachmentsByScope[admission.scope]?.isEmpty == true {
            attachmentsByScope[admission.scope] = nil
        }
        submissionByScope[admission.scope] = nil
        schedulePersistence(for: admission.scope)
    }

    private func finishSubmission(
        _ admission: SubmissionAdmission,
        settlementTarget: SessionPresentationIdentity? = nil
    ) {
        guard let current = submissionByScope[admission.scope],
              current.id == admission.id else { return }
        let target = settlementTarget ?? (lease?.scope == current.scope ? lease?.target : nil)
        if let target, lease?.scope == current.scope {
            if let canonicalHandoffID = current.canonicalHandoffID {
                canonicalHandoffReceipts[target] = CanonicalSubmissionHandoffReceipt(
                    canonicalID: canonicalHandoffID,
                    attachments: current.submittedAttachments.map { $0.frozenForHandoff() },
                    operationID: current.operationID,
                    submission: current.snapshot
                )
            }
            if !current.transcriptObserved,
               let operationID = current.operationID,
               current.snapshot.behavior != nil,
               !current.snapshot.baselineQueuedMessageIDs.contains(operationID) {
                var aliases = settledQueueAliases[target] ?? [:]
                aliases[operationID] = SettledQueueAlias(
                    presentationID: current.snapshot.presentationID,
                    baselineQueueIDs: current.snapshot.baselineQueuedMessageIDs
                )
                if aliases.count > Self.maximumSettledQueueAliases {
                    aliases.removeValue(forKey: aliases.keys.sorted().first!)
                }
                settledQueueAliases[target] = aliases
                settledQueueHandoffs[target] = SettledQueueHandoff(
                    operationID: operationID,
                    snapshot: current.snapshot,
                    submittedAttachments: current.submittedAttachments.map { $0.frozenForHandoff() },
                    baselineTranscriptIDs: current.baselineTranscriptIDs
                )
            }
        }
        let submitted = Set(current.submittedAttachments.map(\.id))
        attachmentsByScope[current.scope]?.removeAll { submitted.contains($0.id) }
        if attachmentsByScope[current.scope]?.isEmpty == true {
            attachmentsByScope[current.scope] = nil
        }
        submissionByScope[current.scope] = nil
        schedulePersistence(for: current.scope)
    }

    private func retireSettledQueueAliases(
        target: SessionPresentationIdentity,
        authoritativeQueueIDs: Set<String>,
        canonicalTranscript: [TranscriptItem]
    ) {
        if let handoff = settledQueueHandoffs[target],
           !authoritativeQueueIDs.contains(handoff.operationID) {
            let matches = canonicalTranscript.filter {
                Self.canonicalUserMessage(
                    $0,
                    matches: handoff.snapshot,
                    submittedAttachments: handoff.submittedAttachments,
                    baselineTranscriptIDs: handoff.baselineTranscriptIDs
                )
            }
            if matches.count == 1 {
                canonicalHandoffReceipts[target] = CanonicalSubmissionHandoffReceipt(
                    canonicalID: matches[0].id,
                    attachments: handoff.submittedAttachments,
                    operationID: handoff.operationID,
                    submission: handoff.snapshot
                )
                settledQueueHandoffs[target] = nil
            }
        }
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
        if let expectedResource = snapshot.resourceInvocation {
            guard item.semantic?.resourceInvocation == expectedResource else { return false }
        } else if item.semantic?.resourceInvocation != nil {
            return false
        }
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
        let contents = item.content ?? []
        guard !submittedAttachments.isEmpty else {
            return !contents.contains { $0.type == .image || $0.attachment != nil }
        }

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
        restoredUploadTasks[lease.target]?.cancel()
        restoredUploadTasks[lease.target] = nil
        if let attachments = attachmentsByScope[lease.scope] {
            let submittedIDs = Set(
                submissionByScope[lease.scope]?.submittedAttachments.map(\.id) ?? []
            )
            for attachment in attachments where !submittedIDs.contains(attachment.id) {
                if let uploadID = attachment.gatewayUploadID {
                    discardUpload(uploadID)
                }
            }
            attachmentsByScope[lease.scope] = attachments.map { $0.requiringUpload() }
            schedulePersistence(for: lease.scope)
        }
        editorRequestByTarget[lease.target] = nil
        // Transport ownership follows durable scope. Presentation revocation
        // clears only target-routed receipts; sending and accepted admissions
        // remain bounded local projections and are never replayed.
        canonicalHandoffReceipts[lease.target] = nil
        settledQueueAliases[lease.target] = nil
        settledQueueHandoffs[lease.target] = nil
        for (admission, task) in uploadTasks where admission.target == lease.target {
            task.cancel()
        }
        uploadAdmissions = uploadAdmissions.filter { $0.target != lease.target }
        uploadAdmissionByAttachmentID = uploadAdmissionByAttachmentID.filter {
            $0.value.target != lease.target
        }
        let retainedSubmission = submissionByScope[lease.scope]
        self.lease = nil
        // Route replacement revokes presentation-only artifacts, never the
        // durable scope-owned transport lifecycle. A sending or accepted
        // admission is projected by the next lease without replaying transport;
        // only already-observed canonical truth can retire it here.
        if let retainedSubmission, retainedSubmission.canonicalObserved {
            finishSubmission(retainedSubmission)
        }
        evictInactiveDraftsIfNeeded()
    }

    private func evictInactiveDraftsIfNeeded() {
        let protectedScopes = Set(submissionByScope.compactMap { scope, admission in
            admission.transportState == .sending ? scope : nil
        }).union(lease.map { [$0.scope] } ?? [])
        var inactive = Array(drafts.filter { !protectedScopes.contains($0.key) })
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
            attachmentsByScope[scope] = nil
            loadedScopes.remove(scope)
            textMutationRevisionByScope[scope] = nil
            dirtyScopes.remove(scope)
            enqueuePersistence { store in await store.remove(scope) }
            selectedResourceByScope[scope] = nil
            resourceMutationRevisionByScope[scope] = nil
            // Safe bounded eviction may retire an accepted presentation-only
            // lifecycle, but never an unresolved transport operation.
            if submissionByScope[scope]?.transportState != .sending {
                submissionByScope[scope] = nil
            }
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

    func installHostedRestoredPresentation(
        profileID: String,
        target: SessionPresentationIdentity,
        lifecycleGeneration: Int,
        initialText: String? = nil
    ) async -> ComposerDraftScope {
        let scope = prepareDraft(
            profileID: profileID,
            sessionID: target.sessionID,
            initialText: initialText
        )
        await restoreDraftIfNeeded(scope)
        _ = beginOpening(scope: scope, lifecycleGeneration: lifecycleGeneration)
        _ = mountPreparedPresentation(target)
        return scope
    }

    func installHostedAttachment(_ attachment: PendingAttachment, target: SessionPresentationIdentity) {
        guard admits(target), let scope = lease?.scope else { return }
        attachmentsByScope[scope, default: []].append(attachment)
        schedulePersistence(for: scope)
    }
    #endif
}
