import SwiftUI

/// Renders system events (notifications) in the chat
/// Consolidates rendering for all SystemEvent cases
@available(iOS 26.0, *)
struct SystemEventView: View {
    let event: SystemEvent
    var onCompactionTap: ((Int, Int, String, String?) -> Void)?
    var onMemoryUpdatedTap: ((String, String, String?) -> Void)?
    var onSubagentResultTap: ((String) -> Void)?
    var onProviderErrorTap: ((ProviderErrorDetailData) -> Void)?

    var body: some View {
        // Memory updating/updated share a single view for smooth in-place animation
        if event.isMemoryNotification {
            memoryNotificationView
        } else {
            nonMemoryEventView
        }
    }

    @ViewBuilder
    private var memoryNotificationView: some View {
        let isInProgress = event.memoryIsInProgress
        let title = event.memoryTitle
        let entryType = event.memoryEntryType
        let eventId = event.memoryEventId
        MemoryNotificationView(
            isInProgress: isInProgress,
            title: title,
            entryType: entryType,
            onTap: isInProgress ? nil : {
                onMemoryUpdatedTap?(title, entryType, eventId)
            }
        )
    }

    @ViewBuilder
    private var nonMemoryEventView: some View {
        switch event {
        case .modelChange(let from, let to):
            ModelChangeNotificationView(from: from, to: to)

        case .reasoningLevelChange(let from, let to):
            ReasoningLevelChangeNotificationView(from: from, to: to)

        case .interrupted:
            InterruptedNotificationView()

        case .transcriptionFailed:
            TranscriptionFailedNotificationView()

        case .transcriptionNoSpeech:
            TranscriptionNoSpeechNotificationView()

        case .compactionInProgress:
            CompactionInProgressNotificationView()

        case .compaction(let tokensBefore, let tokensAfter, let reason, let summary):
            CompactionNotificationView(
                tokensBefore: tokensBefore,
                tokensAfter: tokensAfter,
                reason: reason,
                onTap: {
                    onCompactionTap?(tokensBefore, tokensAfter, reason, summary)
                }
            )

        case .contextCleared(let tokensBefore, let tokensAfter):
            ContextClearedNotificationView(tokensBefore: tokensBefore, tokensAfter: tokensAfter)

        case .messageDeleted(let targetType):
            MessageDeletedNotificationView(targetType: targetType)

        case .skillRemoved(let skillName):
            SkillRemovedNotificationView(skillName: skillName)

        case .rulesLoaded(let count):
            RulesLoadedNotificationView(count: count)

        case .rulesActivated(let rules, let total):
            RulesActivatedNotificationView(rules: rules, totalActivated: total)

        case .catchingUp:
            CatchingUpNotificationView()

        case .turnFailed(let error, let code, let recoverable):
            TurnFailedNotificationView(error: error, code: code, recoverable: recoverable)

        case .subagentResultAvailable(let subagentSessionId, let taskPreview, let success):
            SubagentResultNotificationView(
                subagentSessionId: subagentSessionId,
                taskPreview: taskPreview,
                success: success,
                onTap: {
                    onSubagentResultTap?(subagentSessionId)
                }
            )

        case .memoriesLoaded(let count):
            MemoriesLoadedNotificationView(count: count)

        case .providerError(let data):
            ProviderErrorNotificationView(
                data: data,
                onTap: {
                    onProviderErrorTap?(data)
                }
            )

        default:
            EmptyView()
        }
    }
}
