import Foundation
import Observation

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

struct ComposerSubmissionSnapshot: Equatable, Sendable {
    let target: SessionPresentationIdentity
    let textRevision: Int
    let outgoingText: String
    let attachmentIDs: [String]
    let behavior: String?
}

typealias ComposerUploadOperation = @MainActor @Sendable (
    _ name: String,
    _ mimeType: String,
    _ data: Data
) async throws -> String

typealias ComposerSendOperation = @MainActor @Sendable (
    _ text: String,
    _ sessionID: String,
    _ uploadIDs: [String],
    _ behavior: String?
) async throws -> Void

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
    }

    private struct SubmissionAdmission: Equatable {
        let id: UInt64
        let snapshot: ComposerSubmissionSnapshot
        let submittedAttachments: [PendingAttachment]
        let lifecycleGeneration: Int
    }

    private let uploadOperation: ComposerUploadOperation
    private let sendOperation: ComposerSendOperation
    @ObservationIgnored private let admitsLifecycleGeneration: @MainActor (Int) -> Bool

    private var drafts: [ComposerDraftScope: Draft] = [:]
    private var preparedOpenBySession: [String: PreparedOpen] = [:]
    private var lease: PresentationLease?
    private var attachmentsByTarget: [SessionPresentationIdentity: [PendingAttachment]] = [:]
    private var editorRequestByTarget: [SessionPresentationIdentity: ComposerEditorRequest] = [:]
    private var uploadAdmissions = Set<UploadAdmission>()
    private var submissionByTarget: [SessionPresentationIdentity: SubmissionAdmission] = [:]
    private var sequence: UInt64 = 0

    init(
        upload: @escaping ComposerUploadOperation,
        send: @escaping ComposerSendOperation,
        admitsLifecycleGeneration: @escaping @MainActor (Int) -> Bool
    ) {
        uploadOperation = upload
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

    func editorRequest(for target: SessionPresentationIdentity) -> ComposerEditorRequest? {
        guard admits(target) else { return nil }
        return editorRequestByTarget[target]
    }

    func isSending(target: SessionPresentationIdentity) -> Bool {
        guard admits(target) else { return false }
        return submissionByTarget[target] != nil
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
        let admission = try beginUpload(target: target)
        defer { uploadAdmissions.remove(admission) }
        let id: String
        do {
            id = try await uploadOperation(name, mimeType, data)
        } catch {
            try require(admission)
            throw error
        }
        try require(admission)
        attachmentsByTarget[target, default: []].append(PendingAttachment(
            id: id,
            name: name,
            mimeType: mimeType,
            size: data.count,
            previewData: mimeType.hasPrefix("image/") ? data : nil
        ))
    }

    func removeAttachment(_ id: String, target: SessionPresentationIdentity) {
        guard admits(target), var attachments = attachmentsByTarget[target] else { return }
        attachments.removeAll { $0.id == id }
        attachmentsByTarget[target] = attachments.isEmpty ? nil : attachments
    }

    func send(target: SessionPresentationIdentity, behavior: String?) async throws {
        let admission = try beginSubmission(target: target, behavior: behavior)
        do {
            try await sendOperation(
                admission.snapshot.outgoingText,
                target.sessionID,
                admission.snapshot.attachmentIDs,
                behavior
            )
        } catch {
            try require(admission)
            restoreSubmission(admission)
            throw error
        }
        try require(admission)
        finishSubmission(admission)
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

    private func beginUpload(target: SessionPresentationIdentity) throws -> UploadAdmission {
        guard let lease, admits(target) else { throw CancellationError() }
        sequence &+= 1
        let admission = UploadAdmission(
            id: sequence,
            target: target,
            lifecycleGeneration: lease.lifecycleGeneration
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

    private func beginSubmission(
        target: SessionPresentationIdentity,
        behavior: String?
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
            behavior: behavior
        )
        let admission = SubmissionAdmission(
            id: sequence,
            snapshot: snapshot,
            submittedAttachments: submittedAttachments,
            lifecycleGeneration: lease.lifecycleGeneration
        )
        submissionByTarget[target] = admission
        setText("", for: scope)
        return admission
    }

    private func require(_ admission: SubmissionAdmission) throws {
        guard submissionByTarget[admission.snapshot.target] == admission,
              admits(admission.snapshot.target),
              lease?.lifecycleGeneration == admission.lifecycleGeneration else {
            throw CancellationError()
        }
    }

    private func restoreSubmission(_ admission: SubmissionAdmission) {
        guard submissionByTarget[admission.snapshot.target] == admission,
              let scope = lease?.scope else { return }
        let current = text(for: scope)
        setText(
            ComposerDraftTextPolicy.restoredDraft(
                outgoing: admission.snapshot.outgoingText,
                currentDraft: current
            ),
            for: scope
        )
        let submittedIDs = Set(admission.snapshot.attachmentIDs)
        let newerAttachments = (attachmentsByTarget[admission.snapshot.target] ?? [])
            .filter { !submittedIDs.contains($0.id) }
        attachmentsByTarget[admission.snapshot.target] = admission.submittedAttachments + newerAttachments
        submissionByTarget[admission.snapshot.target] = nil
    }

    private func finishSubmission(_ admission: SubmissionAdmission) {
        let target = admission.snapshot.target
        guard submissionByTarget[target] == admission else { return }
        let submitted = Set(admission.snapshot.attachmentIDs)
        attachmentsByTarget[target]?.removeAll { submitted.contains($0.id) }
        if attachmentsByTarget[target]?.isEmpty == true { attachmentsByTarget[target] = nil }
        submissionByTarget[target] = nil
    }

    private func apply(_ request: ComposerEditorRequest, to scope: ComposerDraftScope) {
        let replacement: String
        switch request.action {
        case .set:
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
