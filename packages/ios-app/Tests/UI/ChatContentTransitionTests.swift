import Foundation
import Testing
@testable import TronMobile

@Suite("Chat content entrance motion")
struct ChatContentTransitionTests {
    @Test("rendered roles select spatially consistent entrances")
    func entranceClassification() throws {
        let user = try transcriptItem(role: "user", id: "user")
        let assistant = try transcriptItem(role: "assistant", id: "assistant")
        let notification = ChatNotificationPresentation(
            id: "status",
            semanticID: nil,
            icon: "checkmark",
            title: "Ready",
            detail: nil,
            body: nil,
            tone: .accent,
            material: .flat
        )

        #expect(ChatContentEntranceKind.classify(.transcript(user)) == .userPrompt)
        #expect(ChatContentEntranceKind.classify(.transcript(assistant)) == .assistantContent)
        #expect(ChatContentEntranceKind.classify(.notification(notification)) == .centeredActivity)
    }

    @Test("prompt lifecycle selects kind before first frame and aliases without replay")
    func promptLifecycleSelection() {
        #expect(ChatPromptLifecycleTransitionPolicy.entranceKind(for: .ordinary) == .userPrompt)
        #expect(ChatPromptLifecycleTransitionPolicy.entranceKind(for: .unknown) == .userPrompt)
        #expect(ChatPromptLifecycleTransitionPolicy.entranceKind(for: .steer) == .queuedPrompt)
        #expect(ChatPromptLifecycleTransitionPolicy.entranceKind(for: .followUp) == .queuedPrompt)
        #expect(ChatPromptLifecycleTransitionPolicy.shouldAnimateQueueEntrance(
            isReady: true, entranceSuppressed: false, hasIdentityAlias: false
        ))
        #expect(ChatPromptLifecycleTransitionPolicy.shouldAnimateUserEntrance(
            isReady: true, entranceSuppressed: false
        ))
        #expect(!ChatPromptLifecycleTransitionPolicy.shouldAnimateUserEntrance(
            isReady: true, entranceSuppressed: true
        ))
        #expect(ChatPromptLifecycleTransitionPolicy.suppressesQueueReplacement(
            pendingOperationID: "operation-3",
            authoritativeQueueIDs: ["operation-3", "other"]
        ))
        #expect(!ChatPromptLifecycleTransitionPolicy.suppressesQueueReplacement(
            pendingOperationID: "operation-3",
            authoritativeQueueIDs: ["other"]
        ))
        #expect(!ChatPromptLifecycleTransitionPolicy.shouldAnimateQueueEntrance(
            isReady: true, entranceSuppressed: false, hasIdentityAlias: true
        ))
        #expect(!ChatPromptLifecycleTransitionPolicy.shouldAnimateQueueEntrance(
            isReady: false, entranceSuppressed: false, hasIdentityAlias: false
        ))
    }

    @Test("settled lifecycle destinations remain plain after crossfade retirement")
    func settledLifecycleDestinationLedger() {
        var ledger = BoundedChatIdentityLedger()
        ledger.formUnion(["canonical-message"])
        #expect(ledger.contains("canonical-message"))
        ledger.formUnion(["canonical-message"])
        #expect(ledger.contains("canonical-message"))
        ledger.removeAll()
        #expect(!ledger.contains("canonical-message"))
    }

    @Test("crossfade finalization is idempotent across completion and disappearance")
    func crossfadeFinalizationPolicy() {
        #expect(ChatPromptLifecycleTransitionPolicy.shouldFinalizeCrossfade(hasFinalized: false))
        #expect(!ChatPromptLifecycleTransitionPolicy.shouldFinalizeCrossfade(hasFinalized: true))
    }

    @Test("transition-cap eviction retires oldest IDs in insertion order")
    func transitionCapEviction() {
        #expect(ChatPromptLifecycleTransitionPolicy.transitionIDsToRetire(
            in: ["first", "second", "third", "fourth", "fifth"], maximum: 4
        ) == ["first"])
        #expect(ChatPromptLifecycleTransitionPolicy.transitionIDsToRetire(
            in: ["first", "second"], maximum: 4
        ).isEmpty)
    }

    @Test("replacement crossfade keeps Reduce Motion opacity-only and hides destination first")
    func replacementMotionPolicy() {
        #expect(ChatPromptLifecycleTransitionPolicy.replacementScale(
            reduceMotion: true, destinationVisible: false
        ) == 1)
        #expect(ChatPromptLifecycleTransitionPolicy.replacementDestinationScale(
            reduceMotion: true, destinationVisible: false
        ) == 1)
        #expect(ChatPromptLifecycleTransitionPolicy.replacementScale(
            reduceMotion: false, destinationVisible: true
        ) < 1)
        #expect(ChatPromptLifecycleTransitionPolicy.replacementDestinationScale(
            reduceMotion: false, destinationVisible: false
        ) < 1)
    }

    @Test("user and queue content rises from the trailing composer edge")
    func composerEdgeMotion() {
        let user = ChatContentTransitionPolicy.hiddenTransform(
            for: .userPrompt,
            reduceMotion: false
        )
        let queued = ChatContentTransitionPolicy.hiddenTransform(
            for: .queuedPrompt,
            reduceMotion: false
        )

        #expect(user.anchor == .trailing)
        #expect(user.offsetX > 0)
        #expect(user.offsetY > 0)
        #expect(user.scale < 1)
        #expect(queued.anchor == .trailing)
        #expect(queued.offsetY >= user.offsetY)
    }

    @Test("activity remains role-aligned rather than flying across the transcript")
    func activityMotion() {
        let leading = ChatContentTransitionPolicy.hiddenTransform(
            for: .leadingActivity,
            reduceMotion: false
        )
        let centered = ChatContentTransitionPolicy.hiddenTransform(
            for: .centeredActivity,
            reduceMotion: false
        )

        #expect(leading.anchor == .leading)
        #expect(leading.offsetX < 0)
        #expect(centered.anchor == .center)
        #expect(centered.offsetX == 0)
    }

    @Test("Reduce Motion removes every spatial entrance component")
    func reduceMotion() {
        let kinds: [ChatContentEntranceKind] = [
            .userPrompt, .assistantContent, .leadingActivity, .centeredActivity, .queuedPrompt,
        ]
        for kind in kinds {
            #expect(ChatContentTransitionPolicy.hiddenTransform(
                for: kind,
                reduceMotion: true
            ) == .identity)
        }
    }

    private func transcriptItem(role: String, id: String) throws -> TranscriptItem {
        let data = Data(#"{"id":"\#(id)","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"\#(role)","content":[{"id":"\#(id):0","type":"text","text":"hello"}]}"#.utf8)
        return try decodeTranscriptFixture(TranscriptItem.self, from: data)
    }
}
