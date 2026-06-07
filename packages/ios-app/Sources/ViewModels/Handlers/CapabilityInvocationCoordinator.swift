import Foundation
import UIKit

/// Coordinates capability invocation event handling (start/end) for ChatViewModel.
///
/// Responsibilities:
/// - Creating capability invocation messages on capability.invocation.started
/// - Handling special capabilities: UserInteraction
/// - Tracking capability invocations for the current turn
/// - Enqueuing capability invocation events for ordered UI processing
///
/// This coordinator extracts the complex capability handling logic from ChatViewModel+Events.swift,
/// making it independently testable while maintaining the same behavior.
@MainActor
final class CapabilityInvocationCoordinator {

    // MARK: - Initialization

    init() {}

    // MARK: - Capability Generating Handling

    /// Handle a capability generating event — emitted when the LLM starts a capability invocation block,
    /// BEFORE arguments are fully streamed. Creates a spinning chip immediately.
    func handleCapabilityInvocationGenerating(
        _ pluginResult: CapabilityInvocationGeneratingPlugin.Result,
        context: CapabilityInvocationContext
    ) {
        let eventTimestamp = pluginResult.timestamp ?? Date()
        // Finalize any active thinking message before capability chip appears
        context.finalizeThinkingMessageIfNeeded()

        // Skip if chip already exists (catch-up/reconstruction)
        if MessageFinder.hasCapabilityInvocationMessage(invocationId: pluginResult.invocationId, in: context.messages) { return }

        context.flushPendingTextUpdates()
        context.finalizeStreamingMessage()

        // Build the chip content based on capability kind
        let content: MessageContent
        if pluginResult.identity.isUserInteractionCapability {
            let capabilityData = UserInteractionInvocationData(
                invocationId: pluginResult.invocationId,
                params: UserInteractionParams(questions: [], context: nil),
                answers: [:],
                status: .generating,
                result: nil
            )
            content = .userInteraction(capabilityData)
        } else {
            let invocation = CapabilityInvocationData(
                id: pluginResult.invocationId,
                status: .generating,
                arguments: "",
                generatedAt: eventTimestamp,
                identity: pluginResult.identity
            )
            content = .capabilityInvocation(invocation)
        }

        // Append, track, and record — shared across all capability kinds
        trackGeneratingChip(
            content: content,
            invocationId: pluginResult.invocationId,
            modelPrimitiveName: pluginResult.modelPrimitiveName,
            context: context
        )

        // Only regular capabilities enqueue for staggered animation
        if !pluginResult.identity.isUserInteractionCapability {
            let invocationStartedData = UIUpdateQueue.CapabilityInvocationStartData(
                invocationId: pluginResult.invocationId,
                modelPrimitiveName: pluginResult.modelPrimitiveName,
                arguments: "",
                timestamp: eventTimestamp
            )
            context.enqueueCapabilityInvocationStart(invocationStartedData)
        }
    }

    // MARK: - Capability Start Handling

