import Foundation

/// Coordinates event dispatch by routing plugin events to the appropriate handlers.
/// This extracts the large handlePluginEvent switch statement from ChatViewModel,
/// making event routing testable and reducing ChatViewModel complexity.
@MainActor
final class EventDispatchCoordinator {

    /// Dispatch an event to the appropriate handler on the context.
    /// - Parameters:
    ///   - type: The event type string (e.g., "agent.text_delta")
    ///   - transform: Closure that transforms the event to its Result type
    ///   - context: The context providing handler methods (e.g., ChatViewModel)
    func dispatch(
        type: String,
        transform: @Sendable () -> (any EventResult)?,
        context: EventDispatchContext
    ) {
        guard let result = transform() else {
            context.logWarning("Failed to transform event: \(type)")
            return
        }

        switch type {
        case TextDeltaPlugin.eventType:
            if let r = result as? TextDeltaPlugin.Result {
                context.handleTextDelta(r.delta)
            }

        case ThinkingDeltaPlugin.eventType:
            if let r = result as? ThinkingDeltaPlugin.Result {
                context.handleThinkingDelta(r.delta)
            }

        case ToolStartPlugin.eventType:
            if let r = result as? ToolStartPlugin.Result {
                context.handleToolStart(r)
            }

        case ToolEndPlugin.eventType:
            if let r = result as? ToolEndPlugin.Result {
                context.handleToolEnd(r)
            }

        case TurnStartPlugin.eventType:
            if let r = result as? TurnStartPlugin.Result {
                context.handleTurnStart(r)
            }

        case TurnEndPlugin.eventType:
            if let r = result as? TurnEndPlugin.Result {
                context.handleTurnEnd(r)
            }

        case AgentTurnPlugin.eventType:
            if let r = result as? AgentTurnPlugin.Result {
                context.handleAgentTurn(r)
            }

        case CompletePlugin.eventType:
            context.handleComplete()

        case ErrorPlugin.eventType:
            if let r = result as? ErrorPlugin.Result {
                context.handleAgentError(r.message)
            }

        case CompactionPlugin.eventType:
            if let r = result as? CompactionPlugin.Result {
                context.handleCompaction(r)
            }

        case ContextClearedPlugin.eventType:
            if let r = result as? ContextClearedPlugin.Result {
                context.handleContextCleared(r)
            }

        case MessageDeletedPlugin.eventType:
            if let r = result as? MessageDeletedPlugin.Result {
                context.handleMessageDeleted(r)
            }

        case SkillRemovedPlugin.eventType:
            if let r = result as? SkillRemovedPlugin.Result {
                context.handleSkillRemoved(r)
            }

        case BrowserFramePlugin.eventType:
            if let r = result as? BrowserFramePlugin.Result {
                context.handleBrowserFrame(r)
            }

        case BrowserClosedPlugin.eventType:
            if let r = result as? BrowserClosedPlugin.Result {
                if let sessionId = r.closedSessionId {
                    context.handleBrowserClosed(sessionId)
                }
            }

        case SubagentSpawnedPlugin.eventType:
            if let r = result as? SubagentSpawnedPlugin.Result {
                context.handleSubagentSpawned(r)
            }

        case SubagentStatusPlugin.eventType:
            if let r = result as? SubagentStatusPlugin.Result {
                context.handleSubagentStatus(r)
            }

        case SubagentCompletedPlugin.eventType:
            if let r = result as? SubagentCompletedPlugin.Result {
                context.handleSubagentCompleted(r)
            }

        case SubagentFailedPlugin.eventType:
            if let r = result as? SubagentFailedPlugin.Result {
                context.handleSubagentFailed(r)
            }

        case SubagentEventPlugin.eventType:
            if let r = result as? SubagentEventPlugin.Result {
                context.handleSubagentEvent(r)
            }

        case UIRenderStartPlugin.eventType:
            if let r = result as? UIRenderStartPlugin.Result {
                context.handleUIRenderStart(r)
            }

        case UIRenderChunkPlugin.eventType:
            if let r = result as? UIRenderChunkPlugin.Result {
                context.handleUIRenderChunk(r)
            }

        case UIRenderCompletePlugin.eventType:
            if let r = result as? UIRenderCompletePlugin.Result {
                context.handleUIRenderComplete(r)
            }

        case UIRenderErrorPlugin.eventType:
            if let r = result as? UIRenderErrorPlugin.Result {
                context.handleUIRenderError(r)
            }

        case UIRenderRetryPlugin.eventType:
            if let r = result as? UIRenderRetryPlugin.Result {
                context.handleUIRenderRetry(r)
            }

        case TodosUpdatedPlugin.eventType:
            if let r = result as? TodosUpdatedPlugin.Result {
                context.handleTodosUpdated(r)
            }

        case ConnectedPlugin.eventType:
            // Connection events are handled elsewhere (RPCClient)
            break

        default:
            context.logDebug("Unhandled plugin event type: \(type)")
        }
    }
}
