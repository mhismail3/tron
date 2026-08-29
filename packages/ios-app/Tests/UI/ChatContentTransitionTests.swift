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

    @Test("new transcript rows grow continuously without clipping settled effects")
    func transcriptEntranceGrowth() {
        #expect(ChatEntranceGrowthPolicy.height(natural: 120, progress: -1) == 0)
        #expect(ChatEntranceGrowthPolicy.height(natural: 120, progress: 0.5) == 60)
        #expect(ChatEntranceGrowthPolicy.height(natural: 120, progress: 2) == 120)
        #expect(ChatEntranceGrowthPolicy.height(natural: .infinity, progress: 1) == 0)
        #expect(ChatEntranceGrowthPolicy.height(natural: 120, progress: .nan) == 0)
        #expect(ChatEntranceGrowthPolicy.requiresClip(progress: 0))
        #expect(ChatEntranceGrowthPolicy.requiresClip(progress: 0.999))
        #expect(!ChatEntranceGrowthPolicy.requiresClip(progress: 1))
        #expect(!ChatEntranceGrowthPolicy.requiresClip(progress: 2))

        let overflow = ChatEntranceGrowthPolicy.effectOverflow
        let hiddenBounds = CGRect(x: 0, y: 0, width: 200, height: overflow * 2)
        let settledBounds = CGRect(x: 0, y: 0, width: 200, height: 168)
        let hiddenClip = ChatEntranceGrowthPolicy.clipRect(in: hiddenBounds, progress: 0)
        let settledClip = ChatEntranceGrowthPolicy.clipRect(in: settledBounds, progress: 1)

        #expect(overflow >= 16)
        #expect(hiddenClip.width == hiddenBounds.width)
        #expect(hiddenClip.height == 0)
        #expect(settledClip == settledBounds)
        #expect(ChatEntranceGrowthPolicy.clipRect(
            in: settledBounds,
            progress: .infinity
        ).height == settledBounds.height - overflow * 2)
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
        #expect(user.scale == 0.98)
        #expect(user.offsetX == 4)
        #expect(user.offsetY == 10)
        #expect(queued.anchor == .trailing)
        #expect(queued.scale == 0.978)
        #expect(queued.offsetY == 12)
        #expect(ChatContentTransitionPolicy.transcriptEntranceDuration == 0.18)
        #expect(ChatContentTransitionPolicy.promptEntranceDuration == 0.18)
        #expect(ChatContentTransitionPolicy.promptFlightDuration == 0.18)
        #expect(ChatContentTransitionPolicy.promptReplacementDuration == 0.14)
        #expect(ChatContentTransitionPolicy.notificationReplacementDuration == 0.16)
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

    @Test("composer accessories animate through one structural owner")
    func composerChildMotion() {
        #expect(ChatContentTransitionPolicy.attachmentAnimation(reduceMotion: false)
            != ChatContentTransitionPolicy.attachmentAnimation(reduceMotion: true))
        #expect(ChatContentTransitionPolicy.composerSurfaceAnimation(reduceMotion: false)
            != ChatContentTransitionPolicy.composerSurfaceAnimation(reduceMotion: true))
        #expect(ChatContentTransitionPolicy.composerSurfaceRemovalEdge == .bottom)
        #expect(ChatContentTransitionPolicy.promptFlightAnimation(reduceMotion: false) != nil)
        #expect(ChatContentTransitionPolicy.promptFlightAnimation(reduceMotion: true) == nil)
        #expect(ChatContentTransitionPolicy.notificationReplacementAnimation(reduceMotion: false) != nil)
        #expect(ChatComposerStructuralTransitionPolicy.admitsHeightChange(
            current: 44,
            measured: 88
        ))
        #expect(!ChatComposerStructuralTransitionPolicy.admitsHeightChange(
            current: 44,
            measured: 44.2
        ))
        #expect(!ChatComposerStructuralTransitionPolicy.admitsHeightChange(
            current: 44,
            measured: .infinity
        ))

        let empty = ChatComposerAccessoryLayoutIdentity(
            attachmentIDs: [],
            selectedResourceID: nil,
            resourcePickerKind: nil,
            resourceResultIDs: []
        )
        let attachment = ChatComposerAccessoryLayoutIdentity(
            attachmentIDs: ["photo"],
            selectedResourceID: nil,
            resourcePickerKind: nil,
            resourceResultIDs: []
        )
        #expect(ChatComposerStructuralTransitionPolicy.animatesAccessoryHeight(
            current: 44,
            installedIdentity: empty,
            identity: attachment,
            reduceMotion: false
        ))
        #expect(!ChatComposerStructuralTransitionPolicy.animatesAccessoryHeight(
            current: 44,
            installedIdentity: attachment,
            identity: attachment,
            reduceMotion: false
        ))
        #expect(!ChatComposerStructuralTransitionPolicy.animatesAccessoryHeight(
            current: nil,
            installedIdentity: empty,
            identity: attachment,
            reduceMotion: false
        ))
        #expect(!ChatComposerStructuralTransitionPolicy.animatesAccessoryHeight(
            current: 44,
            installedIdentity: empty,
            identity: attachment,
            reduceMotion: true
        ))
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
