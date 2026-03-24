import Foundation
import UIKit

/// Coordinates tool event handling (start/end) for ChatViewModel.
///
/// Responsibilities:
/// - Creating tool messages on tool.start
/// - Handling special tools: AskUserQuestion
/// - Tracking tool calls for the current turn
/// - Enqueuing tool events for ordered UI processing
///
/// This coordinator extracts the complex tool handling logic from ChatViewModel+Events.swift,
/// making it independently testable while maintaining the same behavior.
@MainActor
final class ToolEventCoordinator {

    // MARK: - Initialization

    init() {}

    // MARK: - Tool Generating Handling

    /// Handle a tool generating event — emitted when the LLM starts a tool call block,
    /// BEFORE arguments are fully streamed. Creates a spinning chip immediately.
    func handleToolGenerating(
        _ pluginResult: ToolGeneratingPlugin.Result,
        context: ToolEventContext
    ) {
        let kind = ToolKind(toolName: pluginResult.toolName)

        // Finalize any active thinking message before tool chip appears
        context.finalizeThinkingMessageIfNeeded()

        // Skip if chip already exists (catch-up/reconstruction)
        if MessageFinder.hasToolMessage(toolCallId: pluginResult.toolCallId, in: context.messages) { return }

        context.flushPendingTextUpdates()
        context.finalizeStreamingMessage()

        // AskUserQuestion gets its own chip type with a .generating spinner
        if kind == .askUserQuestion {
            let toolData = AskUserQuestionToolData(
                toolCallId: pluginResult.toolCallId,
                params: AskUserQuestionParams(questions: [], context: nil),
                answers: [:],
                status: .generating,
                result: nil
            )
            let message = ChatMessage(role: .assistant, content: .askUserQuestion(toolData))
            context.appendToMessages(message)
            context.currentToolMessages[message.id] = message
            context.runningToolCount += 1
            context.makeToolVisible(pluginResult.toolCallId)
            context.appendToMessageWindow(message)

            let record = ToolCallRecord(
                toolCallId: pluginResult.toolCallId,
                toolName: pluginResult.toolName,
                arguments: ""
            )
            context.currentTurnToolCalls.append(record)
            return
        }

        // Create chip with .running status, empty arguments
        let tool = ToolUseData(
            toolName: pluginResult.toolName,
            toolCallId: pluginResult.toolCallId,
            arguments: "",
            status: .running
        )
        let message = ChatMessage(role: .assistant, content: .toolUse(tool))

        context.appendToMessages(message)
        context.currentToolMessages[message.id] = message
        context.runningToolCount += 1
        context.makeToolVisible(pluginResult.toolCallId)
        context.appendToMessageWindow(message)

        // Track tool call for persistence
        let record = ToolCallRecord(
            toolCallId: pluginResult.toolCallId,
            toolName: pluginResult.toolName,
            arguments: ""
        )
        context.currentTurnToolCalls.append(record)

        // Enqueue for UIUpdateQueue ordering
        let toolStartData = UIUpdateQueue.ToolStartData(
            toolCallId: pluginResult.toolCallId,
            toolName: pluginResult.toolName,
            arguments: "",
            timestamp: Date()
        )
        context.enqueueToolStart(toolStartData)
    }

    // MARK: - Tool Start Handling

