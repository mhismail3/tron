import Foundation
import UIKit

/// Coordinates capability invocation event handling (start/end) for ChatViewModel.
///
/// Responsibilities:
/// - Creating capability invocation messages on capability.invocation.started
/// - Handling special tools: AskUserQuestion
/// - Tracking capability invocations for the current turn
/// - Enqueuing capability invocation events for ordered UI processing
///
/// This coordinator extracts the complex tool handling logic from ChatViewModel+Events.swift,
/// making it independently testable while maintaining the same behavior.
@MainActor
final class CapabilityInvocationCoordinator {

    // MARK: - Initialization

    init() {}

    // MARK: - Tool Generating Handling

    /// Handle a tool generating event — emitted when the LLM starts a capability invocation block,
    /// BEFORE arguments are fully streamed. Creates a spinning chip immediately.
    func handleCapabilityInvocationGenerating(
        _ pluginResult: CapabilityInvocationGeneratingPlugin.Result,
        context: CapabilityInvocationContext
    ) {
        // Finalize any active thinking message before tool chip appears
        context.finalizeThinkingMessageIfNeeded()

        // Skip if chip already exists (catch-up/reconstruction)
        if MessageFinder.hasCapabilityInvocationMessage(invocationId: pluginResult.invocationId, in: context.messages) { return }

        context.flushPendingTextUpdates()
        context.finalizeStreamingMessage()

        // Build the chip content based on tool kind
        let content: MessageContent
        if pluginResult.identity.isAskUserCapability {
            let toolData = AskUserQuestionToolData(
                invocationId: pluginResult.invocationId,
                params: AskUserQuestionParams(questions: [], context: nil),
                answers: [:],
                status: .generating,
                result: nil
            )
            content = .askUserQuestion(toolData)
        } else {
            let invocation = CapabilityInvocationData(
                id: pluginResult.invocationId,
                status: .generating,
                arguments: "",
                identity: pluginResult.identity
            )
            content = .capabilityInvocation(invocation)
        }

        // Append, track, and record — shared across all tool kinds
        trackGeneratingChip(
            content: content,
            invocationId: pluginResult.invocationId,
            modelToolName: pluginResult.modelToolName,
            context: context
        )

        // Only regular tools enqueue for staggered animation
        if !pluginResult.identity.isAskUserCapability {
            let capabilityStartData = UIUpdateQueue.ToolStartData(
                invocationId: pluginResult.invocationId,
                modelToolName: pluginResult.modelToolName,
                arguments: "",
                timestamp: Date()
            )
            context.enqueueCapabilityInvocationStart(capabilityStartData)
        }
    }

    // MARK: - Tool Start Handling

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
        let isAskUserQuestion = pluginResult.identity.isAskUserCapability

        // Parse AskUserQuestion params if applicable
        var askUserQuestionParams: AskUserQuestionParams?
        if isAskUserQuestion {
            if let paramsData = pluginResult.formattedArguments.data(using: .utf8) {
                askUserQuestionParams = try? JSONDecoder().decode(AskUserQuestionParams.self, from: paramsData)
            }
        }

        // Create tool data
        let invocation = CapabilityInvocationData(
            id: pluginResult.invocationId,
            status: .running,
            arguments: pluginResult.formattedArguments,
            payloadJSON: pluginResult.arguments,
            identity: pluginResult.identity
        )

        context.logInfo("Capability started: \(pluginResult.modelToolName) [\(pluginResult.invocationId)]")
        context.logDebug("Tool args: \(pluginResult.formattedArguments.prefix(200))")

        // Finalize any active thinking message before tools begin
        context.finalizeThinkingMessageIfNeeded()

