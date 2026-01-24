import SwiftUI

/// Renders system events (notifications) in the chat
/// Consolidates rendering for all SystemEvent cases
struct SystemEventView: View {
    let event: SystemEvent
    var onCompactionTap: ((Int, Int, String, String?) -> Void)?

    var body: some View {
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

        case .planModeEntered(let skillName, let blockedTools):
            if #available(iOS 26.0, *) {
                PlanModeEnteredView(skillName: skillName, blockedTools: blockedTools)
            } else {
                PlanModeEnteredFallbackView(skillName: skillName)
            }

        case .planModeExited(let reason, let planPath):
            if #available(iOS 26.0, *) {
                PlanModeExitedView(reason: reason, planPath: planPath)
            } else {
                PlanModeExitedFallbackView(reason: reason)
            }

        case .catchingUp:
            CatchingUpNotificationView()
        }
    }
}
