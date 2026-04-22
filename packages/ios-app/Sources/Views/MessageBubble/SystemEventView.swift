import SwiftUI

/// Renders system events (notifications) in the chat
/// Consolidates rendering for all SystemEvent cases
@available(iOS 26.0, *)
struct SystemEventView: View {
    let event: SystemEvent
    var onTap: ((MessageBubbleTapAction) -> Void)?

    var body: some View {
        if event.isCompactionNotification {
            compactionNotificationView
        } else if event.isMemoryRetainNotification {
            memoryRetainNotificationView
        } else {
            eventView
        }
    }

    @ViewBuilder
    private var compactionNotificationView: some View {
        let isInProgress = event.compactionIsInProgress
        let tokensBefore = event.compactionTokensBefore
        let tokensAfter = event.compactionTokensAfter
        let reason = event.compactionReason
        let summary = event.compactionSummary
        CompactionNotificationView(
            isInProgress: isInProgress,
            tokensBefore: tokensBefore,
            tokensAfter: tokensAfter,
            reason: reason,
            onTap: isInProgress ? nil : {
                onTap?(.compaction(tokensBefore: tokensBefore, tokensAfter: tokensAfter, reason: reason, summary: summary, preservedTurns: event.compactionPreservedTurns, summarizedTurns: event.compactionSummarizedTurns))
            }
        )
    }

    @ViewBuilder
    private var memoryRetainNotificationView: some View {
        let isInProgress = event.memoryRetainIsInProgress
        let isAuto = event.memoryRetainIsAuto
        let title = event.memoryRetainTitle
        let summary = event.memoryRetainSummary
        let failureReason = event.memoryRetainFailureReason
        MemoryRetainedNotificationView(
            isInProgress: isInProgress,
            title: title,
            isAuto: isAuto,
            failureReason: failureReason,
            onTap: isInProgress ? nil : (title != nil ? {
                onTap?(.memoryRetainDetail(title: title!, summary: summary))
            } : nil)
        )
    }

    @ViewBuilder
    private var eventView: some View {
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

        case .contextCleared(let tokensBefore, let tokensAfter):
            ContextClearedNotificationView(tokensBefore: tokensBefore, tokensAfter: tokensAfter)

        case .messageDeleted(let targetType):
            MessageDeletedNotificationView(targetType: targetType)

        case .skillDeactivated(let skillName):
            SkillDeactivatedNotificationView(skillName: skillName)

        case .skillsCleared(let clearedSkills, let mode):
            // M6: `.clearAll` renders an informational banner; `.askUser`
            // renders tappable chips that call `skill.activate` via the
            // `.reactivateSkill` tap action.
            SkillsClearedNotificationView(
                clearedSkills: clearedSkills,
                mode: mode,
                onReactivate: mode == .askUser ? { skillName in
                    onTap?(.reactivateSkill(skillName: skillName))
                } : nil
            )

        case .rulesLoaded(let count):
            RulesLoadedNotificationView(count: count)

        case .rulesActivated(let rules, let total):
            RulesActivatedNotificationView(rules: rules, totalActivated: total)

        case .catchingUp:
            CatchingUpNotificationView()

        case .turnFailed(let error, let code, let recoverable):
            TurnFailedNotificationView(error: error, code: code, recoverable: recoverable)

        case .subagentResultAvailable(let subagentSessionId, let taskPreview, let success):
            // Legacy individual notification (from persisted events before consolidation)
            SubagentResultNotificationView(
                results: [SubagentResultEntry(subagentSessionId: subagentSessionId, taskPreview: taskPreview, success: success)],
                onTap: {
                    onTap?(.subagentResult(sessionId: subagentSessionId))
                }
            )

        case .subagentResultsReady(let results):
            SubagentResultNotificationView(results: results) {
                if results.count == 1 {
                    onTap?(.subagentResult(sessionId: results[0].subagentSessionId))
                } else {
                    onTap?(.subagentResultsReady(results: results))
                }
            }

        case .providerError(let data):
            ProviderErrorNotificationView(
                data: data,
                onTap: {
                    onTap?(.providerError(data))
                }
            )

        default:
            EmptyView()
        }
    }
}
