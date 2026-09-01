import Foundation
import SwiftUI
@preconcurrency import UIKit

/// SwiftUI's boundary for the native chat surface. SwiftUI owns only this
/// adapter and the surrounding routes; the returned parent owns transcript,
/// composer, keyboard, sizing, and every native offset.
struct ChatUIKitSessionSurfaceHost: UIViewControllerRepresentable {
    let transcriptInput: ChatUIKitPresentationInput?
    let composerInput: ChatUIKitComposerInput
    let activity: ChatUIKitPresentationActivity
    let mediaLoader: ChatMediaLoader?
    let mediaIdentity: (String) -> ChatMediaIdentity?
    let onComposerIntent: @MainActor (ChatUIKitComposerIntent) -> Void
    let onSend: @MainActor (String?, ChatUIKitComposerSendIdentity) -> Bool
    let onLoadEarlier: @MainActor () -> Void
    let onAttachmentTapped: @MainActor (String, Int) -> Void
    let onToolTapped: @MainActor (String) -> Void
    let onThinkingDetails: @MainActor (String) -> Void
    let onNotificationDetails: @MainActor (String) -> Void
    let onViewportOutcome: @MainActor (ChatUIKitViewportTransactionOutcome) -> Void

    final class Coordinator {
        private var sourceGeneration: UInt64?
        private var sourceVersion: UInt64?
        private var sourceRows: [ChatUIKitTranscriptRow] = []
        private var sourceHistory: ChatUIKitHistoryState = .hidden
        private(set) var uiVersion: UInt64 = 0

        /// The projection source supplies the payload. This coordinator owns
        /// only the UI admission clock, never a second transcript value. A
        /// body refresh with the same immutable source is deliberately a no-op.
        func admittedInput(_ input: ChatUIKitPresentationInput) -> ChatUIKitPresentationInput? {
            if let sourceGeneration, input.generation < sourceGeneration { return nil }
            if sourceGeneration == input.generation,
               let sourceVersion,
               input.version < sourceVersion { return nil }
            if sourceGeneration == input.generation,
               sourceVersion == input.version,
               sourceRows == input.rows,
               sourceHistory == input.history {
                return nil
            }
            sourceGeneration = input.generation
            sourceVersion = input.version
            sourceRows = input.rows
            sourceHistory = input.history
            guard uiVersion < .max else { return nil }
            uiVersion &+= 1
            return ChatUIKitPresentationInput(
                generation: input.generation,
                version: uiVersion,
                rows: input.rows,
                history: input.history
            )
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> ChatUIKitSessionSurfaceController {
        let controller = ChatUIKitSessionSurfaceController()
        installCallbacks(on: controller)
        return controller
    }

    func updateUIViewController(
        _ controller: ChatUIKitSessionSurfaceController,
        context: Context
    ) {
        installCallbacks(on: controller)
        controller.transcript.chatMediaLoader = mediaLoader
        controller.transcript.chatMediaIdentity = mediaIdentity
        controller.setPresentationActivity(activity)
        if let transcriptInput,
           let admitted = context.coordinator.admittedInput(transcriptInput) {
            _ = controller.applyTranscript(admitted)
        }
        _ = controller.applyComposer(composerInput)
    }

    private func installCallbacks(on controller: ChatUIKitSessionSurfaceController) {
        controller.composer.onIntent = { [weak composer = controller.composer] intent in
            guard case .send(let behavior, let identity) = intent else {
                self.onComposerIntent(intent)
                return
            }
            let accepted = self.onSend(behavior, identity)
            composer?.resolveSend(identity: identity, accepted: accepted)
        }
        controller.transcript.onLoadEarlier = onLoadEarlier
        controller.transcript.onAttachmentTapped = onAttachmentTapped
        controller.transcript.onToolTapped = onToolTapped
        controller.transcript.onThinkingDetails = onThinkingDetails
        controller.transcript.onNotificationDetails = onNotificationDetails
        controller.transcript.onTransactionOutcome = onViewportOutcome
    }
}