    /// Handle a tool start event.
    ///
    /// - Parameters:
    ///   - pluginResult: The plugin result with tool start data
    ///   - result: The processed result from ChatEventHandler
    ///   - context: The context providing access to state and dependencies
    func handleToolStart(
        _ pluginResult: ToolStartPlugin.Result,
        context: ToolEventContext
    ) {
        // Classify tool type
        let kind = ToolKind(toolName: pluginResult.toolName)
        let isAskUserQuestion = kind == .askUserQuestion

        // Parse AskUserQuestion params if applicable
        var askUserQuestionParams: AskUserQuestionParams?
        if isAskUserQuestion {
            if let paramsData = pluginResult.formattedArguments.data(using: .utf8) {
                askUserQuestionParams = try? JSONDecoder().decode(AskUserQuestionParams.self, from: paramsData)
            }
        }

        // Create tool data
        let tool = ToolUseData(
            toolName: pluginResult.toolName,
            toolCallId: pluginResult.toolCallId,
            arguments: pluginResult.formattedArguments,
            status: .running
        )

        context.logInfo("Tool started: \(pluginResult.toolName) [\(pluginResult.toolCallId)]")
        context.logDebug("Tool args: \(pluginResult.formattedArguments.prefix(200))")

        // Finalize any active thinking message before tools begin
        context.finalizeThinkingMessageIfNeeded()

        // CRITICAL: Check if this tool already exists from catch-up or tool_generating.
        // When resuming an in-progress session, catch-up creates tool messages for running/completed tools.
        // tool_generating also pre-creates chips before tool_start arrives.
        // The server then continues streaming those same tools, which would cause duplicates.
        if let existingIndex = context.messageIndex.index(forToolCallId: pluginResult.toolCallId)
            ?? MessageFinder.lastIndexOfToolUse(toolCallId: pluginResult.toolCallId, in: context.messages) {

            // AskUserQuestion messages need special update logic (status transition, params).
            // Let them fall through to handleAskUserQuestionToolStart below.
            if case .askUserQuestion = context.messages[existingIndex].content {
                // Fall through — handled below at line "if result.isAskUserQuestion"
            } else {
                context.logInfo("Updating existing tool.start for \(pluginResult.toolName) (toolCallId: \(pluginResult.toolCallId)) with arguments")
                // Still make the tool visible (in case it wasn't)
                context.makeToolVisible(pluginResult.toolCallId)

                // Update the existing chip with full arguments from tool_start
                if case .toolUse(var tool) = context.messages[existingIndex].content {
                    tool.arguments = pluginResult.formattedArguments
                    context.messages[existingIndex].content = .toolUse(tool)
                    context.currentToolMessages[context.messages[existingIndex].id] = context.messages[existingIndex]
                    context.updateInMessageWindow(context.messages[existingIndex])
                }

                // Update tracked tool call arguments
                if let idx = context.currentTurnToolCalls.firstIndex(where: { $0.toolCallId == pluginResult.toolCallId }) {
                    context.currentTurnToolCalls[idx].arguments = pluginResult.formattedArguments
                }

                return
            }
        }

        // Finalize any current streaming text before tool starts
        context.flushPendingTextUpdates()
        context.finalizeStreamingMessage()

        // Handle AskUserQuestion specially
        if isAskUserQuestion {
            handleAskUserQuestionToolStart(pluginResult, params: askUserQuestionParams, context: context)
            return
        }

        // Create the tool message
        let message = ChatMessage(role: .assistant, content: .toolUse(tool))

        // Append message to chat
        context.appendToMessages(message)
        context.currentToolMessages[message.id] = message
        context.runningToolCount += 1

        // Make tool immediately visible for rendering
        context.makeToolVisible(pluginResult.toolCallId)

        // Sync to MessageWindowManager for virtual scrolling
        context.appendToMessageWindow(message)

        // Track tool call for persistence
        let record = ToolCallRecord(
            toolCallId: pluginResult.toolCallId,
            toolName: pluginResult.toolName,
            arguments: pluginResult.formattedArguments
        )
        context.currentTurnToolCalls.append(record)

        // Enqueue tool start for ordered processing and staggered animation
        let toolStartData = UIUpdateQueue.ToolStartData(
            toolCallId: pluginResult.toolCallId,
            toolName: pluginResult.toolName,
            arguments: pluginResult.formattedArguments,
            timestamp: Date()
        )
        context.enqueueToolStart(toolStartData)
    }

    // MARK: - Tool End Handling

