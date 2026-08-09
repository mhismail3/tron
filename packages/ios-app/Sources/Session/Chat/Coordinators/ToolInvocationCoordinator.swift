import Foundation
import UIKit

/// Coordinates primitive tool invocation events for ChatViewModel.
@MainActor
final class ToolInvocationCoordinator {

    init() {}

    func handleToolInvocationGenerating(
        _ pluginResult: ToolInvocationGeneratingPlugin.Result,
        context: ToolInvocationContext
    ) {
        if pluginResult.toolName == "request_user_input" {
            return
        }
        let eventTimestamp = pluginResult.timestamp ?? Date()
        context.finalizeThinkingMessageIfNeeded()

        if MessageFinder.hasToolInvocationMessage(invocationId: pluginResult.invocationId, in: context.messages) {
            return
        }

        context.flushPendingTextUpdates()
        context.finalizeStreamingMessage()

        let invocation = ToolInvocationData(
            id: pluginResult.invocationId,
            status: .generating,
            arguments: "",
            generatedAt: eventTimestamp,
            identity: pluginResult.identity
        )
        let message = ChatMessage(role: .assistant, content: .toolInvocation(invocation))

        context.appendToMessages(message)
        context.currentTurnToolMessageIds.insert(message.id)
        context.runningToolInvocationCount += 1
        context.makeToolInvocationVisible(pluginResult.invocationId)

        let invocationStartedData = UIUpdateQueue.ToolInvocationStartData(
            invocationId: pluginResult.invocationId,
            toolName: pluginResult.toolName,
            arguments: "",
            timestamp: eventTimestamp
        )
        context.enqueueToolInvocationStart(invocationStartedData)
    }

    func handleToolInvocationStarted(
        _ pluginResult: ToolInvocationStartedPlugin.Result,
        context: ToolInvocationContext
    ) {
        let eventTimestamp = pluginResult.timestamp ?? Date()
        if pluginResult.toolName == "request_user_input" {
            context.finalizeThinkingMessageIfNeeded()
            context.flushPendingTextUpdates()
            context.finalizeStreamingMessage()
            guard let request = UserInputRequest.decode(
                invocationId: pluginResult.invocationId,
                arguments: pluginResult.arguments
            ) else {
                context.logError("Could not decode request_user_input arguments")
                return
            }
            if context.pendingUserInputRequest?.invocationId != request.invocationId {
                context.userInputAutoPresentationInvocationId = request.invocationId
            }
            if let existingIndex = context.messages.lastIndex(where: {
                if case .userInputRequest(let existing) = $0.content {
                    return existing.invocationId == pluginResult.invocationId
                }
                return false
            }) {
                context.updateMessage(at: existingIndex) { message in
                    message.content = .userInputRequest(request)
                }
                context.pendingUserInputRequest = request
                return
            }
            let message = ChatMessage(
                role: .assistant,
                content: .userInputRequest(request),
                timestamp: eventTimestamp
            )
            context.appendToMessages(message)
            context.pendingUserInputRequest = request
            return
        }
        let invocation = ToolInvocationData(
            id: pluginResult.invocationId,
            status: .running,
            arguments: pluginResult.formattedArguments,
            payloadJSON: pluginResult.arguments,
            startedAt: eventTimestamp,
            identity: pluginResult.identity
        )

        context.logInfo("Tool started: \(pluginResult.toolName) [\(pluginResult.invocationId)]")
        context.logDebug("Tool args: \(pluginResult.formattedArguments.prefix(200))")
        context.finalizeThinkingMessageIfNeeded()

        if let existingIndex = context.messageIndex.index(forToolInvocationId: pluginResult.invocationId)
            ?? MessageFinder.lastIndexOfToolInvocation(id: pluginResult.invocationId, in: context.messages) {
            context.logInfo("Updating existing tool.invocation.started for \(pluginResult.toolName) (invocationId: \(pluginResult.invocationId)) with arguments")
            context.makeToolInvocationVisible(pluginResult.invocationId)

            if case .toolInvocation(var existing) = context.messages[existingIndex].content {
                existing.arguments = pluginResult.formattedArguments
                existing.payloadJSON = pluginResult.arguments
                existing.status = .running
                existing.startedAt = existing.startedAt ?? eventTimestamp
                existing.identity = existing.identity.merging(pluginResult.identity)
                context.updateMessage(at: existingIndex) { message in
                    message.content = .toolInvocation(existing)
                }
                context.currentTurnToolMessageIds.insert(context.messages[existingIndex].id)
            }

            return
        }

        context.flushPendingTextUpdates()
        context.finalizeStreamingMessage()

        let message = ChatMessage(role: .assistant, content: .toolInvocation(invocation))
        context.appendToMessages(message)
        context.currentTurnToolMessageIds.insert(message.id)
        context.runningToolInvocationCount += 1
        context.makeToolInvocationVisible(pluginResult.invocationId)

        let invocationStartedData = UIUpdateQueue.ToolInvocationStartData(
            invocationId: pluginResult.invocationId,
            toolName: pluginResult.toolName,
            arguments: pluginResult.formattedArguments,
            timestamp: eventTimestamp
        )
        context.enqueueToolInvocationStart(invocationStartedData)
    }

    func handleToolInvocationCompleted(
        _ pluginResult: ToolInvocationCompletedPlugin.Result,
        context: ToolInvocationContext
    ) {
        if pluginResult.toolName == "request_user_input" {
            guard let index = context.messages.lastIndex(where: {
                if case .userInputRequest(let request) = $0.content {
                    return request.invocationId == pluginResult.invocationId
                }
                return false
            }), case .userInputRequest(var request) = context.messages[index].content else {
                return
            }
            request.status = pluginResult.success ? .pending : .failed(pluginResult.displayResult)
            context.updateMessage(at: index) { message in
                message.content = .userInputRequest(request)
            }
            context.pendingUserInputRequest = pluginResult.success ? request : nil
            return
        }
        let statusLabel = pluginResult.success ? "success" : "error"
        context.logInfo("Tool ended: \(pluginResult.invocationId) status=\(statusLabel) duration=\(pluginResult.duration ?? 0)ms")
        context.logDebug("Tool result: \(pluginResult.displayResult.prefix(300))")

        context.finalizeThinkingMessageIfNeeded()
        context.resetThinkingForNewBlock()

        let invocationCompletedData = UIUpdateQueue.ToolInvocationEndData(
            invocationId: pluginResult.invocationId,
            success: pluginResult.success,
            result: pluginResult.displayResult,
            durationMs: pluginResult.duration,
            timestamp: pluginResult.timestamp ?? Date(),
            details: pluginResult.rawDetails,
            failure: pluginResult.failure,
            identity: pluginResult.identity
        )
        context.enqueueToolInvocationEnd(invocationCompletedData)
    }
}