    /// Handle a capability start event.
    ///
    /// - Parameters:
    ///   - pluginResult: The plugin result with capability start data
    ///   - result: The processed result from ChatEventHandler
    ///   - context: The context providing access to state and dependencies
    func handleCapabilityInvocationStarted(
        _ pluginResult: CapabilityInvocationStartedPlugin.Result,
        context: CapabilityInvocationContext
    ) {
        let eventTimestamp = pluginResult.timestamp ?? Date()
        let isUserInteraction = pluginResult.identity.isUserInteractionCapability

        // Parse UserInteraction params if applicable
        var userInteractionParams: UserInteractionParams?
        if isUserInteraction {
            userInteractionParams = decodeUserInteractionParams(from: pluginResult)
        }

        // Create capability data
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

        // Finalize any active thinking message before capability invocations begin
        context.finalizeThinkingMessageIfNeeded()

        // CRITICAL: Check if this capability already exists from catch-up or capability.invocation.generating.
        // When resuming an in-progress session, catch-up creates capability invocation messages for running/completed capabilities.
        // capability.invocation.generating also pre-creates chips before capability.invocation.started arrives.
        // The server then continues streaming those same capabilities, which would cause duplicates.
        if let existingIndex = context.messageIndex.index(forCapabilityInvocationId: pluginResult.invocationId)
            ?? MessageFinder.lastIndexOfCapabilityInvocation(id: pluginResult.invocationId, in: context.messages) {

            // UserInteraction messages need special update logic (status transition, params).
            // Let them fall through to handleUserInteractionCapabilityInvocationStart below.
            if case .userInteraction = context.messages[existingIndex].content {
                // Fall through — handled below at line "if isUserInteraction"
            } else {
                context.logInfo("Updating existing capability.invocation.started for \(pluginResult.modelPrimitiveName) (invocationId: \(pluginResult.invocationId)) with arguments")
                // Still make the capability visible (in case it wasn't)
                context.makeCapabilityInvocationVisible(pluginResult.invocationId)

                // Update the existing chip with full arguments from capability.invocation.started
                if case .capabilityInvocation(var existing) = context.messages[existingIndex].content {
                    existing.arguments = pluginResult.formattedArguments
                    existing.payloadJSON = pluginResult.arguments
                    existing.status = .running
                    existing.startedAt = existing.startedAt ?? eventTimestamp
                    existing.identity = pluginResult.identity
                    context.messages[existingIndex].content = .capabilityInvocation(existing)
                    context.currentCapabilityInvocationMessages[context.messages[existingIndex].id] = context.messages[existingIndex]
                }

                // Update tracked capability invocation arguments
                if let idx = context.currentTurnCapabilityInvocations.firstIndex(where: { $0.invocationId == pluginResult.invocationId }) {
                    context.currentTurnCapabilityInvocations[idx].arguments = pluginResult.formattedArguments
                }

                return
            }
        }

        // Finalize any current streaming text before capability starts
        context.flushPendingTextUpdates()
        context.finalizeStreamingMessage()

        // Handle UserInteraction specially
        if isUserInteraction {
            handleUserInteractionCapabilityInvocationStart(pluginResult, params: userInteractionParams, context: context)
            return
        }

        // Create the capability message
        let message = ChatMessage(role: .assistant, content: .capabilityInvocation(invocation))

        // Append message to chat
        context.appendToMessages(message)
        context.currentCapabilityInvocationMessages[message.id] = message
        context.runningCapabilityInvocationCount += 1

        // Make capability immediately visible for rendering
        context.makeCapabilityInvocationVisible(pluginResult.invocationId)

        // Track capability invocation for persistence
        let record = CapabilityInvocationRecord(
            invocationId: pluginResult.invocationId,
            modelPrimitiveName: pluginResult.modelPrimitiveName,
            arguments: pluginResult.formattedArguments,
            identity: pluginResult.identity
        )
        context.currentTurnCapabilityInvocations.append(record)

        // Enqueue capability start for ordered processing and staggered animation
        let invocationStartedData = UIUpdateQueue.CapabilityInvocationStartData(
            invocationId: pluginResult.invocationId,
            modelPrimitiveName: pluginResult.modelPrimitiveName,
            arguments: pluginResult.formattedArguments,
            timestamp: eventTimestamp
        )
        context.enqueueCapabilityInvocationStart(invocationStartedData)
    }

    // MARK: - Capability End Handling

    /// Handle a capability end event.
    ///
    /// - Parameters:
    ///   - pluginResult: The plugin result with capability end data
    ///   - result: The processed result from ChatEventHandler
    ///   - context: The context providing access to state and dependencies
    func handleCapabilityInvocationCompleted(
        _ pluginResult: CapabilityInvocationCompletedPlugin.Result,
        context: CapabilityInvocationContext
    ) {
        let statusLabel = pluginResult.success ? "success" : "error"
        context.logInfo("Capability ended: \(pluginResult.invocationId) status=\(statusLabel) duration=\(pluginResult.duration ?? 0)ms")
        context.logDebug("Capability result: \(pluginResult.displayResult.prefix(300))")

        // Finalize the current thinking message before starting a new block
        context.finalizeThinkingMessageIfNeeded()

        // Reset thinking state after capability completion
        // Any subsequent thinking deltas should start a new thinking block
        context.resetThinkingForNewBlock()

        // Check if this is an UserInteraction capability end
        if let index = MessageFinder.lastIndexOfUserInteraction(invocationId: pluginResult.invocationId, in: context.messages) {
            if case .userInteraction(let data) = context.messages[index].content {
                // In async mode, capability.invocation.completed means questions are ready for user
                // Status is already .pending, now auto-open the sheet
                context.logInfo("UserInteraction capability.invocation.completed - opening sheet for user input")
                context.openUserInteractionSheet(for: data)
            }
            return
        }

        // Update tracked capability invocation with result
        if let idx = context.currentTurnCapabilityInvocations.firstIndex(where: { $0.invocationId == pluginResult.invocationId }) {
            context.currentTurnCapabilityInvocations[idx].result = pluginResult.displayResult
            context.currentTurnCapabilityInvocations[idx].isError = !pluginResult.success
        }

        // Enqueue capability end for ordered processing
        let invocationCompletedData = UIUpdateQueue.CapabilityInvocationEndData(
            invocationId: pluginResult.invocationId,
            success: pluginResult.success,
            result: pluginResult.displayResult,
            durationMs: pluginResult.duration,
            timestamp: pluginResult.timestamp ?? Date(),
            details: pluginResult.rawDetails,
            identity: pluginResult.identity
        )
        context.enqueueCapabilityInvocationEnd(invocationCompletedData)
    }

    // MARK: - Private Helpers

