import Foundation
import SwiftUI

/// Protocol defining the context required by ChatEventHandler.
/// Allows ChatViewModel to be abstracted for testing.
///
/// Inherits from:
/// - LoggingContext: Logging and error display
@MainActor
protocol ChatEventContext: LoggingContext {
    /// Whether AskUserQuestion was called in the current turn
    var askUserQuestionCalledInTurn: Bool { get set }

    /// Current browser status
    var browserStatus: BrowserGetStatusResult? { get set }

    /// Current messages array
    var messages: [ChatMessage] { get }

    /// Append a message to the chat
    func appendMessage(_ message: ChatMessage)

    /// Make a tool visible for rendering
    func makeToolVisible(_ toolCallId: String)
}
