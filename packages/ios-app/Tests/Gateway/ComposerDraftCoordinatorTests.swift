import Foundation
import ImageIO
import Observation
import Synchronization
import Testing
@testable import TronMobile

@MainActor
@Suite("Composer draft coordinator")
struct ComposerDraftCoordinatorTests {
    @Test("attachment admission is count and aggregate-byte bounded")
    func attachmentAdmissionPolicy() {
        #expect(ComposerAttachmentPolicy.admits(
            existing: [], active: [], candidate: ComposerAttachmentPolicy.maximumTotalBytes
        ))
        #expect(!ComposerAttachmentPolicy.admits(
            existing: [], active: [], candidate: ComposerAttachmentPolicy.maximumTotalBytes + 1
        ))
        #expect(!ComposerAttachmentPolicy.admits(
            existing: Array(repeating: 1, count: ComposerAttachmentPolicy.maximumCount),
            active: [],
            candidate: 1
        ))
        #expect(!ComposerAttachmentPolicy.admits(
            existing: [ComposerAttachmentPolicy.maximumTotalBytes - 1],
            active: [1],
            candidate: 1
        ))
    }

    @Test("drafts are profile/session isolated, reopen exactly, delete exactly, and evict inactive LRU")
    func draftScopesAndEviction() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let coordinator = harness.coordinator
            let target = SessionPresentationIdentity(sessionID: "session", generation: 1)
            let a = coordinator.installHostedPresentation(
                profileID: "profile-a", target: target, lifecycleGeneration: 1,
                initialText: "draft-a"
            )
            coordinator.setText("edited-a", for: a)
            let repeated = coordinator.prepareDraft(
                profileID: "profile-a", sessionID: "session", initialText: "replacement seed"
            )
            #expect(repeated == a)
            #expect(coordinator.text(for: repeated) == "edited-a")
            coordinator.revoke(target)

            let reopened = coordinator.installHostedPresentation(
                profileID: "profile-a",
                target: .init(sessionID: "session", generation: 2),
                lifecycleGeneration: 1
            )
            #expect(reopened == a)
            #expect(coordinator.text(for: reopened) == "edited-a")
            coordinator.revoke(.init(sessionID: "session", generation: 2))

            let b = coordinator.prepareDraft(
                profileID: "profile-b", sessionID: "session", initialText: "draft-b"
            )
            #expect(coordinator.text(for: a) == "edited-a")
            #expect(coordinator.text(for: b) == "draft-b")

            coordinator.removeSession(profileID: "profile-b", sessionID: "session")
            #expect(coordinator.text(for: b).isEmpty)
            coordinator.removeProfile("profile-a")
            #expect(coordinator.text(for: a).isEmpty)

            for index in 0 ... ComposerDraftCoordinator.maxInactiveDrafts {
                _ = coordinator.prepareDraft(
                    profileID: "eviction",
                    sessionID: "session-\(index)",
                    initialText: String(repeating: "x", count: 4_096 + index)
                )
            }
            #expect(coordinator.hostedDraftCount == ComposerDraftCoordinator.maxInactiveDrafts)
            #expect(coordinator.text(for: .init(profileID: "eviction", sessionID: "session-0")).isEmpty)
            #expect(coordinator.text(for: .init(
                profileID: "eviction",
                sessionID: "session-\(ComposerDraftCoordinator.maxInactiveDrafts)"
            )).count == 4_096 + ComposerDraftCoordinator.maxInactiveDrafts)
        }
    }

    @Test("independent uploads retain exact bytes and publish in completion order")
    func independentUploads() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 7)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1
            )
            let firstData = Data([0, 1, 2, 3])
            let secondData = Data([9, 8])
            let (secondPublished, secondPublishedContinuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            let first = Task {
                try await harness.coordinator.upload(
                    name: "first.bin", mimeType: "application/octet-stream",
                    data: firstData, target: target
                )
            }
            try await harness.waitForUploads(1)
            let second = Task {
                try await harness.coordinator.upload(
                    name: "second.jpg", mimeType: "image/jpeg",
                    data: secondData, target: target
                )
                secondPublishedContinuation.yield(())
                secondPublishedContinuation.finish()
            }
            try await harness.waitForUploads(2)
            #expect(harness.uploadCalls == [
                .init(name: "first.bin", mimeType: "application/octet-stream", data: firstData),
                .init(name: "second.jpg", mimeType: "image/jpeg", data: secondData),
            ])
            harness.completeUpload(index: 1, result: .success("upload-second"))
            var secondPublishedIterator = secondPublished.makeAsyncIterator()
            #expect(await secondPublishedIterator.next() != nil)
            harness.completeUpload(index: 0, result: .success("upload-first"))
            try await valueOfOwnedTask(first)
            try await valueOfOwnedTask(second)

            let attachments = harness.coordinator.pendingAttachments(for: target)
            #expect(attachments.map(\.id) == ["upload-second", "upload-first"])
            #expect(attachments.map(\.name) == ["second.jpg", "first.bin"])
            #expect(attachments[0].previewData == nil)
            #expect(attachments[0].fullPreviewData == nil)
            #expect(attachments[1].previewData == nil)
        }
    }

    @Test("successful image upload retains only its bounded preview")
    func boundedImagePreview() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 8)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1
            )
            let fixture = try SessionScenarioBuilder(seed: 91).generatedImageFixture(
                format: .jpeg,
                pixelWidth: 1_200,
                pixelHeight: 800,
                orientation: .right
            )
            let upload = Task {
                try await harness.coordinator.upload(
                    name: "large.jpg", mimeType: "image/jpeg",
                    data: fixture.encodedData, target: target
                )
            }
            try await harness.waitForUploads(1)
            harness.completeUpload(index: 0, result: .success("upload-image"))
            try await valueOfOwnedTask(upload)

            let attachment = try #require(harness.coordinator.pendingAttachments(for: target).first)
            let preview = try #require(attachment.previewData)
            #expect(attachment.size == fixture.encodedData.count)
            #expect(preview != fixture.encodedData)
            #expect(preview.count <= ComposerAttachmentPreviewPolicy.maximumEncodedBytes)
            #expect(attachment.fullPreviewData == fixture.encodedData)
        }
    }

    @Test("document file upload stages bytes and retains only a bounded preview")
    func documentFileUpload() async throws {
        try await withTestWatchdog { @MainActor in
            let data = Data("document".utf8)
            let access = ComposerFileAccessRecorder(data: data)
            let uploaded = UploadedDataBox()
            let coordinator = ComposerDraftCoordinator(
                upload: { _, _, _ in Issue.record("unexpected data upload"); return "unused" },
                fileUpload: { name, mimeType, file, byteCount in
                    #expect(name == "notes.txt")
                    #expect(mimeType == "text/plain")
                    #expect(byteCount == data.count)
                    uploaded.value = try Data(contentsOf: file)
                    return "document-id"
                },
                attachmentFileAccess: access.seam,
                send: { _, _, _, _ in "unused-operation" },
                admitsLifecycleGeneration: { $0 == 1 }
            )
            let target = SessionPresentationIdentity(sessionID: "session", generation: 9)
            _ = coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1
            )

            try await coordinator.uploadFile(URL(fileURLWithPath: "/tmp/notes.txt"), target: target)

            #expect(uploaded.value == data)
            #expect(access.startCount == 1)
            #expect(access.stopCount == 1)
            #expect(access.previewCount == 1)
            #expect(access.stagingIsClean)
            let attachment = try #require(coordinator.pendingAttachments(for: target).first)
            #expect(attachment.id == "document-id")
            #expect(try #require(attachment.previewData).count <= ComposerAttachmentPreviewPolicy.maximumEncodedBytes)
            #expect(attachment.fullPreviewData == nil)
        }
    }

    @Test("image file upload preserves bounded and full preview data")
    func imageFileUploadPreview() async throws {
        try await withTestWatchdog { @MainActor in
            let fixture = try SessionScenarioBuilder(seed: 92).generatedImageFixture(
                format: .jpeg,
                pixelWidth: 1_200,
                pixelHeight: 800,
                orientation: .right
            )
            let access = ComposerFileAccessRecorder(data: fixture.encodedData)
            let coordinator = ComposerDraftCoordinator(
                upload: { _, _, _ in Issue.record("unexpected data upload"); return "unused" },
                fileUpload: { _, _, _, _ in "image-id" },
                attachmentFileAccess: access.seam,
                send: { _, _, _, _ in "unused-operation" },
                admitsLifecycleGeneration: { $0 == 1 }
            )
            let target = SessionPresentationIdentity(sessionID: "session", generation: 10)
            _ = coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1
            )

            try await coordinator.uploadFile(URL(fileURLWithPath: "/tmp/photo.jpg"), target: target)

            #expect(access.previewCount == 1)
            #expect(access.stagingIsClean)
            let attachment = try #require(coordinator.pendingAttachments(for: target).first)
            #expect(attachment.fullPreviewData == fixture.encodedData)
            #expect(try #require(attachment.previewData).count <= ComposerAttachmentPreviewPolicy.maximumEncodedBytes)
        }
    }

    @Test("file uploads publish by completion and revoked work cleans staging")
    func fileUploadCompletionAndRevocation() async throws {
        try await withTestWatchdog { @MainActor in
            let access = ComposerFileAccessRecorder(data: Data("file".utf8))
            let gate = ComposerFileUploadGate()
            let coordinator = ComposerDraftCoordinator(
                upload: { _, _, _ in Issue.record("unexpected data upload"); return "unused" },
                fileUpload: { name, _, file, _ in try await gate.upload(name: name, file: file) },
                attachmentFileAccess: access.seam,
                send: { _, _, _, _ in "unused-operation" },
                admitsLifecycleGeneration: { $0 == 1 }
            )
            let target = SessionPresentationIdentity(sessionID: "session", generation: 11)
            _ = coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1
            )
            let first = Task {
                try await coordinator.uploadFile(URL(fileURLWithPath: "/tmp/first.txt"), target: target)
            }
            await gate.waitForUploads(1)
            let second = Task {
                try await coordinator.uploadFile(URL(fileURLWithPath: "/tmp/second.txt"), target: target)
            }
            await gate.waitForUploads(2)
            await gate.complete(index: 1, result: .success("second-id"))
            try await second.value
            #expect(coordinator.pendingAttachments(for: target).map(\.id) == ["second-id"])

            coordinator.revoke(target)
            await #expect(throws: CancellationError.self) { try await first.value }
            #expect(access.startCount == 2)
            #expect(access.stopCount == 2)
            #expect(access.stagingIsClean)
        }
    }

    @Test("revocation rejects late upload success and failure across A-B-A")
    func uploadRevocation() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let oldTarget = SessionPresentationIdentity(sessionID: "session", generation: 1)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile-a", target: oldTarget, lifecycleGeneration: 1
            )
            let success = Task {
                try await harness.coordinator.upload(
                    name: "old.txt", mimeType: "text/plain", data: Data("old".utf8),
                    target: oldTarget
                )
            }
            try await harness.waitForUploads(1)
            harness.coordinator.retireProfilePresentation()
            harness.admission.generation = 2
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile-b",
                target: .init(sessionID: "session", generation: 2),
                lifecycleGeneration: 2
            )
            harness.coordinator.retireProfilePresentation()
            harness.admission.generation = 3
            let currentTarget = SessionPresentationIdentity(sessionID: "session", generation: 3)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile-a", target: currentTarget, lifecycleGeneration: 3
            )
            harness.completeUpload(index: 0, result: .success("stale"))
            await #expect(throws: CancellationError.self) { try await valueOfOwnedTask(success) }
            #expect(harness.coordinator.pendingAttachments(for: currentTarget).isEmpty)

            let failure = Task {
                try await harness.coordinator.upload(
                    name: "late.txt", mimeType: "text/plain", data: Data("late".utf8), target: currentTarget
                )
            }
            try await harness.waitForUploads(2)
            harness.coordinator.revoke(currentTarget)
            harness.completeUpload(index: 1, result: .failure(ComposerSyntheticError.current))
            await #expect(throws: CancellationError.self) { try await valueOfOwnedTask(failure) }
            #expect(harness.coordinator.hostedUploadAdmissionCount == 0)
        }
    }

    @Test("active upload cancellation releases admission without revoking its presentation")
    func activeUploadCancellation() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 9)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1
            )
            let uploading = Task {
                try await harness.coordinator.upload(
                    name: "cancel.txt", mimeType: "text/plain", data: Data("cancel".utf8),
                    target: target
                )
            }
            try await harness.waitForUploads(1)
            uploading.cancel()
            harness.completeUpload(index: 0, result: .success("cancelled-upload"))
            await #expect(throws: CancellationError.self) {
                try await valueOfOwnedTask(uploading)
            }
            #expect(harness.coordinator.hostedUploadAdmissionCount == 0)
            #expect(harness.coordinator.admits(target))
            #expect(harness.coordinator.pendingAttachments(for: target).isEmpty)
        }
    }

    @Test("confirmed send captures behavior and IDs while preserving newer draft and attachments")
    func confirmedSend() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 4)
            let scope = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "  outgoing  "
            )
            harness.coordinator.installHostedAttachment(
                .init(id: "a", name: "a", mimeType: "image/jpeg", size: 1, previewData: nil),
                target: target
            )
            harness.coordinator.installHostedAttachment(
                .init(id: "b", name: "b", mimeType: "image/jpeg", size: 1, previewData: nil),
                target: target
            )
            let sending = Task { try await harness.coordinator.send(target: target, behavior: "steer") }
            try await harness.waitForSends(1)
            #expect(harness.sendCalls == [
                .init(text: "outgoing", sessionID: "session", uploadIDs: ["a", "b"], behavior: "steer")
            ])
            #expect(harness.coordinator.isSending(target: target))
            #expect(harness.coordinator.submissionSnapshot(for: target)?.textRevision == 1)
            #expect(harness.coordinator.text(for: scope).isEmpty)

            harness.coordinator.setText("newer", for: scope)
            harness.coordinator.installHostedAttachment(
                .init(id: "c", name: "c", mimeType: "text/plain", size: 1, previewData: nil),
                target: target
            )
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)
            #expect(harness.coordinator.text(for: scope) == "newer")
            #expect(harness.coordinator.pendingAttachments(for: target).map(\.id) == ["a", "b", "c"])
            #expect(harness.coordinator.outgoingSubmission(for: target)?.outgoingText == "outgoing")
            #expect(harness.coordinator.submittedAttachments(for: target).map(\.id) == ["a", "b"])
            #expect(!harness.coordinator.isSending(target: target))

            let canonical = TranscriptItem.message(MessageTranscriptItem(
                id: "canonical-user", parentId: nil, timestamp: "2025-01-01T00:00:00Z",
                kind: .message, role: .user, presentationId: "canonical-user",
                content: [
                    ContentPart(id: "text", ordinal: 0, thinkingRunOrdinal: nil, type: .text, text: "outgoing", attachment: nil, redacted: nil, mimeType: nil, blobId: nil, toolCallId: nil, name: nil, arguments: nil),
                    // Canonical attachment order is not a client-upload identity.
                    ContentPart(id: "image-two", ordinal: 1, thinkingRunOrdinal: nil, type: .image, text: nil, attachment: .init(name: "b", mimeType: "image/jpeg", size: 1), redacted: nil, mimeType: "image/jpeg", blobId: "canonical-blob-b", toolCallId: nil, name: nil, arguments: nil),
                    ContentPart(id: "image-one", ordinal: 2, thinkingRunOrdinal: nil, type: .image, text: nil, attachment: .init(name: "a", mimeType: "image/jpeg", size: 1), redacted: nil, mimeType: "image/jpeg", blobId: "canonical-blob-a", toolCallId: nil, name: nil, arguments: nil),
                ],
                provider: nil, modelId: nil, stopReason: nil, errorMessage: nil, toolCallId: nil,
                toolName: nil, isError: nil, details: nil, usage: nil, startedAt: nil,
                completedAt: nil, durationMs: nil, lastProgressAt: nil, progressSequence: nil
            ))
            harness.coordinator.reconcileSubmission(target: target, canonicalTranscript: [canonical])
            #expect(harness.coordinator.outgoingSubmission(for: target) == nil)
            #expect(harness.coordinator.submittedAttachments(for: target).isEmpty)
            #expect(harness.coordinator.pendingAttachments(for: target).map(\.id) == ["c"])
        }
    }

    @Test("reconciliation ignores historical identical user messages")
    func reconciliationRequiresPostSubmissionCanonicalEntry() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 41)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "same"
            )
            func user(_ id: String) -> TranscriptItem {
                .message(MessageTranscriptItem(
                    id: id, parentId: nil, timestamp: "2025-01-01T00:00:00Z",
                    kind: .message, role: .user, presentationId: id,
                    content: [ContentPart(id: "text", ordinal: 0, thinkingRunOrdinal: nil, type: .text, text: "same", attachment: nil, redacted: nil, mimeType: nil, blobId: nil, toolCallId: nil, name: nil, arguments: nil)],
                    provider: nil, modelId: nil, stopReason: nil, errorMessage: nil, toolCallId: nil,
                    toolName: nil, isError: nil, details: nil, usage: nil, startedAt: nil,
                    completedAt: nil, durationMs: nil, lastProgressAt: nil, progressSequence: nil
                ))
            }
            let historical = user("historical")
            let sending = Task {
                try await harness.coordinator.send(
                    target: target, behavior: nil, canonicalTranscript: [historical]
                )
            }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)
            harness.coordinator.reconcileSubmission(target: target, canonicalTranscript: [historical])
            #expect(harness.coordinator.outgoingSubmission(for: target) != nil)
            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [historical, user("new")]
            )
            #expect(harness.coordinator.outgoingSubmission(for: target) == nil)
        }
    }

    @Test("pre-existing identical queued prompts do not reconcile a newer submission")
    func queuedReconciliationRequiresNewIdentity() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 43)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "same"
            )
            let existing = SessionSnapshot.QueuedMessage(
                id: "existing",
                behavior: .steer,
                text: "same",
                attachmentCount: 0
            )
            let sending = Task {
                try await harness.coordinator.send(
                    target: target,
                    behavior: "steer",
                    queuedMessages: [existing]
                )
            }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)

            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [],
                queuedMessages: [existing]
            )
            #expect(harness.coordinator.outgoingSubmission(for: target) != nil)

            let unrelated = SessionSnapshot.QueuedMessage(
                id: "other-operation",
                behavior: .steer,
                text: "same",
                attachmentCount: 0
            )
            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [],
                queuedMessages: [existing, unrelated]
            )
            #expect(harness.coordinator.outgoingSubmission(for: target) != nil)

            let admitted = SessionSnapshot.QueuedMessage(
                id: "operation-0",
                behavior: .steer,
                text: "same",
                attachmentCount: 0
            )
            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [],
                queuedMessages: [existing, unrelated, admitted]
            )
            #expect(harness.coordinator.outgoingSubmission(for: target) == nil)
        }
    }

    @Test("non-image canonical attachment metadata reconciles without a text blob ID")
    func nonImageAttachmentReconciliation() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 42)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "notes"
            )
            harness.coordinator.installHostedAttachment(
                .init(id: "upload", name: "notes.txt", mimeType: "text/plain", size: 5, previewData: nil),
                target: target
            )
            let sending = Task { try await harness.coordinator.send(target: target, behavior: nil) }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)
            let canonical = TranscriptItem.message(MessageTranscriptItem(
                id: "canonical", parentId: nil, timestamp: "2025-01-01T00:00:00Z",
                kind: .message, role: .user, presentationId: "canonical",
                content: [
                    ContentPart(id: "text", ordinal: 0, thinkingRunOrdinal: nil, type: .text, text: "notes", attachment: nil, redacted: nil, mimeType: nil, blobId: nil, toolCallId: nil, name: nil, arguments: nil),
                    ContentPart(id: "name", ordinal: 1, thinkingRunOrdinal: nil, type: .text, text: "notes.txt", attachment: .init(name: "notes.txt", mimeType: "text/plain", size: 5), redacted: nil, mimeType: nil, blobId: nil, toolCallId: nil, name: nil, arguments: nil),
                ],
                provider: nil, modelId: nil, stopReason: nil, errorMessage: nil, toolCallId: nil,
                toolName: nil, isError: nil, details: nil, usage: nil, startedAt: nil,
                completedAt: nil, durationMs: nil, lastProgressAt: nil, progressSequence: nil
            ))
            harness.coordinator.reconcileSubmission(target: target, canonicalTranscript: [canonical])
            #expect(harness.coordinator.outgoingSubmission(for: target) == nil)
        }
    }

    @Test("attachment-only steering settles from canonical attachment evidence and admits the next send")
    func attachmentOnlySteeringSettlement() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 44)
            let scope = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: ""
            )
            harness.coordinator.installHostedAttachment(
                .init(id: "photo", name: "photo.jpg", mimeType: "image/jpeg", size: 7, previewData: nil),
                target: target
            )
            let first = Task { try await harness.coordinator.send(target: target, behavior: "steer") }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(first)
            #expect(harness.coordinator.outgoingSubmission(for: target) != nil)

            let canonical = TranscriptItem.message(MessageTranscriptItem(
                id: "canonical-photo", parentId: nil, timestamp: "2025-01-01T00:00:00Z",
                kind: .message, role: .user, presentationId: "canonical-photo",
                content: [
                    ContentPart(id: "envelope", ordinal: 0, thinkingRunOrdinal: nil, type: .text, text: "[Attached image context]", attachment: nil, redacted: nil, mimeType: nil, blobId: nil, toolCallId: nil, name: nil, arguments: nil),
                    ContentPart(id: "image", ordinal: 1, thinkingRunOrdinal: nil, type: .image, text: nil, attachment: .init(name: "photo.jpg", mimeType: "image/jpeg", size: 7), redacted: nil, mimeType: "image/jpeg", blobId: "canonical-blob", toolCallId: nil, name: nil, arguments: nil),
                ],
                provider: nil, modelId: nil, stopReason: nil, errorMessage: nil, toolCallId: nil,
                toolName: nil, isError: nil, details: nil, usage: nil, startedAt: nil,
                completedAt: nil, durationMs: nil, lastProgressAt: nil, progressSequence: nil
            ))
            harness.coordinator.reconcileSubmission(target: target, canonicalTranscript: [canonical])
            #expect(harness.coordinator.outgoingSubmission(for: target) == nil)

            harness.coordinator.setText("next", for: scope)
            let second = Task { try await harness.coordinator.send(target: target, behavior: "steer") }
            try await harness.waitForSends(2)
            harness.completeSend(index: 1, result: .success(()))
            try await valueOfOwnedTask(second)
            #expect(harness.sendCalls.last?.text == "next")
        }
    }

    @Test("definitive and uncertain send failures restore outgoing before newer text and retain IDs")
    func failedSendRestoration() async throws {
        try await withTestWatchdog { @MainActor in
            for isUncertain in [false, true] {
                let failure: any Error = isUncertain
                    ? GatewayFailure(
                        code: "outcome_unknown",
                        message: "possibly accepted",
                        retryable: false,
                        details: nil
                    )
                    : ComposerSyntheticError.current
                let harness = ComposerHarness()
                let target = SessionPresentationIdentity(sessionID: "session", generation: 5)
                let scope = harness.coordinator.installHostedPresentation(
                    profileID: "profile", target: target, lifecycleGeneration: 1,
                    initialText: "outgoing"
                )
                harness.coordinator.installHostedAttachment(
                    .init(id: "upload", name: "f", mimeType: "text/plain", size: 1, previewData: nil),
                    target: target
                )
                let sending = Task { try await harness.coordinator.send(target: target, behavior: nil) }
                try await harness.waitForSends(1)
                harness.coordinator.setText("newer", for: scope)
                harness.coordinator.removeAttachment("upload", target: target)
                harness.coordinator.installHostedAttachment(
                    .init(id: "newer-upload", name: "n", mimeType: "text/plain", size: 1, previewData: nil),
                    target: target
                )
                harness.completeSend(index: 0, result: .failure(failure))
                do {
                    try await valueOfOwnedTask(sending)
                    Issue.record("failed send unexpectedly succeeded")
                } catch let gatewayFailure as GatewayFailure {
                    #expect(isUncertain)
                    #expect(gatewayFailure.code == "outcome_unknown")
                } catch is ComposerSyntheticError {
                    #expect(!isUncertain)
                }
                if isUncertain {
                    #expect(harness.coordinator.text(for: scope) == "newer")
                    #expect(harness.coordinator.outgoingSubmission(for: target)?.outgoingText == "outgoing")
                    #expect(harness.coordinator.pendingAttachments(for: target).map(\.id) == [
                        "upload", "newer-upload",
                    ])
                } else {
                    #expect(harness.coordinator.text(for: scope) == "outgoing\nnewer")
                    #expect(harness.coordinator.outgoingSubmission(for: target) == nil)
                    #expect(harness.coordinator.pendingAttachments(for: target).map(\.id) == [
                        "upload", "newer-upload",
                    ])
                }
            }

            let cancelledHarness = ComposerHarness()
            let cancelledTarget = SessionPresentationIdentity(sessionID: "cancelled", generation: 50)
            let cancelledScope = cancelledHarness.coordinator.installHostedPresentation(
                profileID: "profile", target: cancelledTarget, lifecycleGeneration: 1,
                initialText: "restore cancellation"
            )
            let cancelledSend = Task {
                try await cancelledHarness.coordinator.send(target: cancelledTarget, behavior: nil)
            }
            try await cancelledHarness.waitForSends(1)
            cancelledHarness.completeSend(index: 0, result: .failure(CancellationError()))
            await #expect(throws: CancellationError.self) {
                try await valueOfOwnedTask(cancelledSend)
            }
            #expect(cancelledHarness.coordinator.text(for: cancelledScope) == "restore cancellation")
        }
    }

    @Test("retired send completion publishes and restores nothing")
    func retiredSend() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 6)
            let scope = harness.coordinator.installHostedPresentation(
                profileID: "profile-a", target: target, lifecycleGeneration: 1,
                initialText: "outgoing"
            )
            let sending = Task { try await harness.coordinator.send(target: target, behavior: nil) }
            try await harness.waitForSends(1)
            harness.coordinator.retireProfilePresentation()
            harness.completeSend(index: 0, result: .failure(ComposerSyntheticError.current))
            await #expect(throws: CancellationError.self) { try await valueOfOwnedTask(sending) }
            #expect(harness.coordinator.text(for: scope).isEmpty)
        }
    }

    @Test("editor requests auto-apply to empty drafts and use/keep consume exact requests")
    func editorDisposition() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 8)
            let scope = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1
            )
            let automatic = request(target: target, revision: 1, action: .paste, text: "auto", fullText: "auto")
            harness.coordinator.publishEditorRequest(automatic, target: target)
            #expect(harness.coordinator.text(for: scope) == "auto")
            #expect(harness.coordinator.editorRequest(for: target) == nil)

            let keep = request(target: target, revision: 2, action: .set, text: "replace", fullText: "replace")
            harness.coordinator.publishEditorRequest(keep, target: target)
            #expect(harness.coordinator.editorRequest(for: target) == keep)
            harness.coordinator.disposeEditorRequest(keep, disposition: .keep, target: target)
            #expect(harness.coordinator.text(for: scope) == "auto")

            let use = request(target: target, revision: 3, action: .paste, text: "+use", fullText: "ignored")
            harness.coordinator.publishEditorRequest(use, target: target)
            harness.coordinator.disposeEditorRequest(use, disposition: .use, target: target)
            #expect(harness.coordinator.text(for: scope) == "auto+use")
            #expect(harness.coordinator.editorRequest(for: target) == nil)
        }
    }

    @Test("AppModel composer façade observes nested owner changes")
    func nestedObservation() {
        let model = AppModel()
        let scope = model.composerDrafts.prepareDraft(
            profileID: "profile", sessionID: "session", initialText: "before"
        )
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.composerDrafts.text(for: scope)
        } onChange: {
            changed.withLock { $0 = true }
        }
        model.composerDrafts.setText("after", for: scope)
        #expect(changed.withLock { $0 })
        #expect(model.composerDrafts.text(for: scope) == "after")
    }

    private func request(
        target: SessionPresentationIdentity,
        revision: Int,
        action: SessionEditorAction,
        text: String,
        fullText: String
    ) -> ComposerEditorRequest {
        ComposerEditorRequest(
            sessionID: target.sessionID,
            presentationGeneration: target.generation,
            revision: revision,
            action: action,
            text: text,
            fullText: fullText
        )
    }
}