    /// Handle a tool end event.
    ///
    /// - Parameters:
    ///   - pluginResult: The plugin result with tool end data
    ///   - result: The processed result from ChatEventHandler
    ///   - context: The context providing access to state and dependencies
    func handleToolEnd(
        _ pluginResult: ToolEndPlugin.Result,
        context: ToolEventContext
    ) {
        let statusLabel = pluginResult.success ? "success" : "error"
        context.logInfo("Tool ended: \(pluginResult.toolCallId) status=\(statusLabel) duration=\(pluginResult.duration ?? 0)ms")
        context.logDebug("Tool result: \(pluginResult.displayResult.prefix(300))")

        // Finalize the current thinking message before starting a new block
        context.finalizeThinkingMessageIfNeeded()

        // Reset thinking state after tool completion
        // Any subsequent thinking deltas should start a new thinking block
        context.resetThinkingForNewBlock()

        // Check if this is an AskUserQuestion tool end
        if let index = MessageFinder.lastIndexOfAskUserQuestion(toolCallId: pluginResult.toolCallId, in: context.messages) {
            if case .askUserQuestion(let data) = context.messages[index].content {
                // In async mode, tool.end means questions are ready for user
                // Status is already .pending, now auto-open the sheet
                context.logInfo("AskUserQuestion tool.end - opening sheet for user input")
                context.openAskUserQuestionSheet(for: data)
            }
            return
        }

        // Update tracked tool call with result
        if let idx = context.currentTurnToolCalls.firstIndex(where: { $0.toolCallId == pluginResult.toolCallId }) {
            context.currentTurnToolCalls[idx].result = pluginResult.displayResult
            context.currentTurnToolCalls[idx].isError = !pluginResult.success
        }

        // Enqueue tool end for ordered processing
        let toolEndData = UIUpdateQueue.ToolEndData(
            toolCallId: pluginResult.toolCallId,
            success: pluginResult.success,
            result: pluginResult.displayResult,
            durationMs: pluginResult.duration,
            details: pluginResult.rawDetails
        )
        context.enqueueToolEnd(toolEndData)
    }

    // MARK: - Private Helpers

    /// Handle AskUserQuestion tool start - creates or updates special message
    private func handleAskUserQuestionToolStart(
        _ pluginResult: ToolStartPlugin.Result,
        params: AskUserQuestionParams?,
        context: ToolEventContext
    ) {
        context.logInfo("AskUserQuestion tool detected")

        // Mark that AskUserQuestion was called in this turn
        // This suppresses any subsequent text deltas (question should be final entry)
        context.askUserQuestionCalledInTurn = true

        // Check if a generating chip already exists from tool_generating
        if let existingIndex = MessageFinder.lastIndexOfAskUserQuestion(toolCallId: pluginResult.toolCallId, in: context.messages) {
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
                context.updateInMessageWindow(context.messages[existingIndex])
            }

            // Update tracked tool call arguments
            if let idx = context.currentTurnToolCalls.firstIndex(where: { $0.toolCallId == pluginResult.toolCallId }) {
                context.currentTurnToolCalls[idx].arguments = pluginResult.formattedArguments
            }
            return
        }

        // No existing chip — create fresh (e.g. reconstruction without tool_generating)

        // Use pre-parsed params, fall back to regular tool display if parsing failed
        guard let params = params else {
            context.logError("Failed to parse AskUserQuestion params: \(pluginResult.formattedArguments.prefix(500))")
            let tool = ToolUseData(
                toolName: pluginResult.toolName,
                toolCallId: pluginResult.toolCallId,
                arguments: pluginResult.formattedArguments,
                status: .running
            )
            let message = ChatMessage(role: .assistant, content: .toolUse(tool))
            context.appendToMessages(message)
            context.makeToolVisible(pluginResult.toolCallId)
            return
        }

        // Create AskUserQuestion tool data with pending status
        let toolData = AskUserQuestionToolData(
            toolCallId: pluginResult.toolCallId,
            params: params,
            answers: [:],
            status: .pending,
            result: nil
        )

        let message = ChatMessage(role: .assistant, content: .askUserQuestion(toolData))
        context.appendToMessages(message)

        // Track tool call for persistence
        let record = ToolCallRecord(
            toolCallId: pluginResult.toolCallId,
            toolName: pluginResult.toolName,
            arguments: pluginResult.formattedArguments
        )
        context.currentTurnToolCalls.append(record)
    }

}
