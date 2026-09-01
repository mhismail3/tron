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
    let onDetailIntent: @MainActor (ChatUIKitTranscriptDetailIntent) -> Void
    let onViewportOutcome: @MainActor (ChatUIKitViewportTransactionOutcome) -> Void
    let onViewportStateChanged: @MainActor (ChatUIKitViewportState) -> Void

    final class Coordinator {
        private struct SourceIdentity: Equatable {
            let generation: UInt64
            let sourceVersion: UInt64
            let payloadFingerprint: Int
        }

        private var sourceIdentity: SourceIdentity?
        private(set) var uiVersion: UInt64 = 0

        /// The projection source supplies the payload. This coordinator owns
        /// only a bounded admission identity, never a second row projection.
        /// A body refresh with the same immutable source is deliberately a
        /// no-op, while handoff-only payload changes remain distinguishable.
        func admittedInput(_ input: ChatUIKitPresentationInput) -> ChatUIKitPresentationInput? {
            let identity = SourceIdentity(
                generation: input.generation,
                sourceVersion: input.version,
                payloadFingerprint: Self.fingerprint(input)
            )
            if let sourceIdentity,
               input.generation < sourceIdentity.generation { return nil }
            if let sourceIdentity,
               input.generation == sourceIdentity.generation,
               input.version < sourceIdentity.sourceVersion { return nil }
            guard identity != sourceIdentity else { return nil }
            guard uiVersion < .max else { return nil }
            sourceIdentity = identity
            uiVersion &+= 1
            return ChatUIKitPresentationInput(
                generation: input.generation,
                version: uiVersion,
                rows: input.rows,
                history: input.history
            )
        }

        private static func fingerprint(_ input: ChatUIKitPresentationInput) -> Int {
            var hasher = Hasher()
            hasher.combine(input.generation)
            hasher.combine(input.version)
            switch input.history {
            case .hidden: hasher.combine(0)
            case .available: hasher.combine(1)
            case .loading: hasher.combine(2)
            case .failed(let message): hasher.combine(3); hasher.combine(message)
            }
            for row in input.rows {
                hasher.combine(row)
            }
            return hasher.finalize()
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
            if case .send(let behavior, let identity) = intent {
                let accepted = self.onSend(behavior, identity)
                composer?.resolveSend(identity: identity, accepted: accepted)
            } else {
                self.onComposerIntent(intent)
                if case .catchUp = intent {
                    controller.transcript.setIntent(.followTail)
                }
            }
        }
        controller.transcript.onLoadEarlier = onLoadEarlier
        controller.transcript.onDetailIntent = onDetailIntent
        controller.transcript.onTransactionOutcome = onViewportOutcome
        controller.transcript.onViewportStateChanged = { state in
            self.onViewportStateChanged(state)
        }
    }
}