private enum ComposerSyntheticError: Error {
    case current
}

private struct ComposerUploadCall: Equatable {
    let name: String
    let mimeType: String
    let data: Data
}

private struct ComposerSendCall: Equatable {
    let text: String
    let sessionID: String
    let uploadIDs: [String]
    let behavior: String?
}

private actor ComposerFileUploadGate {
    private struct Pending {
        let id: UUID
        let continuation: CheckedContinuation<String, Error>
    }

    private var continuations: [Pending] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func upload(name: String, file: URL) async throws -> String {
        #expect(FileManager.default.fileExists(atPath: file.path))
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations.append(Pending(id: id, continuation: continuation))
                waiters.forEach { $0.resume() }
                waiters.removeAll()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func waitForUploads(_ count: Int) async {
        while continuations.count < count {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func complete(index: Int, result: Result<String, Error>) {
        continuations.remove(at: index).continuation.resume(with: result)
    }

    private func cancel(_ id: UUID) {
        guard let index = continuations.firstIndex(where: { $0.id == id }) else { return }
        continuations.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

@MainActor
private final class UploadedDataBox {
    var value: Data?
}

@MainActor
private final class ComposerFileAccessRecorder {
    private let data: Data
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var previewCount = 0
    private(set) var destinations: [URL] = []

    init(data: Data) {
        self.data = data
    }

    var stagingIsClean: Bool {
        destinations.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
    }

    var seam: ComposerAttachmentFileAccess {
        ComposerAttachmentFileAccess(
            startAccessing: { [weak self] _ in
                self?.startCount += 1
                return true
            },
            size: { [weak self] _ in
                guard let self else { throw CancellationError() }
                return self.data.count
            },
            copy: { [weak self] _, destination, _ in
                guard let self else { throw CancellationError() }
                self.destinations.append(destination)
                try self.data.write(to: destination, options: .withoutOverwriting)
            },
            previewData: { [weak self] file, expectedSize in
                guard let self else { throw CancellationError() }
                self.previewCount += 1
                let data = try Data(contentsOf: file)
                #expect(data.count == expectedSize)
                return data
            },
            stopAccessing: { [weak self] _ in self?.stopCount += 1 }
        )
    }
}

@MainActor
private final class ComposerAdmissionState {
    var generation = 1
}

@MainActor
private final class ComposerHarness {
    let admission = ComposerAdmissionState()
    private(set) var uploadCalls: [ComposerUploadCall] = []
    private(set) var sendCalls: [ComposerSendCall] = []
    private var uploadContinuations: [CheckedContinuation<String, Error>] = []
    private var sendContinuations: [CheckedContinuation<Void, Error>] = []
    private let uploadBarriers: AsyncStream<Int>
    private let uploadBarrierContinuation: AsyncStream<Int>.Continuation
    private let sendBarriers: AsyncStream<Int>
    private let sendBarrierContinuation: AsyncStream<Int>.Continuation

    init() {
        (uploadBarriers, uploadBarrierContinuation) = AsyncStream<Int>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        (sendBarriers, sendBarrierContinuation) = AsyncStream<Int>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    lazy var coordinator = ComposerDraftCoordinator(
        upload: { [weak self] name, mimeType, data in
            guard let self else { throw CancellationError() }
            self.uploadCalls.append(.init(name: name, mimeType: mimeType, data: data))
            self.uploadBarrierContinuation.yield(self.uploadCalls.count)
            return try await withCheckedThrowingContinuation { continuation in
                self.uploadContinuations.append(continuation)
            }
        },
        fileUpload: { _, _, _, _ in
            Issue.record("unexpected file upload")
            throw CancellationError()
        },
        send: { [weak self] text, sessionID, uploadIDs, behavior in
            guard let self else { throw CancellationError() }
            let index = self.sendCalls.count
            self.sendCalls.append(.init(
                text: text, sessionID: sessionID, uploadIDs: uploadIDs, behavior: behavior
            ))
            self.sendBarrierContinuation.yield(self.sendCalls.count)
            try await withCheckedThrowingContinuation { continuation in
                self.sendContinuations.append(continuation)
            }
            return "operation-\(index)"
        },
        admitsLifecycleGeneration: { [weak admission] generation in
            admission?.generation == generation
        }
    )

    func waitForUploads(_ count: Int) async throws {
        guard uploadCalls.count < count else { return }
        var iterator = uploadBarriers.makeAsyncIterator()
        while let observed = await iterator.next() {
            if observed >= count { return }
        }
        throw CancellationError()
    }

    func waitForSends(_ count: Int) async throws {
        guard sendCalls.count < count else { return }
        var iterator = sendBarriers.makeAsyncIterator()
        while let observed = await iterator.next() {
            if observed >= count { return }
        }
        throw CancellationError()
    }

    func completeUpload(index: Int, result: Result<String, Error>) {
        uploadContinuations[index].resume(with: result)
    }

    func completeSend(index: Int, result: Result<Void, Error>) {
        sendContinuations[index].resume(with: result)
    }
}
