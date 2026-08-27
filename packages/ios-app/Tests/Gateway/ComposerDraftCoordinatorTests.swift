import Foundation
import ImageIO
import Observation
import Synchronization
import Testing
@testable import TronMobile

@MainActor
@Suite("Composer draft coordinator")
struct ComposerDraftCoordinatorTests {
    @Test("durable text, photo, and file restore only to the exact remounted scope and re-upload")
    func durableRestartAndRemount() async throws {
        try await withTestWatchdog { @MainActor in
            let root = FileManager.default.temporaryDirectory.appending(
                path: "composer-coordinator-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ComposerDraftStore(root: root)
            let seed = ComposerDraftCoordinator(
                upload: { _, _, _ in "unused" },
                fileUpload: { _, _, _, _ in "unused" },
                draftStore: store,
                send: { _, _, _, _, _ in "unused" },
                admitsLifecycleGeneration: { $0 == 1 }
            )
            let firstTarget = SessionPresentationIdentity(sessionID: "session", generation: 1)
            let scope = seed.installHostedPresentation(
                profileID: "profile", target: firstTarget, lifecycleGeneration: 1
            )
            seed.setText("survive restart", for: scope)
            seed.installHostedAttachment(.init(
                id: "old-photo-upload", name: "photo.jpg", mimeType: "image/jpeg", size: 4,
                previewData: nil, fullPreviewData: Data([0xff, 0xd8, 1, 2])
            ), target: firstTarget)
            seed.installHostedAttachment(.init(
                id: "old-file-upload", name: "notes.txt", mimeType: "text/plain", size: 5,
                previewData: nil, fullPreviewData: Data("notes".utf8)
            ), target: firstTarget)
            await seed.checkpointDrafts().value

            var uploads: [(String, Data)] = []
            let restored = ComposerDraftCoordinator(
                upload: { name, _, data in
                    uploads.append((name, data))
                    return "fresh-\(uploads.count)"
                },
                fileUpload: { _, _, _, _ in "unused" },
                draftStore: store,
                send: { _, _, _, _, _ in "unused" },
                admitsLifecycleGeneration: { $0 == 1 }
            )
            let secondTarget = SessionPresentationIdentity(sessionID: "session", generation: 2)
            let restoredScope = await restored.installHostedRestoredPresentation(
                profileID: "profile",
                target: secondTarget,
                lifecycleGeneration: 1,
                initialText: ""
            )
            for _ in 0..<50 where restored.pendingAttachments(for: secondTarget)
                .contains(where: { $0.gatewayUploadID == nil }) {
                await Task.yield()
            }
            #expect(restoredScope == scope)
            #expect(restored.text(for: restoredScope) == "survive restart")
            #expect(restored.pendingAttachments(for: secondTarget).map(\.name) == ["photo.jpg", "notes.txt"])
            #expect(restored.pendingAttachments(for: secondTarget).map(\.fullPreviewData) == [
                Data([0xff, 0xd8, 1, 2]), Data("notes".utf8),
            ])
            #expect(restored.pendingAttachments(for: secondTarget).compactMap(\.gatewayUploadID) == [
                "fresh-1", "fresh-2",
            ])
            #expect(uploads.map(\.0) == ["photo.jpg", "notes.txt"])

            restored.revoke(secondTarget)
            #expect(restored.pendingAttachments(for: secondTarget).isEmpty)
            let thirdTarget = SessionPresentationIdentity(sessionID: "session", generation: 3)
            _ = await restored.installHostedRestoredPresentation(
                profileID: "profile", target: thirdTarget, lifecycleGeneration: 1
            )
            for _ in 0..<50 where uploads.count < 4 { await Task.yield() }
            #expect(restored.pendingAttachments(for: thirdTarget).count == 2)
            #expect(uploads.count == 4)

            restored.revoke(thirdTarget)
            let isolated = await restored.installHostedRestoredPresentation(
                profileID: "other-profile",
                target: .init(sessionID: "session", generation: 4),
                lifecycleGeneration: 1
            )
            #expect(restored.text(for: isolated).isEmpty)
            #expect(restored.pendingAttachments(for: .init(sessionID: "session", generation: 4)).isEmpty)
        }
    }

    @Test("newer text waits for delayed durable load and preserves restored attachment bytes")
    func textEditDuringDelayedLoad() async throws {
        try await withTestWatchdog { @MainActor in
            let root = FileManager.default.temporaryDirectory.appending(
                path: "composer-delayed-load-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            defer { try? FileManager.default.removeItem(at: root) }
            let scope = ComposerDraftScope(profileID: "profile", sessionID: "session")
            let bytes = Data("persisted attachment".utf8)
            let seed = ComposerDraftStore(root: root)
            await seed.save(.init(
                text: "persisted text",
                attachments: [.init(name: "notes.txt", mimeType: "text/plain", data: bytes)]
            ), for: scope)
            let delayedStore = ComposerDraftStore(root: root, hostedBlocksLoads: true)
            let coordinator = ComposerDraftCoordinator(
                upload: { _, _, _ in "unused" },
                fileUpload: { _, _, _, _ in "unused" },
                draftStore: delayedStore,
                send: { _, _, _, _, _ in "unused" },
                admitsLifecycleGeneration: { $0 == 1 }
            )
            _ = coordinator.prepareDraft(
                profileID: scope.profileID, sessionID: scope.sessionID, initialText: nil
            )
            coordinator.setText("newer typed text", for: scope)
            let checkpoint = coordinator.checkpointDrafts()
            for _ in 0..<100 {
                if await delayedStore.hostedLoadWaiterCount > 0 { break }
                await Task.yield()
            }
            #expect(await delayedStore.hostedLoadWaiterCount == 1)
            #expect(await seed.load(scope)?.attachments.first?.data == bytes)

            await delayedStore.hostedReleaseLoads()
            await checkpoint.value

            let restored = await seed.load(scope)
            #expect(restored?.text == "newer typed text")
            #expect(restored?.attachments.first?.data == bytes)
        }
    }

    @Test("newer text waits for delayed thumbnail preparation and merges restored bytes")
    func textEditDuringDelayedPreparation() async throws {
        try await withTestWatchdog { @MainActor in
            let root = FileManager.default.temporaryDirectory.appending(
                path: "composer-delayed-prep-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            defer { try? FileManager.default.removeItem(at: root) }
            let scope = ComposerDraftScope(profileID: "profile", sessionID: "session")
            let bytes = Data("thumbnail source".utf8)
            let store = ComposerDraftStore(root: root)
            await store.save(.init(
                text: "persisted text",
                attachments: [.init(name: "notes.txt", mimeType: "text/plain", data: bytes)]
            ), for: scope)
            let gate = ComposerPreviewPreparationGate()
            let coordinator = ComposerDraftCoordinator(
                upload: { _, _, _ in "unused" },
                fileUpload: { _, _, _, _ in "unused" },
                prepareAttachmentPreview: { data, mimeType, name in
                    await gate.prepare(data: data, mimeType: mimeType, name: name)
                },
                draftStore: store,
                send: { _, _, _, _, _ in "unused" },
                admitsLifecycleGeneration: { $0 == 1 }
            )
            _ = coordinator.prepareDraft(
                profileID: scope.profileID, sessionID: scope.sessionID, initialText: nil
            )
            coordinator.setText("newer typed text", for: scope)
            let checkpoint = coordinator.checkpointDrafts()
            await gate.waitUntilBlocked()
            #expect(await store.load(scope)?.attachments.first?.data == bytes)

            await gate.release()
            await checkpoint.value

            let restored = await store.load(scope)
            #expect(restored?.text == "newer typed text")
            #expect(restored?.attachments.first?.data == bytes)
        }
    }

    @Test("transient restored upload failure retains exact bytes for remount retry")
    func transientRestoredUploadFailure() async throws {
        try await withTestWatchdog { @MainActor in
            struct TransientFailure: Error {}
            let root = FileManager.default.temporaryDirectory.appending(
                path: "composer-reupload-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ComposerDraftStore(root: root)
            let scope = ComposerDraftScope(profileID: "profile", sessionID: "session")
            let exact = Data("recoverable".utf8)
            await store.save(.init(
                text: "",
                attachments: [.init(name: "notes.txt", mimeType: "text/plain", data: exact)]
            ), for: scope)
            var attempts = 0
            let coordinator = ComposerDraftCoordinator(
                upload: { _, _, data in
                    #expect(data == exact)
                    attempts += 1
                    if attempts == 1 { throw TransientFailure() }
                    return "fresh-upload"
                },
                fileUpload: { _, _, _, _ in "unused" },
                draftStore: store,
                send: { _, _, _, _, _ in "unused" },
                admitsLifecycleGeneration: { $0 == 1 }
            )
            let first = SessionPresentationIdentity(sessionID: scope.sessionID, generation: 1)
            _ = await coordinator.installHostedRestoredPresentation(
                profileID: scope.profileID, target: first, lifecycleGeneration: 1
            )
            for _ in 0..<100 where coordinator.hasActiveUploads(for: first) { await Task.yield() }
            #expect(coordinator.pendingAttachments(for: first).first?.gatewayUploadID == nil)
            #expect(await store.load(scope)?.attachments.first?.data == exact)

            coordinator.revoke(first)
            let second = SessionPresentationIdentity(sessionID: scope.sessionID, generation: 2)
            _ = await coordinator.installHostedRestoredPresentation(
                profileID: scope.profileID, target: second, lifecycleGeneration: 1
            )
            for _ in 0..<100 where coordinator.hasActiveUploads(for: second) { await Task.yield() }
            #expect(attempts == 2)
            #expect(coordinator.pendingAttachments(for: second).first?.gatewayUploadID == "fresh-upload")
            #expect(await store.load(scope)?.attachments.first?.data == exact)
        }
    }

    @Test("durable submission checkpoint clears on acceptance and restores on definitive failure")
    func durableSubmissionSettlement() async throws {
        try await withTestWatchdog { @MainActor in
            let root = FileManager.default.temporaryDirectory.appending(
                path: "composer-settlement-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ComposerDraftStore(root: root)
            let target = SessionPresentationIdentity(sessionID: "session", generation: 1)
            let accepted = ComposerDraftCoordinator(
                upload: { _, _, _ in "upload" },
                fileUpload: { _, _, _, _ in "upload" },
                draftStore: store,
                send: { _, _, _, _, _ in "operation" },
                admitsLifecycleGeneration: { $0 == 1 }
            )
            let acceptedScope = accepted.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "accepted"
            )
            accepted.installHostedAttachment(.init(
                id: "accepted-upload", name: "accepted.txt", mimeType: "text/plain", size: 5,
                previewData: nil, fullPreviewData: Data("bytes".utf8)
            ), target: target)
            await accepted.checkpointDrafts().value
            #expect(await store.load(acceptedScope)?.text == "accepted")

            try await accepted.send(target: target, behavior: nil)
            await accepted.checkpointDrafts().value
            #expect(await store.load(acceptedScope) == nil)

            struct DefinitiveFailure: Error {}
            let failedTarget = SessionPresentationIdentity(sessionID: "failed", generation: 2)
            let failed = ComposerDraftCoordinator(
                upload: { _, _, _ in "fresh-upload" },
                fileUpload: { _, _, _, _ in "unused" },
                draftStore: store,
                send: { _, _, _, _, _ in throw DefinitiveFailure() },
                admitsLifecycleGeneration: { $0 == 1 }
            )
            let failedScope = failed.installHostedPresentation(
                profileID: "profile", target: failedTarget, lifecycleGeneration: 1,
                initialText: "restore me"
            )
            failed.installHostedAttachment(.init(
                id: "failed-upload", name: "failed.txt", mimeType: "text/plain", size: 5,
                previewData: nil, fullPreviewData: Data("exact".utf8)
            ), target: failedTarget)
            await #expect(throws: DefinitiveFailure.self) {
                try await failed.send(target: failedTarget, behavior: nil)
            }
            await failed.checkpointDrafts().value
            #expect(await store.load(failedScope) == .init(
                text: "restore me",
                attachments: [.init(name: "failed.txt", mimeType: "text/plain", data: Data("exact".utf8))]
            ))

            await failed.removeSession(
                profileID: failedScope.profileID,
                sessionID: failedScope.sessionID
            ).value
            #expect(await store.load(failedScope) == nil)
        }
    }

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

    @Test("independent uploads retain exact bytes and stable invocation-order chips")
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
            #expect(attachments.map(\.name) == ["first.bin", "second.jpg"])
            #expect(attachments.compactMap(\.gatewayUploadID) == ["upload-first", "upload-second"])
            #expect(Set(attachments.map(\.id)).count == 2)
            #expect(attachments.allSatisfy { $0.id.hasPrefix("local:") })
            #expect(attachments[0].previewData == nil)
            #expect(attachments[0].fullPreviewData == firstData)
            #expect(attachments[1].previewData == nil)
            #expect(attachments[1].fullPreviewData == secondData)
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
            #expect(attachment.preparedThumbnail != nil)
            #expect(attachment.fullPreviewData == fixture.encodedData)
        }
    }

    @Test("document file upload stages bytes and retains exact live preview bytes only until handoff")
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
                send: { _, _, _, _, _ in "unused-operation" },
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
            #expect(attachment.id.hasPrefix("local:"))
            #expect(attachment.gatewayUploadID == "document-id")
            #expect(try #require(attachment.previewData).count <= ComposerAttachmentPreviewPolicy.maximumEncodedBytes)
            #expect(attachment.preparedThumbnail != nil)
            #expect(attachment.fullPreviewData == data)
            #expect(attachment.frozenForHandoff().fullPreviewData == nil)
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
                send: { _, _, _, _, _ in "unused-operation" },
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
            #expect(attachment.preparedThumbnail != nil)
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
                send: { _, _, _, _, _ in "unused-operation" },
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
            #expect(coordinator.pendingAttachments(for: target).map(\.name) == ["first.txt", "second.txt"])
            #expect(coordinator.pendingAttachments(for: target).compactMap(\.gatewayUploadID) == ["second-id"])

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
            let retainedOld = try #require(
                harness.coordinator.pendingAttachments(for: currentTarget).first
            )
            #expect(retainedOld.name == "old.txt")
            #expect(retainedOld.gatewayUploadID == nil)
            #expect(retainedOld.fullPreviewData == Data("old".utf8))

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
            let retained = try #require(harness.coordinator.pendingAttachments(for: target).first)
            #expect(retained.name == "cancel.txt")
            #expect(retained.gatewayUploadID == nil)
            #expect(retained.fullPreviewData == Data("cancel".utf8))
        }
    }

    @Test("capacity failure retains one local attachment and exact retry bytes")
    func failedFreshUploadRetainsLocalDraft() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 91)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1
            )
            let data = Data("retain after capacity".utf8)
            let uploading = Task {
                try await harness.coordinator.upload(
                    name: "capacity.txt", mimeType: "text/plain", data: data,
                    target: target
                )
            }
            try await harness.waitForUploads(1)
            harness.completeUpload(index: 0, result: .failure(GatewayFailure(
                code: "busy", message: "capacity full", retryable: true,
                details: .object(["reason": .string("bytes")])
            )))
            await #expect(throws: GatewayFailure.self) { try await valueOfOwnedTask(uploading) }

            let retained = try #require(harness.coordinator.pendingAttachments(for: target).first)
            #expect(retained.id.hasPrefix("local:"))
            #expect(retained.gatewayUploadID == nil)
            #expect(retained.fullPreviewData == data)
            #expect(harness.coordinator.hasActiveUploads(for: target) == false)
        }
    }

    @Test("send fails closed during an exact-target upload and retries without clearing the draft")
    func activeUploadRejectsSend() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 10)
            let scope = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "retain this draft"
            )
            let uploading = Task {
                try await harness.coordinator.upload(
                    name: "pending.txt", mimeType: "text/plain", data: Data("pending".utf8),
                    target: target
                )
            }
            try await harness.waitForUploads(1)
            #expect(harness.coordinator.hasActiveUploads(for: target))

            do {
                _ = try harness.coordinator.beginSubmission(target: target, behavior: nil)
                Issue.record("send admitted while its attachment upload was active")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "upload_in_progress")
            }
            #expect(harness.coordinator.text(for: scope) == "retain this draft")
            #expect(harness.coordinator.outgoingSubmission(for: target) == nil)
            #expect(harness.sendCalls.isEmpty)

            harness.completeUpload(index: 0, result: .success("pending-upload"))
            try await valueOfOwnedTask(uploading)
            #expect(!harness.coordinator.hasActiveUploads(for: target))
            let submission = try harness.coordinator.beginSubmission(target: target, behavior: nil)
            #expect(submission.outgoingText == "retain this draft")
            #expect(submission.attachmentIDs == ["pending-upload"])
            #expect(harness.coordinator.text(for: scope).isEmpty)
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
                kind: .message, role: .user, presentationId: "operation-0",
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

    @Test("one staged skill replaces its predecessor and definitive send failure restores it")
    func selectedSkillLifecycle() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 40)
            let scope = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "Inspect this"
            )
            let review = CommandInfo(
                name: "skill:review", description: "Review", argumentHint: nil,
                source: .skill, sourcePath: "/skills/review"
            )
            let repair = CommandInfo(
                name: "skill:repair", description: "Repair", argumentHint: nil,
                source: .skill, sourcePath: "/skills/repair"
            )
            harness.coordinator.selectSkill(review, for: scope)
            harness.coordinator.selectSkill(repair, for: scope)
            #expect(harness.coordinator.selectedSkill(for: scope) == repair)
            harness.coordinator.removeSelectedSkill(for: scope)
            #expect(harness.coordinator.selectedSkill(for: scope) == nil)
            harness.coordinator.selectSkill(repair, for: scope)

            let sending = Task { try await harness.coordinator.send(target: target, behavior: nil) }
            try await harness.waitForSends(1)
            #expect(harness.sendCalls[0].text == "Inspect this")
            #expect(harness.sendCalls[0].skillName == "repair")
            #expect(harness.coordinator.selectedSkill(for: scope) == nil)
            harness.completeSend(index: 0, result: .failure(ComposerSyntheticError.current))
            await #expect(throws: ComposerSyntheticError.self) { try await valueOfOwnedTask(sending) }
            #expect(harness.coordinator.text(for: scope) == "Inspect this")
            #expect(harness.coordinator.selectedSkill(for: scope) == repair)

            harness.coordinator.reconcileSelectedSkill(for: scope, commands: [review])
            #expect(harness.coordinator.selectedSkill(for: scope) == nil)

            harness.coordinator.selectSkill(repair, for: scope)
            let mutatedWhileSending = Task { try await harness.coordinator.send(target: target, behavior: nil) }
            try await harness.waitForSends(2)
            harness.coordinator.selectSkill(review, for: scope)
            harness.coordinator.removeSelectedSkill(for: scope)
            harness.completeSend(index: 1, result: .failure(ComposerSyntheticError.current))
            await #expect(throws: ComposerSyntheticError.self) { try await valueOfOwnedTask(mutatedWhileSending) }
            #expect(harness.coordinator.selectedSkill(for: scope) == nil)

            harness.coordinator.selectSkill(repair, for: scope)
            let retiredWhileSending = Task { try await harness.coordinator.send(target: target, behavior: nil) }
            try await harness.waitForSends(3)
            harness.coordinator.reconcileSelectedSkill(for: scope, commands: [review])
            harness.completeSend(index: 2, result: .failure(ComposerSyntheticError.current))
            await #expect(throws: ComposerSyntheticError.self) { try await valueOfOwnedTask(retiredWhileSending) }
            #expect(harness.coordinator.selectedSkill(for: scope) == nil)
        }
    }

    @Test("known operation identity never falls back to identical canonical text")
    func reconciliationRequiresExactOperationIdentity() async throws {
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
            #expect(harness.coordinator.outgoingSubmission(for: target) != nil)
            let exact = TranscriptItem.message(MessageTranscriptItem(
                id: "exact", parentId: nil, timestamp: "2025-01-01T00:00:00Z",
                kind: .message, role: .user, presentationId: "operation-0",
                content: [ContentPart(id: "text", ordinal: 0, thinkingRunOrdinal: nil, type: .text, text: "same", attachment: nil, redacted: nil, mimeType: nil, blobId: nil, toolCallId: nil, name: nil, arguments: nil)],
                provider: nil, modelId: nil, stopReason: nil, errorMessage: nil, toolCallId: nil,
                toolName: nil, isError: nil, details: nil, usage: nil, startedAt: nil,
                completedAt: nil, durationMs: nil, lastProgressAt: nil, progressSequence: nil
            ))
            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [historical, user("new"), exact]
            )
            #expect(harness.coordinator.outgoingSubmission(for: target) == nil)
        }
    }

    @Test("operation-bound canonical presentation identity resolves repeated prompt text")
    func operationIdentityResolvesRepeatedCanonicalText() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 44)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "same"
            )
            let sending = Task {
                try await harness.coordinator.send(target: target, behavior: nil)
            }
            try await harness.waitForSends(1)
            #expect(harness.coordinator.matchesPendingPrompt(
                target: target,
                pending: .init(
                    id: "operation-0", createdAt: "2026-01-01T00:00:00Z",
                    behavior: nil, text: "same", attachmentCount: 0
                )
            ))
            #expect(!harness.coordinator.matchesPendingPrompt(
                target: target,
                pending: .init(
                    id: "operation-other", createdAt: "2026-01-01T00:00:00Z",
                    behavior: nil, text: "different", attachmentCount: 0
                )
            ))
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)

            func user(_ id: String, presentationID: String) -> TranscriptItem {
                .message(MessageTranscriptItem(
                    id: id, parentId: nil, timestamp: "2026-01-01T00:00:00Z",
                    kind: .message, role: .user, presentationId: presentationID,
                    content: [ContentPart(
                        id: "text", ordinal: 0, thinkingRunOrdinal: nil,
                        type: .text, text: "same", attachment: nil,
                        redacted: nil, mimeType: nil, blobId: nil,
                        toolCallId: nil, name: nil, arguments: nil
                    )],
                    provider: nil, modelId: nil, stopReason: nil,
                    errorMessage: nil, toolCallId: nil, toolName: nil,
                    isError: nil, details: nil, usage: nil, startedAt: nil,
                    completedAt: nil, durationMs: nil, lastProgressAt: nil,
                    progressSequence: nil
                ))
            }
            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [
                    user("unrelated", presentationID: "unrelated"),
                    user("owned", presentationID: "operation-0"),
                ]
            )
            #expect(harness.coordinator.outgoingSubmission(for: target) == nil)
            #expect(harness.coordinator.canonicalSubmissionHandoff(target: target)?.canonicalID == "owned")
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
            let admittedPresentationID = harness.coordinator.submissionSnapshot(for: target)!.presentationID
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
            #expect(harness.coordinator.queuedSubmissionPresentationID(
                target: target,
                message: existing
            ) == nil)
            #expect(harness.coordinator.queuedSubmissionPresentationID(
                target: target,
                message: unrelated
            ) == nil)
            #expect(harness.coordinator.queuedSubmissionPresentationID(
                target: target,
                message: admitted
            ) == admittedPresentationID)
        }
    }

    @Test("a unique snapshot-before-response queue candidate borrows visual identity without settling")
    func uniqueProvisionalQueueCandidateIsVisualOnly() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 45)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "provisional"
            )
            let sending = Task {
                try await harness.coordinator.send(target: target, behavior: "steer")
            }
            try await harness.waitForSends(1)
            let presentationID = try #require(
                harness.coordinator.submissionSnapshot(for: target)?.presentationID
            )
            let candidate = SessionSnapshot.QueuedMessage(
                id: "operation-0", behavior: .steer, text: "provisional", attachmentCount: 0
            )

            harness.coordinator.reconcileSubmission(
                target: target, canonicalTranscript: [], queuedMessages: [candidate]
            )
            #expect(harness.coordinator.outgoingSubmission(for: target) != nil)
            #expect(harness.coordinator.isSending(target: target))
            #expect(harness.coordinator.queuedSubmissionPresentationID(
                target: target, message: candidate
            ) == presentationID)

            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)
            #expect(harness.coordinator.outgoingSubmission(for: target) == nil)
            #expect(harness.coordinator.queuedSubmissionPresentationID(
                target: target, message: candidate
            ) == presentationID)
        }
    }

    @Test("ambiguous provisional queue candidates fail closed")
    func ambiguousProvisionalQueueCandidatesDoNotAlias() async throws {
        struct Rejected: Error {}
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 46)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "same"
            )
            let sending = Task {
                try await harness.coordinator.send(target: target, behavior: "steer")
            }
            try await harness.waitForSends(1)
            let candidates = [
                SessionSnapshot.QueuedMessage(
                    id: "other-a", behavior: .steer, text: "same", attachmentCount: 0
                ),
                SessionSnapshot.QueuedMessage(
                    id: "other-b", behavior: .steer, text: "same", attachmentCount: 0
                ),
            ]
            harness.coordinator.reconcileSubmission(
                target: target, canonicalTranscript: [], queuedMessages: candidates
            )
            #expect(candidates.allSatisfy {
                harness.coordinator.queuedSubmissionPresentationID(
                    target: target, message: $0
                ) == nil
            })
            #expect(harness.coordinator.outgoingSubmission(for: target) != nil)

            harness.completeSend(index: 0, result: .failure(Rejected()))
            await #expect(throws: Rejected.self) { try await sending.value }
        }
    }

    @Test("a conflicting transport ID clears provisional visual continuity")
    func conflictingOperationIDClearsProvisionalCandidate() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 47)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "race"
            )
            let sending = Task {
                try await harness.coordinator.send(target: target, behavior: "steer")
            }
            try await harness.waitForSends(1)
            let wrong = SessionSnapshot.QueuedMessage(
                id: "other-operation", behavior: .steer, text: "race", attachmentCount: 0
            )
            harness.coordinator.reconcileSubmission(
                target: target, canonicalTranscript: [], queuedMessages: [wrong]
            )
            #expect(harness.coordinator.queuedSubmissionPresentationID(
                target: target, message: wrong
            ) != nil)

            // ComposerHarness returns operation-0 for the first accepted send.
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)
            #expect(harness.coordinator.queuedSubmissionPresentationID(
                target: target, message: wrong
            ) == nil)
            #expect(harness.coordinator.outgoingSubmission(for: target) != nil)
        }
    }

    @Test("duplicate queue IDs fail closed when freezing presentation aliases")
    func duplicateQueueIDsDoNotTrapAliasCapture() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 48)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "duplicate"
            )
            let sending = Task {
                try await harness.coordinator.send(target: target, behavior: "steer")
            }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)
            let duplicate = SessionSnapshot.QueuedMessage(
                id: "operation-0", behavior: .steer, text: "duplicate", attachmentCount: 0
            )

            #expect(harness.coordinator.queuedSubmissionPresentationIDs(
                target: target,
                queuedMessages: [duplicate, duplicate]
            ).isEmpty)
            #expect(harness.coordinator.outgoingSubmission(for: target) != nil)
        }
    }

    @Test("duplicate authoritative queue IDs cannot settle an outgoing submission")
    func duplicateQueueIDsFailClosedBeforeSettlement() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 46)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "duplicate"
            )
            let sending = Task { try await harness.coordinator.send(target: target, behavior: "steer") }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)
            let duplicate = SessionSnapshot.QueuedMessage(
                id: "operation-0", behavior: .steer, text: "duplicate", attachmentCount: 0
            )
            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [],
                queuedMessages: [duplicate, duplicate]
            )
            // Invalid queue data cannot settle or hide the outgoing lifecycle
            // row. The projection owner rejects this same malformed snapshot.
            #expect(harness.coordinator.outgoingSubmission(for: target) != nil)
        }
    }

    @Test("settled aliases reject a reused baseline operation ID")
    func reusedBaselineOperationIDDoesNotAlias() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 47)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "reused"
            )
            let baseline = SessionSnapshot.QueuedMessage(
                id: "operation-0", behavior: .steer, text: "old", attachmentCount: 0
            )
            let sending = Task {
                try await harness.coordinator.send(
                    target: target, behavior: "steer", queuedMessages: [baseline]
                )
            }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)
            let reused = baseline
            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [],
                queuedMessages: [reused]
            )
            #expect(harness.coordinator.outgoingSubmission(for: target) != nil)
            #expect(harness.coordinator.queuedSubmissionPresentationID(
                target: target, message: reused
            ) == nil)
        }
    }

    @Test("settled queue aliases are operation keyed, bounded, editable, and retired")
    func settledQueueAliasLifecycle() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 44)
            let scope = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "first"
            )
            let first = Task { try await harness.coordinator.send(target: target, behavior: "steer") }
            try await harness.waitForSends(1)
            let firstID = harness.coordinator.submissionSnapshot(for: target)!.presentationID
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(first)
            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [],
                queuedMessages: [.init(id: "operation-0", behavior: .steer, text: "first", attachmentCount: 0)]
            )
            #expect(harness.coordinator.queuedSubmissionPresentationID(
                target: target,
                message: .init(id: "operation-0", behavior: .steer, text: "edited", attachmentCount: 9)
            ) == firstID)

            harness.coordinator.setText("second", for: scope)
            let second = Task { try await harness.coordinator.send(target: target, behavior: "followUp") }
            try await harness.waitForSends(2)
            harness.completeSend(index: 1, result: .success(()))
            try await valueOfOwnedTask(second)
            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [],
                queuedMessages: [
                    .init(id: "operation-0", behavior: .steer, text: "edited", attachmentCount: 9),
                    .init(id: "operation-1", behavior: .followUp, text: "second", attachmentCount: 0),
                ]
            )
            #expect(harness.coordinator.queuedSubmissionPresentationID(
                target: target,
                message: .init(id: "operation-0", behavior: .steer, text: "edited", attachmentCount: 9)
            ) == firstID)
            #expect(harness.coordinator.queuedSubmissionPresentationID(
                target: target,
                message: .init(id: "operation-1", behavior: .followUp, text: "changed", attachmentCount: 1)
            ) != nil)

            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [],
                queuedMessages: [.init(id: "operation-1", behavior: .followUp, text: "changed", attachmentCount: 1)]
            )
            #expect(harness.coordinator.queuedSubmissionPresentationID(
                target: target,
                message: .init(id: "operation-0", behavior: .steer, text: "edited", attachmentCount: 9)
            ) == nil)
            harness.coordinator.revoke(target)
            #expect(harness.coordinator.queuedSubmissionPresentationID(
                target: target,
                message: .init(id: "operation-1", behavior: .followUp, text: "changed", attachmentCount: 1)
            ) == nil)
        }
    }

    @Test("consecutive attachment-only submissions receive distinct local presentation IDs")
    func attachmentOnlyPresentationIDsAreUnique() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 45)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: ""
            )
            harness.coordinator.installHostedAttachment(
                .init(id: "first", name: "one.jpg", mimeType: "image/jpeg", size: 1, previewData: nil),
                target: target
            )
            let first = Task { try await harness.coordinator.send(target: target, behavior: "steer") }
            try await harness.waitForSends(1)
            let firstID = harness.coordinator.submissionSnapshot(for: target)!.presentationID
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(first)
            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [],
                queuedMessages: [.init(id: "operation-0", behavior: .steer, text: "", attachmentCount: 1)]
            )
            harness.coordinator.installHostedAttachment(
                .init(id: "second", name: "two.jpg", mimeType: "image/jpeg", size: 1, previewData: nil),
                target: target
            )
            let second = Task { try await harness.coordinator.send(target: target, behavior: "steer") }
            try await harness.waitForSends(2)
            let secondID = harness.coordinator.submissionSnapshot(for: target)!.presentationID
            #expect(firstID != secondID)
            harness.completeSend(index: 1, result: .success(()))
            try await valueOfOwnedTask(second)
        }
    }

    @Test("canonical handoff receipt is preserved before admission retirement and consumed once")
    func canonicalHandoffReceiptIsOneShot() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 48)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "direct"
            )
            let sending = Task { try await harness.coordinator.send(target: target, behavior: nil) }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)
            let canonical = try decodeTranscriptFixture(
                TranscriptItem.self,
                from: Data("{\"id\":\"canonical-direct\",\"parentId\":null,\"timestamp\":\"2026-01-01T00:00:01Z\",\"kind\":\"message\",\"role\":\"user\",\"presentationId\":\"operation-0\",\"content\":[{\"id\":\"text\",\"ordinal\":0,\"type\":\"text\",\"text\":\"direct\"}]}".utf8))
            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [canonical]
            )
            #expect(harness.coordinator.outgoingSubmission(for: target) == nil)
            let receipt = try #require(harness.coordinator.consumeCanonicalSubmissionHandoff(target: target))
            #expect(receipt.canonicalID == "canonical-direct")
            #expect(receipt.attachments.isEmpty)
            #expect(harness.coordinator.consumeCanonicalSubmissionHandoff(target: target) == nil)
        }
    }

    @Test("canonical handoff retains only the newest unconsumed lifecycle receipt")
    func canonicalHandoffReceiptIsSingleBounded() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 51)
            let scope = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "first"
            )
            func canonical(_ id: String, operationID: String, text: String) throws -> TranscriptItem {
                try decodeTranscriptFixture(
                    TranscriptItem.self,
                    from: Data("{\"id\":\"\(id)\",\"parentId\":null,\"timestamp\":\"2026-01-01T00:00:01Z\",\"kind\":\"message\",\"role\":\"user\",\"presentationId\":\"\(operationID)\",\"content\":[{\"id\":\"text\",\"ordinal\":0,\"type\":\"text\",\"text\":\"\(text)\"}]}".utf8)
                )
            }

            let firstSend = Task { try await harness.coordinator.send(target: target, behavior: nil) }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(firstSend)
            let first = try canonical("canonical-first", operationID: "operation-0", text: "first")
            harness.coordinator.reconcileSubmission(target: target, canonicalTranscript: [first])

            harness.coordinator.setText("second", for: scope)
            let secondSend = Task {
                try await harness.coordinator.send(
                    target: target, behavior: nil, canonicalTranscript: [first]
                )
            }
            try await harness.waitForSends(2)
            harness.completeSend(index: 1, result: .success(()))
            try await valueOfOwnedTask(secondSend)
            let second = try canonical("canonical-second", operationID: "operation-1", text: "second")
            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [first, second]
            )

            #expect(harness.coordinator.consumeCanonicalSubmissionHandoff(target: target)?.canonicalID == "canonical-second")
            #expect(harness.coordinator.consumeCanonicalSubmissionHandoff(target: target) == nil)
        }
    }

    @Test("canonical handoff freezes one bounded attachment preview and strips full bytes")
    func canonicalHandoffFreezesPreview() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 50)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "photo"
            )
            let fixture = try SessionScenarioBuilder(seed: 9_501).generatedImageFixture(
                format: .jpeg, pixelWidth: 600, pixelHeight: 400, orientation: .up
            )
            let prepared = try #require(ComposerAttachmentPreviewPolicy.preparePayloadSynchronously(
                fixture.encodedData, mimeType: "image/jpeg", name: "photo.jpg"
            ))
            let preview = prepared.encodedData
            harness.coordinator.installHostedAttachment(
                .init(
                    id: "photo-upload", name: "photo.jpg", mimeType: "image/jpeg", size: 8,
                    previewData: preview, fullPreviewData: fixture.encodedData,
                    preparedThumbnail: prepared
                ),
                target: target
            )
            let sending = Task { try await harness.coordinator.send(target: target, behavior: nil) }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)
            let canonical = TranscriptItem.message(MessageTranscriptItem(
                id: "canonical-photo", parentId: nil, timestamp: "2026-01-01T00:00:01Z",
                kind: .message, role: .user, presentationId: "operation-0",
                content: [
                    ContentPart(id: "text", ordinal: 0, thinkingRunOrdinal: nil, type: .text, text: "photo", attachment: nil, redacted: nil, mimeType: nil, blobId: nil, toolCallId: nil, name: nil, arguments: nil),
                    ContentPart(id: "image", ordinal: 1, thinkingRunOrdinal: nil, type: .image, text: nil, attachment: nil, redacted: nil, mimeType: "image/jpeg", blobId: "canonical-blob", toolCallId: nil, name: nil, arguments: nil),
                ],
                provider: nil, modelId: nil, stopReason: nil, errorMessage: nil,
                toolCallId: nil, toolName: nil, isError: nil, details: nil, usage: nil,
                startedAt: nil, completedAt: nil, durationMs: nil,
                lastProgressAt: nil, progressSequence: nil
            ))
            harness.coordinator.reconcileSubmission(target: target, canonicalTranscript: [canonical])

            let receipt = try #require(harness.coordinator.consumeCanonicalSubmissionHandoff(target: target))
            #expect(receipt.canonicalID == "canonical-photo")
            #expect(receipt.attachments.count == 1)
            #expect(receipt.attachments[0].previewData == preview)
            #expect(receipt.attachments[0].preparedThumbnail != nil)
            #expect(receipt.attachments[0].fullPreviewData == nil)
        }
    }

    @Test("queued steering carries its frozen preview into later canonical settlement")
    func queuedCanonicalHandoffCarriesPreview() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 52)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "queued photo"
            )
            let fixture = try SessionScenarioBuilder(seed: 9_502).generatedImageFixture(
                format: .jpeg, pixelWidth: 600, pixelHeight: 400, orientation: .up
            )
            let prepared = try #require(ComposerAttachmentPreviewPolicy.preparePayloadSynchronously(
                fixture.encodedData, mimeType: "image/jpeg", name: "photo.jpg"
            ))
            let preview = prepared.encodedData
            harness.coordinator.installHostedAttachment(
                .init(
                    id: "photo-upload", name: "photo.jpg", mimeType: "image/jpeg", size: 3,
                    previewData: preview, fullPreviewData: fixture.encodedData,
                    preparedThumbnail: prepared
                ),
                target: target
            )
            let sending = Task { try await harness.coordinator.send(target: target, behavior: "steer") }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)
            let queued = SessionSnapshot.QueuedMessage(
                id: "operation-0", behavior: .steer, text: "queued photo",
                attachmentCount: 1, photoCount: 1, fileAttachmentCount: 0
            )
            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [],
                queuedMessages: [queued]
            )
            #expect(harness.coordinator.outgoingSubmission(for: target) == nil)
            #expect(harness.coordinator.consumeCanonicalSubmissionHandoff(target: target) == nil)
            // Queue removal and canonical append may publish in separate
            // snapshots. The lifecycle must survive the intermediate gap.
            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [],
                queuedMessages: []
            )
            #expect(harness.coordinator.consumeCanonicalSubmissionHandoff(target: target) == nil)

            let canonical = TranscriptItem.message(MessageTranscriptItem(
                id: "canonical-queued-photo", parentId: nil, timestamp: "2026-01-01T00:00:02Z",
                kind: .message, role: .user, presentationId: "canonical-queued-photo",
                content: [
                    ContentPart(id: "text", ordinal: 0, thinkingRunOrdinal: nil, type: .text, text: "queued photo", attachment: nil, redacted: nil, mimeType: nil, blobId: nil, toolCallId: nil, name: nil, arguments: nil),
                    ContentPart(id: "image", ordinal: 1, thinkingRunOrdinal: nil, type: .image, text: nil, attachment: nil, redacted: nil, mimeType: "image/jpeg", blobId: "canonical-queued-blob", toolCallId: nil, name: nil, arguments: nil),
                ],
                provider: nil, modelId: nil, stopReason: nil, errorMessage: nil,
                toolCallId: nil, toolName: nil, isError: nil, details: nil, usage: nil,
                startedAt: nil, completedAt: nil, durationMs: nil,
                lastProgressAt: nil, progressSequence: nil
            ))
            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [canonical],
                queuedMessages: []
            )
            let receipt = try #require(harness.coordinator.consumeCanonicalSubmissionHandoff(target: target))
            #expect(receipt.canonicalID == "canonical-queued-photo")
            #expect(receipt.operationID == queued.id)
            #expect(receipt.attachments.count == 1)
            #expect(receipt.attachments[0].previewData == preview)
            #expect(receipt.attachments[0].preparedThumbnail != nil)
            #expect(receipt.attachments[0].fullPreviewData == nil)
        }
    }

    @Test("text-only queued steering survives a queue-absent snapshot before canonical settlement")
    func queuedTextCanonicalHandoffSurvivesGap() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 53)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "queued text"
            )
            let sending = Task { try await harness.coordinator.send(target: target, behavior: "steer") }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)
            let queued = SessionSnapshot.QueuedMessage(
                id: "operation-0", behavior: .steer, text: "queued text", attachmentCount: 0
            )
            harness.coordinator.reconcileSubmission(
                target: target, canonicalTranscript: [], queuedMessages: [queued]
            )
            harness.coordinator.invalidateSettledQueueHandoff(
                target: target,
                affectedOperationIDs: ["unrelated-operation"]
            )
            harness.coordinator.reconcileSubmission(
                target: target, canonicalTranscript: [], queuedMessages: []
            )
            #expect(harness.coordinator.consumeCanonicalSubmissionHandoff(target: target) == nil)

            let canonical = try decodeTranscriptFixture(
                TranscriptItem.self,
                from: Data(#"{"id":"canonical-queued-text","parentId":null,"timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"user","presentationId":"canonical-queued-text","content":[{"id":"text","ordinal":0,"type":"text","text":"queued text"}]}"#.utf8)
            )
            harness.coordinator.reconcileSubmission(
                target: target, canonicalTranscript: [canonical], queuedMessages: []
            )
            let receipt = try #require(
                harness.coordinator.consumeCanonicalSubmissionHandoff(target: target)
            )
            #expect(receipt.canonicalID == "canonical-queued-text")
            #expect(receipt.operationID == queued.id)
            #expect(receipt.attachments.isEmpty)
        }
    }

    @Test("a confirmed local queue mutation invalidates only its exact settlement owner")
    func localQueueMutationInvalidatesExactHandoff() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 56)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "locally removed"
            )
            let sending = Task { try await harness.coordinator.send(target: target, behavior: "steer") }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)
            let queued = SessionSnapshot.QueuedMessage(
                id: "operation-0", behavior: .steer, text: "locally removed", attachmentCount: 0
            )
            harness.coordinator.reconcileSubmission(
                target: target, canonicalTranscript: [], queuedMessages: [queued]
            )
            harness.coordinator.invalidateSettledQueueHandoff(
                target: target,
                affectedOperationIDs: [queued.id]
            )
            harness.coordinator.reconcileSubmission(
                target: target, canonicalTranscript: [], queuedMessages: []
            )
            let laterCanonical = try decodeTranscriptFixture(
                TranscriptItem.self,
                from: Data(#"{"id":"later-unrelated","parentId":null,"timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"user","presentationId":"later-unrelated","content":[{"id":"text","ordinal":0,"type":"text","text":"locally removed"}]}"#.utf8)
            )
            harness.coordinator.reconcileSubmission(
                target: target, canonicalTranscript: [laterCanonical], queuedMessages: []
            )
            #expect(harness.coordinator.consumeCanonicalSubmissionHandoff(target: target) == nil)
        }
    }

    @Test("confirmed queue mutation retires a receipt prepared before command success")
    func localQueueMutationInvalidatesPreparedReceipt() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 57)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "simultaneous canonical"
            )
            let sending = Task { try await harness.coordinator.send(target: target, behavior: "steer") }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)
            let queued = SessionSnapshot.QueuedMessage(
                id: "operation-0", behavior: .steer, text: "simultaneous canonical", attachmentCount: 0
            )
            harness.coordinator.reconcileSubmission(
                target: target, canonicalTranscript: [], queuedMessages: [queued]
            )
            let canonical = try decodeTranscriptFixture(
                TranscriptItem.self,
                from: Data(#"{"id":"canonical-before-success","parentId":null,"timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"user","presentationId":"canonical-before-success","content":[{"id":"text","ordinal":0,"type":"text","text":"simultaneous canonical"}]}"#.utf8)
            )
            harness.coordinator.reconcileSubmission(
                target: target, canonicalTranscript: [canonical], queuedMessages: []
            )
            #expect(harness.coordinator.canonicalSubmissionHandoff(target: target)?.operationID == queued.id)

            harness.coordinator.invalidateSettledQueueHandoff(
                target: target,
                affectedOperationIDs: [queued.id]
            )
            #expect(harness.coordinator.canonicalSubmissionHandoff(target: target) == nil)
        }
    }

    @Test("ambiguous canonical matches retain the outgoing admission and no receipt")
    func ambiguousCanonicalMatchesRemainUnsettled() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 49)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "repeat"
            )
            let sending = Task { try await harness.coordinator.send(target: target, behavior: nil) }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)
            let canonicalOne = try decodeTranscriptFixture(
                TranscriptItem.self,
                from: Data("{\"id\":\"canonical-repeat-a\",\"parentId\":null,\"timestamp\":\"2026-01-01T00:00:01Z\",\"kind\":\"message\",\"role\":\"user\",\"content\":[{\"id\":\"text\",\"ordinal\":0,\"type\":\"text\",\"text\":\"repeat\"}]}".utf8)
            )
            let canonicalTwo = try decodeTranscriptFixture(
                TranscriptItem.self,
                from: Data("{\"id\":\"canonical-repeat-b\",\"parentId\":null,\"timestamp\":\"2026-01-01T00:00:02Z\",\"kind\":\"message\",\"role\":\"user\",\"content\":[{\"id\":\"text\",\"ordinal\":0,\"type\":\"text\",\"text\":\"repeat\"}]}".utf8)
            )
            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [canonicalOne, canonicalTwo]
            )
            #expect(harness.coordinator.outgoingSubmission(for: target) != nil)
            #expect(harness.coordinator.consumeCanonicalSubmissionHandoff(target: target) == nil)
        }
    }

    @Test("an exact canonical handoff survives later ambiguity until transport accepts")
    func exactCanonicalHandoffSurvivesLaterAmbiguity() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 54)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "repeat"
            )
            let sending = Task { try await harness.coordinator.send(target: target, behavior: nil) }
            try await harness.waitForSends(1)
            let canonicalOne = try decodeTranscriptFixture(
                TranscriptItem.self,
                from: Data(#"{"id":"canonical-exact","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"user","presentationId":"canonical-exact","content":[{"id":"text","ordinal":0,"type":"text","text":"repeat"}]}"#.utf8)
            )
            let canonicalTwo = try decodeTranscriptFixture(
                TranscriptItem.self,
                from: Data(#"{"id":"canonical-later","parentId":null,"timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"user","presentationId":"canonical-later","content":[{"id":"text","ordinal":0,"type":"text","text":"repeat"}]}"#.utf8)
            )
            harness.coordinator.reconcileSubmission(
                target: target, canonicalTranscript: [canonicalOne]
            )
            harness.coordinator.reconcileSubmission(
                target: target, canonicalTranscript: [canonicalOne, canonicalTwo]
            )
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)

            let receipt = try #require(
                harness.coordinator.consumeCanonicalSubmissionHandoff(target: target)
            )
            #expect(receipt.canonicalID == "canonical-exact")
        }
    }

    @Test("text-only submissions reject same-text canonical rows with attachments")
    func textOnlySubmissionRejectsCanonicalAttachments() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 55)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "same"
            )
            let sending = Task { try await harness.coordinator.send(target: target, behavior: nil) }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)
            let canonical = TranscriptItem.message(MessageTranscriptItem(
                id: "canonical-with-photo", parentId: nil, timestamp: "2026-01-01T00:00:01Z",
                kind: .message, role: .user, presentationId: "canonical-with-photo",
                content: [
                    ContentPart(id: "text", ordinal: 0, thinkingRunOrdinal: nil, type: .text, text: "same", attachment: nil, redacted: nil, mimeType: nil, blobId: nil, toolCallId: nil, name: nil, arguments: nil),
                    ContentPart(id: "image", ordinal: 1, thinkingRunOrdinal: nil, type: .image, text: nil, attachment: nil, redacted: nil, mimeType: "image/jpeg", blobId: "unrelated", toolCallId: nil, name: nil, arguments: nil),
                ],
                provider: nil, modelId: nil, stopReason: nil, errorMessage: nil,
                toolCallId: nil, toolName: nil, isError: nil, details: nil, usage: nil,
                startedAt: nil, completedAt: nil, durationMs: nil,
                lastProgressAt: nil, progressSequence: nil
            ))
            harness.coordinator.reconcileSubmission(target: target, canonicalTranscript: [canonical])

            #expect(harness.coordinator.outgoingSubmission(for: target) != nil)
            #expect(harness.coordinator.consumeCanonicalSubmissionHandoff(target: target) == nil)
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
                kind: .message, role: .user, presentationId: "operation-0",
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
                kind: .message, role: .user, presentationId: "operation-0",
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

    @Test("definitive failure after presentation retirement restores the scoped draft")
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
            await #expect(throws: ComposerSyntheticError.self) {
                try await valueOfOwnedTask(sending)
            }
            #expect(harness.coordinator.text(for: scope) == "outgoing")
        }
    }

    @Test("sequenced failure retires only its exact accepted operation and restores the draft once")
    func acceptedOperationFailure() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "session", generation: 60)
            let scope = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: target, lifecycleGeneration: 1,
                initialText: "outgoing"
            )
            let sending = Task { try await harness.coordinator.send(target: target, behavior: "steer") }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(sending)

            #expect(harness.coordinator.failOperation("other-operation", target: target) == false)
            #expect(harness.coordinator.outgoingSubmission(for: target) != nil)
            #expect(harness.coordinator.failOperation("operation-0", target: target))
            #expect(harness.coordinator.outgoingSubmission(for: target) == nil)
            #expect(harness.coordinator.text(for: scope) == "outgoing")
            #expect(harness.coordinator.failOperation("operation-0", target: target) == false)
            #expect(harness.coordinator.text(for: scope) == "outgoing")
        }
    }

    @Test("accepted submission survives remount until exact canonical settlement")
    func acceptedSendSurvivesPresentationRevocation() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let first = SessionPresentationIdentity(sessionID: "session", generation: 61)
            let scope = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: first, lifecycleGeneration: 1,
                initialText: "first"
            )
            let firstSend = Task {
                try await harness.coordinator.send(target: first, behavior: nil)
            }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(firstSend)
            let presentationID = try #require(
                harness.coordinator.outgoingSubmission(for: first)?.presentationID
            )

            harness.coordinator.revoke(first)
            let second = SessionPresentationIdentity(sessionID: "session", generation: 62)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile", target: second, lifecycleGeneration: 1
            )
            #expect(harness.coordinator.outgoingSubmission(for: second)?.presentationID == presentationID)
            #expect(harness.sendCalls.count == 1)

            harness.coordinator.setText("second", for: scope)
            #expect(throws: GatewayFailure.self) {
                try harness.coordinator.beginSubmission(target: second, behavior: nil)
            }
            harness.coordinator.reconcileSubmission(
                target: second,
                canonicalTranscript: [canonicalUser(
                    id: "canonical-first",
                    presentationID: "operation-0",
                    text: "first"
                )]
            )
            #expect(harness.coordinator.outgoingSubmission(for: second) == nil)
            let receipt = try #require(
                harness.coordinator.consumeCanonicalSubmissionHandoff(target: second)
            )
            #expect(receipt.submission?.presentationID == presentationID)
            #expect(receipt.operationID == "operation-0")
            #expect(harness.sendCalls.count == 1)
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

    @Test("derived submission lifecycle stages, transports, and canonically reconciles")
    func derivedSubmissionLifecycle() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "lifecycle", generation: 70)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile",
                target: target,
                lifecycleGeneration: 1,
                initialText: "hello"
            )
            let submission = try harness.coordinator.beginSubmission(target: target, behavior: nil)
            #expect(harness.coordinator.submissionLifecycle(for: target).phase == .staged)
            #expect(harness.coordinator.submissionLifecycle(for: target).id == submission.presentationID)

            let transport = Task { try await harness.coordinator.transmitSubmission(submission) }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(transport)
            #expect(harness.coordinator.submissionLifecycle(for: target).phase == .transported)

            harness.coordinator.reconcileSubmission(
                target: target,
                canonicalTranscript: [canonicalUser(id: "canonical", presentationID: "operation-0", text: "hello")]
            )
            #expect(harness.coordinator.submissionLifecycle(for: target).phase == .canonical("canonical"))
            #expect(harness.coordinator.consumeCanonicalSubmissionHandoff(target: target) != nil)
            #expect(harness.coordinator.submissionLifecycle(for: target) == .idle)
        }
    }

    @Test("identical sends have distinct lifecycle identities")
    func identicalSubmissionIdentity() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "identity", generation: 71)
            let scope = harness.coordinator.installHostedPresentation(
                profileID: "profile",
                target: target,
                lifecycleGeneration: 1,
                initialText: "same"
            )
            let first = try harness.coordinator.beginSubmission(target: target, behavior: nil)
            let failed = Task { try await harness.coordinator.transmitSubmission(first) }
            try await harness.waitForSends(1)
            harness.completeSend(index: 0, result: .failure(ComposerSyntheticError.current))
            await #expect(throws: ComposerSyntheticError.self) {
                try await valueOfOwnedTask(failed)
            }
            harness.coordinator.setText("same", for: scope)
            let second = try harness.coordinator.beginSubmission(target: target, behavior: nil)
            #expect(first.presentationID != second.presentationID)
        }
    }

    @Test("sending submission survives remount and transports exactly once")
    func lifecycleRevocation() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "revoked", generation: 72)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile",
                target: target,
                lifecycleGeneration: 1,
                initialText: "message"
            )
            let submission = try harness.coordinator.beginSubmission(target: target, behavior: nil)
            let transport = Task { try await harness.coordinator.transmitSubmission(submission) }
            try await harness.waitForSends(1)
            harness.coordinator.revoke(target)

            let remounted = SessionPresentationIdentity(sessionID: "revoked", generation: 73)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile",
                target: remounted,
                lifecycleGeneration: 1
            )
            #expect(harness.coordinator.isSending(target: remounted))
            #expect(harness.coordinator.outgoingSubmission(for: remounted)?.presentationID == submission.presentationID)
            #expect(harness.sendCalls.count == 1)

            harness.completeSend(index: 0, result: .success(()))
            try await valueOfOwnedTask(transport)
            #expect(harness.coordinator.submissionLifecycle(for: remounted).phase == .transported)
            #expect(harness.sendCalls.count == 1)
        }
    }

    @Test("lifecycle replacement prevents admitted transport from entering a new Gateway")
    func lifecycleReplacementStopsTransportBeforeSend() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let target = SessionPresentationIdentity(sessionID: "replaced-lifecycle", generation: 74)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile-a",
                target: target,
                lifecycleGeneration: 1,
                initialText: "must stay on profile a"
            )
            let submission = try harness.coordinator.beginSubmission(target: target, behavior: nil)

            harness.admission.generation = 2
            await #expect(throws: CancellationError.self) {
                try await harness.coordinator.transmitSubmission(submission)
            }
            #expect(harness.sendCalls.isEmpty)
        }
    }

    @Test("definitive failure after revocation restores draft and attachments on reopen")
    func revokedDefinitiveFailureRestoresOnReopen() async throws {
        try await withTestWatchdog { @MainActor in
            let harness = ComposerHarness()
            let oldTarget = SessionPresentationIdentity(sessionID: "revoked-failure", generation: 80)
            let scope = harness.coordinator.installHostedPresentation(
                profileID: "profile",
                target: oldTarget,
                lifecycleGeneration: 1,
                initialText: "recover me"
            )
            harness.coordinator.installHostedAttachment(
                .init(
                    id: "upload",
                    gatewayUploadID: "stale-old-upload",
                    name: "file.txt",
                    mimeType: "text/plain",
                    size: 4,
                    previewData: nil
                ),
                target: oldTarget
            )
            let submission = try harness.coordinator.beginSubmission(target: oldTarget, behavior: nil)
            let transport = Task { try await harness.coordinator.transmitSubmission(submission) }
            try await harness.waitForSends(1)
            harness.coordinator.revoke(oldTarget)
            let newTarget = SessionPresentationIdentity(sessionID: oldTarget.sessionID, generation: 81)
            _ = harness.coordinator.installHostedPresentation(
                profileID: "profile",
                target: newTarget,
                lifecycleGeneration: 1
            )
            // Model the remount's fresh upload representation for the same
            // stable chip before the old transport reports a definitive error.
            harness.coordinator.removeAttachment("upload", target: newTarget)
            harness.coordinator.installHostedAttachment(
                .init(
                    id: "upload",
                    gatewayUploadID: "fresh-remount-upload",
                    name: "file.txt",
                    mimeType: "text/plain",
                    size: 4,
                    previewData: nil
                ),
                target: newTarget
            )

            harness.completeSend(index: 0, result: .failure(ComposerSyntheticError.current))
            await #expect(throws: ComposerSyntheticError.self) {
                try await valueOfOwnedTask(transport)
            }
            #expect(harness.coordinator.text(for: scope) == "recover me")
            #expect(harness.coordinator.pendingAttachments(for: newTarget).map(\.id) == ["upload"])
            #expect(harness.coordinator.pendingAttachments(for: newTarget).first?.gatewayUploadID
                == "fresh-remount-upload")
            #expect(harness.coordinator.outgoingSubmission(for: newTarget) == nil)

            let retry = Task { try await harness.coordinator.send(target: newTarget, behavior: nil) }
            try await harness.waitForSends(2)
            #expect(harness.sendCalls[1].uploadIDs == ["fresh-remount-upload"])
            harness.completeSend(index: 1, result: .success(()))
            try await valueOfOwnedTask(retry)

            let missing = ComposerHarness()
            let missingOld = SessionPresentationIdentity(sessionID: "missing-copy", generation: 1)
            _ = missing.coordinator.installHostedPresentation(
                profileID: "profile",
                target: missingOld,
                lifecycleGeneration: 1,
                initialText: "retry attachment"
            )
            missing.coordinator.installHostedAttachment(
                .init(
                    id: "stable-chip",
                    gatewayUploadID: "stale-presentation-upload",
                    name: "missing.txt",
                    mimeType: "text/plain",
                    size: 1,
                    previewData: nil
                ),
                target: missingOld
            )
            let missingSubmission = try missing.coordinator.beginSubmission(
                target: missingOld,
                behavior: nil
            )
            let missingTransport = Task {
                try await missing.coordinator.transmitSubmission(missingSubmission)
            }
            try await missing.waitForSends(1)
            missing.coordinator.revoke(missingOld)
            let missingNew = SessionPresentationIdentity(sessionID: "missing-copy", generation: 2)
            _ = missing.coordinator.installHostedPresentation(
                profileID: "profile",
                target: missingNew,
                lifecycleGeneration: 1
            )
            missing.coordinator.removeAttachment("stable-chip", target: missingNew)
            missing.completeSend(index: 0, result: .failure(ComposerSyntheticError.current))
            await #expect(throws: ComposerSyntheticError.self) {
                try await valueOfOwnedTask(missingTransport)
            }
            #expect(missing.coordinator.pendingAttachments(for: missingNew).first?.id
                == "stable-chip")
            #expect(missing.coordinator.pendingAttachments(for: missingNew).first?.gatewayUploadID
                == nil)
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

    private func canonicalUser(
        id: String,
        presentationID: String? = nil,
        text: String
    ) -> TranscriptItem {
        .message(MessageTranscriptItem(
            id: id,
            parentId: nil,
            timestamp: "2026-01-01T00:00:00Z",
            kind: .message,
            role: .user,
            presentationId: presentationID ?? id,
            content: [ContentPart(
                id: "text",
                ordinal: 0,
                thinkingRunOrdinal: nil,
                type: .text,
                text: text,
                attachment: nil,
                redacted: nil,
                mimeType: nil,
                blobId: nil,
                toolCallId: nil,
                name: nil,
                arguments: nil
            )],
            provider: nil,
            modelId: nil,
            stopReason: nil,
            errorMessage: nil,
            toolCallId: nil,
            toolName: nil,
            isError: nil,
            details: nil,
            usage: nil,
            startedAt: nil,
            completedAt: nil,
            durationMs: nil,
            lastProgressAt: nil,
            progressSequence: nil
        ))
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
    let skillName: String?

    init(text: String, sessionID: String, uploadIDs: [String], behavior: String?, skillName: String? = nil) {
        self.text = text
        self.sessionID = sessionID
        self.uploadIDs = uploadIDs
        self.behavior = behavior
        self.skillName = skillName
    }
}

private actor ComposerPreviewPreparationGate {
    private var isBlocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func prepare(
        data: Data,
        mimeType: String,
        name: String
    ) async -> ComposerPreparedAttachmentThumbnail? {
        _ = data
        _ = mimeType
        _ = name
        isBlocked = true
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        await withCheckedContinuation { releaseWaiters.append($0) }
        return nil
    }

    func waitUntilBlocked() async {
        if isBlocked { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
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
        send: { [weak self] text, sessionID, uploadIDs, behavior, skillName in
            guard let self else { throw CancellationError() }
            let index = self.sendCalls.count
            self.sendCalls.append(.init(
                text: text, sessionID: sessionID, uploadIDs: uploadIDs, behavior: behavior,
                skillName: skillName
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
