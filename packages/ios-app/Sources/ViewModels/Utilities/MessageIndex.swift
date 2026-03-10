import Foundation

// MARK: - MessageMutating Protocol

/// Protocol that centralizes message array mutations with automatic index sync.
///
/// Any type that holds a `messages` array and a `messageIndex` can conform.
/// Protocol extension methods ensure every append/insert/remove keeps the index in sync,
/// eliminating the need to call `messageIndex.didXxx` manually at every mutation site.
///
/// Usage: Conform context protocols to `MessageMutating` instead of exposing
/// `var messages: [ChatMessage] { get set }` + `var messageIndex: MessageIndex { get }` separately.
@MainActor
protocol MessageMutating: AnyObject {
    var messages: [ChatMessage] { get set }
    var messageIndex: MessageIndex { get }
}

extension MessageMutating {

    /// Append a single message to the end.
    func appendToMessages(_ message: ChatMessage) {
        messages.append(message)
        messageIndex.didAppend(message, at: messages.count - 1)
    }

    /// Insert a single message at the given position.
    func insertInMessages(_ message: ChatMessage, at position: Int) {
        messages.insert(message, at: position)
        messageIndex.didInsert(message, at: position, totalCount: messages.count)
    }

    /// Remove a message at the given position. Returns the removed message.
    @discardableResult
    func removeFromMessages(at position: Int) -> ChatMessage {
        let removed = messages[position]
        messages.remove(at: position)
        messageIndex.didRemove(removed, at: position, newTotalCount: messages.count)
        return removed
    }

    /// Remove all messages matching a predicate. Rebuilds the index.
    func removeFromMessages(where predicate: (ChatMessage) -> Bool) {
        messages.removeAll(where: predicate)
        messageIndex.rebuild(from: messages)
    }

    /// Replace the entire messages array. Rebuilds the index.
    func replaceAllMessages(with newMessages: [ChatMessage]) {
        messages = newMessages
        messageIndex.rebuild(from: messages)
    }

    /// Append multiple messages. Rebuilds the index.
    func appendToMessages(contentsOf newMessages: [ChatMessage]) {
        messages.append(contentsOf: newMessages)
        messageIndex.rebuild(from: messages)
    }

    /// Insert messages at the front (for pagination). Uses optimized shift.
    func insertAtFrontOfMessages(_ newMessages: [ChatMessage]) {
        messages.insert(contentsOf: newMessages, at: 0)
        messageIndex.didInsertAtFront(messages: newMessages, totalCount: messages.count)
    }

    /// Clear all messages and the index.
    func clearAllMessages() {
        messages.removeAll()
        messageIndex.clear()
    }
}

// MARK: - MessageIndex

/// O(1) lookup index for messages by UUID and toolCallId.
/// Maintains dictionaries that stay in sync with the messages array.
/// All mutations to the message array should go through `MessageMutating` protocol methods.
@MainActor
final class MessageIndex {

    private var idToIndex: [UUID: Int] = [:]
    private var toolCallIdToIndex: [String: Int] = [:]

    // MARK: - Lookup

    /// O(1) lookup by message UUID
    func index(for id: UUID) -> Int? {
        idToIndex[id]
    }

    /// O(1) lookup by toolCallId
    func index(forToolCallId toolCallId: String) -> Int? {
        toolCallIdToIndex[toolCallId]
    }

    // MARK: - Rebuild

    /// Rebuild the entire index from a messages array.
    /// Call after bulk operations (pagination load, clear + reload).
    func rebuild(from messages: [ChatMessage]) {
        idToIndex.removeAll(keepingCapacity: true)
        toolCallIdToIndex.removeAll(keepingCapacity: true)

        for (i, message) in messages.enumerated() {
            idToIndex[message.id] = i
            if let toolCallId = extractToolCallId(from: message) {
                toolCallIdToIndex[toolCallId] = i
            }
        }
    }

    /// Notify the index that a message was appended at the end.
    func didAppend(_ message: ChatMessage, at index: Int) {
        idToIndex[message.id] = index
        if let toolCallId = extractToolCallId(from: message) {
            toolCallIdToIndex[toolCallId] = index
        }
    }

    /// Notify the index that a message was inserted at the given position.
    /// All indices >= position shift right by 1.
    func didInsert(_ message: ChatMessage, at position: Int, totalCount: Int) {
        // Shift existing entries at or after `position`
        shiftIndices(from: position, by: 1, totalCount: totalCount)

        idToIndex[message.id] = position
        if let toolCallId = extractToolCallId(from: message) {
            toolCallIdToIndex[toolCallId] = position
        }
    }

    /// Notify the index that messages were inserted at the front.
    /// All existing indices shift right by `count`.
    func didInsertAtFront(messages: [ChatMessage], totalCount: Int) {
        // Shift all existing entries
        shiftIndices(from: 0, by: messages.count, totalCount: totalCount)

        for (i, message) in messages.enumerated() {
            idToIndex[message.id] = i
            if let toolCallId = extractToolCallId(from: message) {
                toolCallIdToIndex[toolCallId] = i
            }
        }
    }

    /// Notify the index that a message was removed at the given position.
    /// All indices > position shift left by 1.
    func didRemove(_ message: ChatMessage, at position: Int, newTotalCount: Int) {
        idToIndex.removeValue(forKey: message.id)
        if let toolCallId = extractToolCallId(from: message) {
            toolCallIdToIndex.removeValue(forKey: toolCallId)
        }

        // Shift entries after the removed position
        shiftIndices(from: position, by: -1, totalCount: newTotalCount + 1)
    }

    /// Notify the index that a message's content was updated in place.
    /// The index position doesn't change, but toolCallId mapping may need updating.
    func didUpdate(_ message: ChatMessage, at position: Int) {
        // Re-register toolCallId in case content changed
        if let toolCallId = extractToolCallId(from: message) {
            toolCallIdToIndex[toolCallId] = position
        }
    }

    /// Clear the entire index.
    func clear() {
        idToIndex.removeAll()
        toolCallIdToIndex.removeAll()
    }

    // MARK: - Private

    private func shiftIndices(from startPosition: Int, by delta: Int, totalCount: Int) {
        for (id, idx) in idToIndex where idx >= startPosition {
            idToIndex[id] = idx + delta
        }
        for (toolCallId, idx) in toolCallIdToIndex where idx >= startPosition {
            toolCallIdToIndex[toolCallId] = idx + delta
        }
    }

    private func extractToolCallId(from message: ChatMessage) -> String? {
        switch message.content {
        case .toolUse(let data):
            return data.toolCallId
        case .toolResult(let data):
            return data.toolCallId
        case .askUserQuestion(let data):
            return data.toolCallId
        case .subagent(let data):
            return data.toolCallId
        default:
            return nil
        }
    }
}
