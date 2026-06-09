import Foundation
import UIKit

/// Coordinates primitive capability invocation events for ChatViewModel.
@MainActor
final class CapabilityInvocationCoordinator {

    init() {}

    func handleCapabilityInvocationGenerating(
        _ pluginResult: CapabilityInvocationGeneratingPlugin.Result,
        context: CapabilityInvocationContext
    ) {
        let eventTimestamp = pluginResult.timestamp ?? Date()
        context.finalizeThinkingMessageIfNeeded()

        if MessageFinder.hasCapabilityInvocationMessage(invocationId: pluginResult.invocationId, in: context.messages) {
            return
        }

        context.flushPendingTextUpdates()
        context.finalizeStreamingMessage()

        let invocation = CapabilityInvocationData(
            id: pluginResult.invocationId,
            status: .generating,
            arguments: "",
            generatedAt: eventTimestamp,
            identity: pluginResult.identity
        )
        let message = ChatMessage(role: .assistant, content: .capabilityInvocation(invocation))

        context.appendToMessages(message)
        context.currentCapabilityInvocationMessages[message.id] = message
        context.runningCapabilityInvocationCount += 1
        context.makeCapabilityInvocationVisible(pluginResult.invocationId)

        let record = CapabilityInvocationRecord(
            invocationId: pluginResult.invocationId,
            modelPrimitiveName: pluginResult.modelPrimitiveName,
            arguments: "",
            identity: pluginResult.identity
        )
        context.currentTurnCapabilityInvocations.append(record)

        let invocationStartedData = UIUpdateQueue.CapabilityInvocationStartData(
            invocationId: pluginResult.invocationId,
            modelPrimitiveName: pluginResult.modelPrimitiveName,
            arguments: "",
            timestamp: eventTimestamp
        )
        context.enqueueCapabilityInvocationStart(invocationStartedData)
    }

    func handleCapabilityInvocationStarted(
        _ pluginResult: CapabilityInvocationStartedPlugin.Result,
        context: CapabilityInvocationContext
    ) {
        let eventTimestamp = pluginResult.timestamp ?? Date()
        let invocation = CapabilityInvocationData(
            id: pluginResult.invocationId,
            status: .running,
            arguments: pluginResult.formattedArguments,
            payloadJSON: pluginResult.arguments,
            startedAt: eventTimestamp,
            identity: pluginResult.identity
        )

        context.logInfo("Capability started: \(pluginResult.modelPrimitiveName) [\(pluginResult.invocationId)]")
        context.logDebug("Capability args: \(pluginResult.formattedArguments.prefix(200))")
        context.finalizeThinkingMessageIfNeeded()

        if let existingIndex = context.messageIndex.index(forCapabilityInvocationId: pluginResult.invocationId)
            ?? MessageFinder.lastIndexOfCapabilityInvocation(id: pluginResult.invocationId, in: context.messages) {
            context.logInfo("Updating existing capability.invocation.started for \(pluginResult.modelPrimitiveName) (invocationId: \(pluginResult.invocationId)) with arguments")
            context.makeCapabilityInvocationVisible(pluginResult.invocationId)

            if case .capabilityInvocation(var existing) = context.messages[existingIndex].content {
                existing.arguments = pluginResult.formattedArguments
                existing.payloadJSON = pluginResult.arguments
                existing.status = .running
                existing.startedAt = existing.startedAt ?? eventTimestamp
                existing.identity = pluginResult.identity
                context.messages[existingIndex].content = .capabilityInvocation(existing)
                context.currentCapabilityInvocationMessages[context.messages[existingIndex].id] = context.messages[existingIndex]
            }

            if let idx = context.currentTurnCapabilityInvocations.firstIndex(where: { $0.invocationId == pluginResult.invocationId }) {
                context.currentTurnCapabilityInvocations[idx].arguments = pluginResult.formattedArguments
            }
            return
        }

        context.flushPendingTextUpdates()
        context.finalizeStreamingMessage()

        let message = ChatMessage(role: .assistant, content: .capabilityInvocation(invocation))
        context.appendToMessages(message)
        context.currentCapabilityInvocationMessages[message.id] = message
        context.runningCapabilityInvocationCount += 1
        context.makeCapabilityInvocationVisible(pluginResult.invocationId)

        let record = CapabilityInvocationRecord(
            invocationId: pluginResult.invocationId,
            modelPrimitiveName: pluginResult.modelPrimitiveName,
            arguments: pluginResult.formattedArguments,
            identity: pluginResult.identity
        )
        context.currentTurnCapabilityInvocations.append(record)

        let invocationStartedData = UIUpdateQueue.CapabilityInvocationStartData(
            invocationId: pluginResult.invocationId,
            modelPrimitiveName: pluginResult.modelPrimitiveName,
            arguments: pluginResult.formattedArguments,
            timestamp: eventTimestamp
        )
        context.enqueueCapabilityInvocationStart(invocationStartedData)
    }

    func handleCapabilityInvocationCompleted(
        _ pluginResult: CapabilityInvocationCompletedPlugin.Result,
        context: CapabilityInvocationContext
    ) {
        let statusLabel = pluginResult.success ? "success" : "error"
        context.logInfo("Capability ended: \(pluginResult.invocationId) status=\(statusLabel) duration=\(pluginResult.duration ?? 0)ms")
        context.logDebug("Capability result: \(pluginResult.displayResult.prefix(300))")

        context.finalizeThinkingMessageIfNeeded()
        context.resetThinkingForNewBlock()

        if let idx = context.currentTurnCapabilityInvocations.firstIndex(where: { $0.invocationId == pluginResult.invocationId }) {
            context.currentTurnCapabilityInvocations[idx].result = pluginResult.displayResult
            context.currentTurnCapabilityInvocations[idx].isError = !pluginResult.success
        }

        let invocationCompletedData = UIUpdateQueue.CapabilityInvocationEndData(
            invocationId: pluginResult.invocationId,
            success: pluginResult.success,
            result: pluginResult.displayResult,
            durationMs: pluginResult.duration,
            timestamp: pluginResult.timestamp ?? Date(),
            details: pluginResult.rawDetails,
            failure: pluginResult.failure,
            identity: pluginResult.identity
        )
        context.enqueueCapabilityInvocationEnd(invocationCompletedData)
    }
}