        // CRITICAL: Check if this tool already exists from catch-up or capability.invocation.generating.
        // When resuming an in-progress session, catch-up creates capability invocation messages for running/completed tools.
        // capability.invocation.generating also pre-creates chips before capability.invocation.started arrives.
        // The server then continues streaming those same tools, which would cause duplicates.
        if let existingIndex = context.messageIndex.index(forCapabilityInvocationId: pluginResult.invocationId)
            ?? MessageFinder.lastIndexOfCapabilityInvocation(id: pluginResult.invocationId, in: context.messages) {

            // AskUserQuestion messages need special update logic (status transition, params).
            // Let them fall through to handleAskUserQuestionToolStart below.
            if case .askUserQuestion = context.messages[existingIndex].content {
                // Fall through — handled below at line "if isAskUserQuestion"
            } else {
                context.logInfo("Updating existing capability.invocation.started for \(pluginResult.modelToolName) (invocationId: \(pluginResult.invocationId)) with arguments")
                // Still make the tool visible (in case it wasn't)
                context.makeCapabilityInvocationVisible(pluginResult.invocationId)

                // Update the existing chip with full arguments from capability.invocation.started
                if case .capabilityInvocation(var existing) = context.messages[existingIndex].content {
                    existing.arguments = pluginResult.formattedArguments
                    existing.payloadJSON = pluginResult.arguments
                    existing.status = .running
                    existing.identity = pluginResult.identity
                    context.messages[existingIndex].content = .capabilityInvocation(existing)
                    context.currentToolMessages[context.messages[existingIndex].id] = context.messages[existingIndex]
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

        // Handle AskUserQuestion specially
        if isAskUserQuestion {
            handleAskUserQuestionToolStart(pluginResult, params: askUserQuestionParams, context: context)
            return
        }

        // Create the tool message
        let message = ChatMessage(role: .assistant, content: .capabilityInvocation(invocation))

        // Append message to chat
        context.appendToMessages(message)
        context.currentToolMessages[message.id] = message
        context.runningToolCount += 1

        // Make tool immediately visible for rendering
        context.makeCapabilityInvocationVisible(pluginResult.invocationId)

        // Track capability invocation for persistence
        let record = CapabilityInvocationRecord(
            invocationId: pluginResult.invocationId,
            modelToolName: pluginResult.modelToolName,
            arguments: pluginResult.formattedArguments
        )
        context.currentTurnCapabilityInvocations.append(record)

        // Enqueue capability start for ordered processing and staggered animation
        let capabilityStartData = UIUpdateQueue.ToolStartData(
            invocationId: pluginResult.invocationId,
            modelToolName: pluginResult.modelToolName,
            arguments: pluginResult.formattedArguments,
            timestamp: Date()
        )
        context.enqueueCapabilityInvocationStart(capabilityStartData)
    }

    // MARK: - Tool End Handling

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

        // Reset thinking state after tool completion
        // Any subsequent thinking deltas should start a new thinking block
        context.resetThinkingForNewBlock()

        // Check if this is an AskUserQuestion capability end
        if let index = MessageFinder.lastIndexOfAskUserQuestion(invocationId: pluginResult.invocationId, in: context.messages) {
            if case .askUserQuestion(let data) = context.messages[index].content {
                // In async mode, capability.invocation.completed means questions are ready for user
                // Status is already .pending, now auto-open the sheet
                context.logInfo("AskUserQuestion capability.invocation.completed - opening sheet for user input")
                context.openAskUserQuestionSheet(for: data)
            }
            return
        }

        // Update tracked capability invocation with result
        if let idx = context.currentTurnCapabilityInvocations.firstIndex(where: { $0.invocationId == pluginResult.invocationId }) {
            context.currentTurnCapabilityInvocations[idx].result = pluginResult.displayResult
            context.currentTurnCapabilityInvocations[idx].isError = !pluginResult.success
        }

        // Enqueue capability end for ordered processing
        let capabilityEndData = UIUpdateQueue.ToolEndData(
            invocationId: pluginResult.invocationId,
            success: pluginResult.success,
            result: pluginResult.displayResult,
            durationMs: pluginResult.duration,
            details: pluginResult.rawDetails,
            identity: pluginResult.identity
        )
        context.enqueueToolEnd(capabilityEndData)
    }

    // MARK: - Private Helpers

    /// Append a generating chip to chat, track in currentToolMessages, and record for persistence.
    /// Shared by AskUserQuestion and regular tool chips.
    private func trackGeneratingChip(
        content: MessageContent,
        invocationId: String,
        modelToolName: String,
        context: CapabilityInvocationContext
    ) {
        let message = ChatMessage(role: .assistant, content: content)
        context.appendToMessages(message)
        context.currentToolMessages[message.id] = message
        context.runningToolCount += 1
        context.makeCapabilityInvocationVisible(invocationId)

        let record = CapabilityInvocationRecord(
            invocationId: invocationId,
            modelToolName: modelToolName,
            arguments: ""
        )
        context.currentTurnCapabilityInvocations.append(record)
    }

    /// Handle AskUserQuestion capability start - creates or updates special message
    private func handleAskUserQuestionToolStart(
        _ pluginResult: CapabilityInvocationStartedPlugin.Result,
        params: AskUserQuestionParams?,
        context: CapabilityInvocationContext
    ) {
        context.logInfo("AskUserQuestion tool detected")

        // Mark that AskUserQuestion was called in this turn
        // This suppresses any subsequent text deltas (question should be final entry)
        context.askUserQuestionCalledInTurn = true

        // Check if a generating chip already exists from capability.invocation.generating
        if let existingIndex = MessageFinder.lastIndexOfAskUserQuestion(invocationId: pluginResult.invocationId, in: context.messages) {
            // Update existing generating chip with real params
            if case .askUserQuestion(var toolData) = context.messages[existingIndex].content {
                if let params = params {
                    toolData.params = params
                    toolData.status = .pending
                } else {
                    context.logError("Failed to parse AskUserQuestion params: \(pluginResult.formattedArguments.prefix(500))")
                    toolData.status = .pending
                }
                context.messages[existingIndex].content = .askUserQuestion(toolData)
                context.currentToolMessages[context.messages[existingIndex].id] = context.messages[existingIndex]
            }

            // Update tracked capability invocation arguments
            if let idx = context.currentTurnCapabilityInvocations.firstIndex(where: { $0.invocationId == pluginResult.invocationId }) {
                context.currentTurnCapabilityInvocations[idx].arguments = pluginResult.formattedArguments
            }
            return
        }

        // No existing chip — create fresh (e.g. reconstruction without capability.invocation.generating)

        // Use pre-parsed params, fall back to regular tool display if parsing failed
        guard let params = params else {
            context.logError("Failed to parse AskUserQuestion params: \(pluginResult.formattedArguments.prefix(500))")
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

        // Create AskUserQuestion tool data with pending status
        let toolData = AskUserQuestionToolData(
            invocationId: pluginResult.invocationId,
            params: params,
            answers: [:],
            status: .pending,
            result: nil
        )

        let message = ChatMessage(role: .assistant, content: .askUserQuestion(toolData))
        context.appendToMessages(message)

        // Track capability invocation for persistence
        let record = CapabilityInvocationRecord(
            invocationId: pluginResult.invocationId,
            modelToolName: pluginResult.modelToolName,
            arguments: pluginResult.formattedArguments
        )
        context.currentTurnCapabilityInvocations.append(record)
    }

}