    /// Append a generating chip to chat, track in currentCapabilityInvocationMessages, and record for persistence.
    /// Shared by UserInteraction and regular capability chips.
    private func trackGeneratingChip(
        content: MessageContent,
        invocationId: String,
        modelPrimitiveName: String,
        context: CapabilityInvocationContext
    ) {
        let message = ChatMessage(role: .assistant, content: content)
        context.appendToMessages(message)
        context.currentCapabilityInvocationMessages[message.id] = message
        context.runningCapabilityInvocationCount += 1
        context.makeCapabilityInvocationVisible(invocationId)

        let identity: CapabilityIdentity = {
            switch content {
            case .capabilityInvocation(let data):
                return data.identity
            case .userInteraction:
                return CapabilityIdentity(
                    modelPrimitiveName: modelPrimitiveName,
                    contractId: "capability::execute",
                    functionId: "capability::execute"
                )
            default:
                return CapabilityIdentity(modelPrimitiveName: modelPrimitiveName)
            }
        }()

        let record = CapabilityInvocationRecord(
            invocationId: invocationId,
            modelPrimitiveName: modelPrimitiveName,
            arguments: "",
            identity: identity
        )
        context.currentTurnCapabilityInvocations.append(record)
    }

    /// Handle UserInteraction capability start - creates or updates special message
    private func handleUserInteractionCapabilityInvocationStart(
        _ pluginResult: CapabilityInvocationStartedPlugin.Result,
        params: UserInteractionParams?,
        context: CapabilityInvocationContext
    ) {
        context.logInfo("UserInteraction capability detected")

        // Mark that UserInteraction was called in this turn
        // This suppresses any subsequent text deltas (question should be final entry)
        context.userInteractionCalledInTurn = true

        // Check if a generating chip already exists from capability.invocation.generating
        if let existingIndex = MessageFinder.lastIndexOfUserInteraction(invocationId: pluginResult.invocationId, in: context.messages) {
            // Update existing generating chip with real params
            if case .userInteraction(var capabilityData) = context.messages[existingIndex].content {
                if let params = params {
                    capabilityData.params = params
                    capabilityData.status = .pending
                } else {
                    context.logError("Failed to parse UserInteraction params: \(pluginResult.formattedArguments.prefix(500))")
                    capabilityData.status = .pending
                }
                context.messages[existingIndex].content = .userInteraction(capabilityData)
                context.currentCapabilityInvocationMessages[context.messages[existingIndex].id] = context.messages[existingIndex]
            }

            // Update tracked capability invocation arguments
            if let idx = context.currentTurnCapabilityInvocations.firstIndex(where: { $0.invocationId == pluginResult.invocationId }) {
                context.currentTurnCapabilityInvocations[idx].arguments = pluginResult.formattedArguments
            }
            return
        }

        // No existing chip — create fresh (e.g. reconstruction without capability.invocation.generating)

        // Use pre-parsed params, fall back to regular capability display if parsing failed
        guard let params = params else {
            context.logError("Failed to parse UserInteraction params: \(pluginResult.formattedArguments.prefix(500))")
            let invocation = CapabilityInvocationData(
                id: pluginResult.invocationId,
                status: .error,
                arguments: pluginResult.formattedArguments,
                payloadJSON: pluginResult.arguments,
                result: "Unable to parse interaction payload.",
                identity: pluginResult.identity
            )
            let message = ChatMessage(role: .assistant, content: .capabilityInvocation(invocation))
            context.appendToMessages(message)
            context.makeCapabilityInvocationVisible(pluginResult.invocationId)
            return
        }

        // Create UserInteraction capability data with pending status
        let capabilityData = UserInteractionInvocationData(
            invocationId: pluginResult.invocationId,
            params: params,
            answers: [:],
            status: .pending,
            result: nil
        )

        let message = ChatMessage(role: .assistant, content: .userInteraction(capabilityData))
        context.appendToMessages(message)

        // Track capability invocation for persistence
        let record = CapabilityInvocationRecord(
            invocationId: pluginResult.invocationId,
            modelPrimitiveName: pluginResult.modelPrimitiveName,
            arguments: pluginResult.formattedArguments,
            identity: pluginResult.identity
        )
        context.currentTurnCapabilityInvocations.append(record)
    }

    private func decodeUserInteractionParams(
        from pluginResult: CapabilityInvocationStartedPlugin.Result
    ) -> UserInteractionParams? {
        if let paramsData = pluginResult.formattedArguments.data(using: .utf8),
           let params = try? JSONDecoder().decode(UserInteractionParams.self, from: paramsData) {
            return params
        }
        guard let payload = pluginResult.arguments?["payload"],
              let payloadDict = payload.value as? [String: Any] else {
            return nil
        }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: payloadDict, options: [])
            return try JSONDecoder().decode(UserInteractionParams.self, from: jsonData)
        } catch {
            return nil
        }
    }

}
