import Foundation
import SwiftUI
@preconcurrency import UIKit

/// Exact lightweight admission identity plus a lazy native adapter. SwiftUI can
/// rebuild this value freely; physical rows are materialized only after the
/// coordinator admits a new immutable source.
struct ChatUIKitPresentationSource {
    struct Identity: Equatable {
        let generation: UInt64
        let version: UInt64
        let history: ChatUIKitHistoryState
        let canonicalAliases: [String: String]
    }

    let identity: Identity
    let build: @MainActor () -> ChatUIKitPresentationInput?
}

/// SwiftUI's boundary for the native chat surface. SwiftUI owns only this
/// adapter and the surrounding routes; the returned parent owns transcript,
/// composer, keyboard, sizing, and every native offset.
struct ChatUIKitSessionSurfaceHost: UIViewControllerRepresentable {
    let transcriptSource: ChatUIKitPresentationSource?
    let composerInput: ChatUIKitComposerInput
    let activity: ChatUIKitPresentationActivity
    let mediaLoader: ChatMediaLoader?
    let mediaIdentity: (String) -> ChatMediaIdentity?
    let onComposerIntent: @MainActor (ChatUIKitComposerIntent) -> Void
    let onSend: @MainActor (String?, ChatUIKitComposerSendIdentity) -> Bool
    let onLoadEarlier: @MainActor () -> Void
    let onDetailIntent: @MainActor (ChatUIKitTranscriptDetailIntent) -> Void
    let onViewportOutcome: @MainActor (ChatUIKitViewportTransactionOutcome) -> Void

    @MainActor
    final class Coordinator {
        private var sourceIdentity: ChatUIKitPresentationSource.Identity?
        private(set) var uiVersion: UInt64 = 0

        /// Admits only a lightweight exact source identity before invoking the
        /// row adapter. A failed adapter never consumes the identity, so a
        /// corrected complete projection can retry without another source tick.
        func admittedInput(
            _ source: ChatUIKitPresentationSource
        ) -> ChatUIKitPresentationInput? {
            let identity = source.identity
            if let sourceIdentity,
               identity.generation < sourceIdentity.generation { return nil }
            if let sourceIdentity,
               identity.generation == sourceIdentity.generation,
               identity.version < sourceIdentity.version { return nil }
            guard identity != sourceIdentity,
                  uiVersion < .max,
                  let sourceInput = source.build(),
                  let admitted = ChatUIKitPresentationInput(
                      generation: sourceInput.generation,
                      version: uiVersion &+ 1,
                      rows: sourceInput.rows,
                      history: sourceInput.history
                  ) else { return nil }
            sourceIdentity = identity
            uiVersion &+= 1
            return admitted
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
        if let transcriptSource,
           let admitted = context.coordinator.admittedInput(transcriptSource) {
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
    }
}
