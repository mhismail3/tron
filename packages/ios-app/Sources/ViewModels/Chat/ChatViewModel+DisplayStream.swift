import Foundation
import UIKit

// MARK: - Display Stream State & Handler

extension ChatViewModel: DisplayStreamEventHandler {

    // MARK: - Handler

    func handleDisplayFrame(_ result: DisplayFramePlugin.Result) {
        // Ignore frames for a stream we've stopped.
        if let stopped = stoppedStreamId, stopped == result.streamId {
            return
        }

        let isNewStream = (activeStreamId == nil)
        activeStreamId = result.streamId
        streamFrameImage = result.image
        streamToolCallId = result.toolCallId

        // Auto-open the sheet exactly once per stream.
        if isNewStream && !hasAutoOpenedStream {
            showStreamSheet = true
            hasAutoOpenedStream = true
        }
    }

    // MARK: - Stream Lifecycle

    /// Called when the stream ends (agent complete, frames stop arriving).
    /// Keeps `streamFrameImage` and `streamToolCallId` so the tool chip
    /// can still show the last frame after the stream is over.
    func endDisplayStream() {
        activeStreamId = nil
    }

    /// Stop the active display stream via RPC and clean up active state.
    /// Keeps the last frame for post-stream viewing.
    func stopDisplayStream() {
        guard let streamId = activeStreamId else { return }

        // Mark this stream as stopped so incoming frames are ignored
        // even if the server takes a moment to actually stop the producer.
        stoppedStreamId = streamId
        activeStreamId = nil

        launchBackground { [weak self] in
            guard let self else { return }
            do {
                let _ = try await self.rpcClient.display.stopStream(streamId: streamId)
                self.logInfo("Stopped display stream: \(streamId)")
            } catch {
                self.logWarning("Failed to stop display stream: \(error)")
            }
        }
    }

    /// Clear all stream state (e.g., on session change or disconnect).
    func clearDisplayStreamState() {
        activeStreamId = nil
        stoppedStreamId = nil
        streamFrameImage = nil
        streamToolCallId = nil
        showStreamSheet = false
        hasAutoOpenedStream = false
    }
}
