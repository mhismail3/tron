import Foundation
import UIKit

// MARK: - Display Stream State & Handler

extension ChatViewModel: DisplayStreamEventHandler {

    // MARK: - Handler

    func handleDisplayFrame(_ result: DisplayFramePlugin.Result) {
        let isFirstFrame = (activeStreamId == nil)
        activeStreamId = result.streamId
        streamFrameImage = result.image
        streamToolCallId = result.toolCallId

        if isFirstFrame {
            showStreamSheet = true
        }
    }

    // MARK: - Stream Lifecycle

    /// Called when the stream ends (agent complete, tool result received).
    func endDisplayStream() {
        activeStreamId = nil
        streamFrameImage = nil
        streamToolCallId = nil
        showStreamSheet = false
    }
}
