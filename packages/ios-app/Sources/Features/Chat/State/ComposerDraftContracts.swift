import Foundation
import TronMobileCore

struct ComposerDraftScope: Hashable, Sendable {
    let profileID: String
    let sessionID: String
}

struct PendingAttachment: Identifiable, Hashable, Sendable {
    /// Stable chip identity. Restored drafts use a local opaque value.
    let id: String
    /// Staged Gateway upload identity. It belongs to the draft scope, whose
    /// profile is one paired Mac, so it survives presentation revocation and
    /// reconnects to that Mac (#916). It is never persisted; a Gateway that no
    /// longer holds it (expired or reset staging) makes the chip upload again.
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
            // The digest is computed once when preview bytes are admitted.
            // Routine composer equality must never rescan image data.
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

/// The logical route a submission is admitted for. A Home conversation keeps
/// its physical chapter as presentation identity, but its prompts go through
/// `home.prompt`, which resolves the current chapter when the prompt is sent.
enum ComposerSubmissionRoute: Equatable, Sendable {
    case session
    case home
}

struct ComposerSubmissionSnapshot: Equatable, Sendable {
    let target: SessionPresentationIdentity
    let textRevision: Int
    let localNonce: UInt64
    /// User-visible text. Skill transport metadata is deliberately separate so
    /// optimistic, queued, and canonical presentation never expose `/skill:`.
    let outgoingText: String
    /// The typed message without staged annotations; a rejected submission
    /// restores this and `annotations` separately, never the composed envelope.
    let draftText: String
    let annotations: [ChatAnnotation]
    /// Ordered skills and prompts (no arguments), or one extension command
    /// whose arguments are `outgoingText`. Empty for an ordinary message.
    let resourceInvocations: [ComposerResourceInvocation]
    let attachmentIDs: [String]
    let behavior: String?
    let route: ComposerSubmissionRoute
    let baselineQueuedMessageIDs: Set<String>

    init(
        target: SessionPresentationIdentity,
        textRevision: Int,
        outgoingText: String,
        draftText: String? = nil,
        annotations: [ChatAnnotation] = [],
        resourceInvocations: [ComposerResourceInvocation] = [],
        attachmentIDs: [String],
        behavior: String?,
        route: ComposerSubmissionRoute = .session,
        baselineQueuedMessageIDs: Set<String> = [],
        localNonce: UInt64
    ) {
        self.target = target
        self.textRevision = textRevision
        self.localNonce = localNonce
        self.outgoingText = outgoingText
        self.draftText = draftText ?? outgoingText
        self.annotations = annotations
        self.resourceInvocations = resourceInvocations
        self.attachmentIDs = attachmentIDs
        self.behavior = behavior
        self.route = route
        self.baselineQueuedMessageIDs = baselineQueuedMessageIDs
    }

    var isExtensionCommand: Bool { resourceInvocations.first?.isExtensionCommand == true }

    /// Stable only for the owning presentation and admitted submission. This
    /// is a presentation identity, never a transcript/event ID.
    var presentationID: String {
        "outgoing-submission:\(target.sessionID):\(target.generation):\(localNonce)"
    }
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
    _ resourceInvocations: [ComposerResourceInvocation],
    _ route: ComposerSubmissionRoute
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
