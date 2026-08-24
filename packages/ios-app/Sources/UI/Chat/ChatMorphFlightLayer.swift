import Observation
import SwiftUI
import UIKit

enum ChatMorphAdmissionPolicy {
    /// Spatial morphs are intentionally reserved for compact composer content.
    /// A multiline prompt can be much taller than its source frame during the
    /// handoff; letting it paint through an interpolated frame produces an
    /// oversized overlay over the keyboard. Long prompts use the bounded row
    /// entrance instead.
    static let maximumPromptBytes = 240
    static let maximumPromptHeight: CGFloat = 112

    static func admitsPrompt(
        text: String,
        sourceFrame: CGRect,
        reduceMotion: Bool
    ) -> Bool {
        !reduceMotion
            && !text.isEmpty
            && text.utf8.count <= maximumPromptBytes
            && sourceFrame.height > 0
            && sourceFrame.height <= maximumPromptHeight
            && sourceFrame.width > 0
            && sourceFrame.width.isFinite
            && sourceFrame.height.isFinite
    }
}

struct ChatMorphID: Hashable, Sendable, Identifiable {
    enum Element: Hashable, Sendable {
        case prompt
        case attachment(String)
    }

    let lifecycleID: String
    let element: Element

    var id: String {
        switch element {
        case .prompt: "\(lifecycleID):prompt"
        case .attachment(let attachmentID): "\(lifecycleID):attachment:\(attachmentID)"
        }
    }
}

@MainActor
@Observable
final class ChatMorphFrameRegistry {
    enum FlightPhase: Equatable, Sendable { case waitingForDestination, animating }
    enum EntranceOwnership: Equatable, Sendable { case ordinary, flight, completed }

    struct Element: Identifiable, Equatable, Sendable {
        let id: ChatMorphID
        let sourceFrame: CGRect
        let text: String?
        let attachment: PendingAttachment?
    }

    struct Flight: Equatable, Sendable {
        let lifecycleID: String
        let generation: Int
        let elements: [Element]
        var destinationFrames: [ChatMorphID: CGRect]
        var phase: FlightPhase

        var isReady: Bool {
            !elements.isEmpty && elements.allSatisfy { destinationFrames[$0.id] != nil }
        }
    }

    static let maximumRememberedFrames = ComposerAttachmentPolicy.maximumCount + 1

    private(set) var flight: Flight?
    private(set) var readinessRevision = 0
    private var completedLifecycleID: String?
    private var abandonedGeneration: Int?
    private var draftPromptFrame: CGRect?
    private var draftAttachmentFrames: [String: CGRect] = [:]

    func recordDraftPrompt(frame: CGRect) {
        draftPromptFrame = Self.valid(frame) ? frame : nil
    }

    func recordDraftAttachment(id: String, frame: CGRect) {
        guard !id.isEmpty else { return }
        if Self.valid(frame) {
            draftAttachmentFrames[id] = frame
            if draftAttachmentFrames.count > ComposerAttachmentPolicy.maximumCount {
                let retained = Set(draftAttachmentFrames.keys.sorted().suffix(
                    ComposerAttachmentPolicy.maximumCount
                ))
                draftAttachmentFrames = draftAttachmentFrames.filter { retained.contains($0.key) }
            }
        } else {
            draftAttachmentFrames[id] = nil
        }
    }

    @discardableResult
    func stage(
        lifecycle: ChatSubmissionLifecycle,
        generation: Int,
        suppress: Bool
    ) -> Bool {
        guard !suppress,
              let submission = lifecycle.submission,
              let lifecycleID = lifecycle.id,
              lifecycle.phase != .idle,
              flight == nil else { return false }
        if completedLifecycleID != lifecycleID { completedLifecycleID = nil }

        var elements: [Element] = []
        if !submission.outgoingText.isEmpty {
            guard let sourceFrame = draftPromptFrame,
                  ChatMorphAdmissionPolicy.admitsPrompt(
                      text: submission.outgoingText,
                      sourceFrame: sourceFrame,
                      reduceMotion: suppress
                  ) else { return false }
            elements.append(Element(
                id: ChatMorphID(lifecycleID: lifecycleID, element: .prompt),
                sourceFrame: sourceFrame,
                text: submission.outgoingText,
                attachment: nil
            ))
        }
        for attachment in lifecycle.attachments {
            guard let sourceFrame = draftAttachmentFrames[attachment.id], Self.valid(sourceFrame) else {
                return false
            }
            elements.append(Element(
                id: ChatMorphID(
                    lifecycleID: lifecycleID,
                    element: .attachment(attachment.id)
                ),
                sourceFrame: sourceFrame,
                text: nil,
                attachment: attachment
            ))
        }
        guard !elements.isEmpty, elements.count <= Self.maximumRememberedFrames else { return false }
        flight = Flight(
            lifecycleID: lifecycleID,
            generation: generation,
            elements: elements,
            destinationFrames: [:],
            phase: .waitingForDestination
        )
        readinessRevision &+= 1
        return true
    }

    func recordDestination(id: ChatMorphID, frame: CGRect) {
        guard var flight, flight.elements.contains(where: { $0.id == id }) else { return }
        guard Self.valid(frame) else {
            if flight.phase == .animating {
                abandonedGeneration = flight.generation
                self.flight = nil
            } else {
                flight.destinationFrames[id] = nil
                self.flight = flight
            }
            readinessRevision &+= 1
            return
        }
        // Endpoints are immutable once motion starts. Keyboard or viewport
        // relayout during a flight abandons spatial motion rather than bending
        // its path or revealing at a different endpoint.
        if flight.phase == .animating {
            guard flight.destinationFrames[id] != frame else { return }
            abandonedGeneration = flight.generation
            self.flight = nil
            readinessRevision &+= 1
            return
        }
        guard flight.destinationFrames[id] != frame else { return }
        flight.destinationFrames[id] = frame
        self.flight = flight
        readinessRevision &+= 1
    }

    func beginAnimation(lifecycleID: String) -> Flight? {
        guard var flight,
              flight.lifecycleID == lifecycleID,
              flight.phase == .waitingForDestination,
              flight.isReady else { return nil }
        flight.phase = .animating
        self.flight = flight
        return flight
    }

    func hidesDestination(_ id: ChatMorphID) -> Bool {
        flight?.elements.contains(where: { $0.id == id }) == true
    }

    /// The outgoing row remains mounted for destination measurement. This
    /// value gives that row one deterministic visual owner: an admitted flight,
    /// the completed flight, or its ordinary fallback entrance.
    func entranceOwnership(for lifecycleID: String) -> EntranceOwnership {
        if flight?.lifecycleID == lifecycleID { return .flight }
        if completedLifecycleID == lifecycleID { return .completed }
        return .ordinary
    }

    @discardableResult
    func completeAnimation(lifecycleID: String) -> Int? {
        guard let flight, flight.lifecycleID == lifecycleID,
              flight.phase == .animating else { return nil }
        completedLifecycleID = lifecycleID
        self.flight = nil
        readinessRevision &+= 1
        return flight.generation
    }

    @discardableResult
    func failOpen(lifecycleID: String) -> Int? {
        guard let flight, flight.lifecycleID == lifecycleID else { return nil }
        self.flight = nil
        readinessRevision &+= 1
        return flight.generation
    }

    @discardableResult
    func abandon() -> Int? {
        let generation = flight?.generation
        flight = nil
        completedLifecycleID = nil
        abandonedGeneration = nil
        readinessRevision &+= 1
        return generation
    }

    @discardableResult
    func consumeAbandonedGeneration() -> Int? {
        defer { abandonedGeneration = nil }
        return abandonedGeneration
    }

    @discardableResult
    func reconcile(installedLifecycleID: String?) -> Int? {
        if let completedLifecycleID, completedLifecycleID != installedLifecycleID {
            self.completedLifecycleID = nil
            readinessRevision &+= 1
        }
        guard let flight, flight.lifecycleID != installedLifecycleID else { return nil }
        self.flight = nil
        readinessRevision &+= 1
        return flight.generation
    }

    private static func valid(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0
            && frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
    }
}

private struct ChatDraftPromptMorphSource: ViewModifier {
    let registry: ChatMorphFrameRegistry

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .global)
        } action: { registry.recordDraftPrompt(frame: $0) }
    }
}

private struct ChatDraftAttachmentMorphSource: ViewModifier {
    let id: String
    let registry: ChatMorphFrameRegistry

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .global)
        } action: { registry.recordDraftAttachment(id: id, frame: $0) }
    }
}

private struct ChatMorphDestination: ViewModifier {
    let id: ChatMorphID
    let registry: ChatMorphFrameRegistry

    func body(content: Content) -> some View {
        content
            .opacity(registry.hidesDestination(id) ? 0 : 1)
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .global)
            } action: { registry.recordDestination(id: id, frame: $0) }
    }
}

extension View {
    func chatDraftPromptMorphSource(registry: ChatMorphFrameRegistry) -> some View {
        modifier(ChatDraftPromptMorphSource(registry: registry))
    }

    func chatDraftAttachmentMorphSource(
        id: String,
        registry: ChatMorphFrameRegistry
    ) -> some View {
        modifier(ChatDraftAttachmentMorphSource(id: id, registry: registry))
    }

    func chatMorphDestination(
        id: ChatMorphID,
        registry: ChatMorphFrameRegistry
    ) -> some View {
        modifier(ChatMorphDestination(id: id, registry: registry))
    }
}

struct ChatMorphFlightLayer: View {
    let registry: ChatMorphFrameRegistry
    let layoutTransaction: ChatLayoutTransaction
    let reduceMotion: Bool

    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            if let flight = registry.flight, flight.phase == .animating {
                let layerFrame = geometry.frame(in: .global)
                ZStack {
                    ForEach(flight.elements) { element in
                        if let destination = flight.destinationFrames[element.id] {
                            flightElement(element, progress: progress)
                                .frame(
                                    width: interpolate(
                                        element.sourceFrame.width,
                                        destination.width,
                                        progress
                                    ),
                                    height: interpolate(
                                        element.sourceFrame.height,
                                        destination.height,
                                        progress
                                    )
                                )
                                // The interpolated frame is the hard visual
                                // boundary. This prevents a long or late
                                // measured text layout from escaping over the
                                // composer and keyboard.
                                .clipShape(RoundedRectangle(
                                    cornerRadius: element.text == nil ? 14 : 22,
                                    style: .continuous
                                ))
                                .clipped()
                                .position(
                                    x: interpolate(
                                        element.sourceFrame.midX,
                                        destination.midX,
                                        progress
                                    ) - layerFrame.minX,
                                    y: interpolate(
                                        element.sourceFrame.midY,
                                        destination.midY,
                                        progress
                                    ) - layerFrame.minY
                                )
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: registry.readinessRevision, initial: true) { _, _ in
            if let generation = registry.consumeAbandonedGeneration() {
                layoutTransaction.settle(generation, source: .morphFlight)
                progress = 0
            }
            startIfReady()
        }
        .onChange(of: layoutTransaction.generation?.id) { _, generation in
            guard let flight = registry.flight, generation != flight.generation else { return }
            registry.abandon()
        }
        .task(id: registry.flight?.lifecycleID) {
            guard let lifecycleID = registry.flight?.lifecycleID else { return }
            if reduceMotion {
                failOpen(lifecycleID: lifecycleID)
                return
            }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled,
                  registry.flight?.lifecycleID == lifecycleID,
                  registry.flight?.phase == .waitingForDestination else { return }
            failOpen(lifecycleID: lifecycleID)
        }
    }

    @ViewBuilder
    private func flightElement(
        _ element: ChatMorphFrameRegistry.Element,
        progress: CGFloat
    ) -> some View {
        if let text = element.text {
            UserPromptText(text: text)
                .padding(.horizontal, ChatPromptContainerStyle.horizontalPadding)
                .padding(.top, ChatPromptContainerStyle.topPadding)
                .padding(.bottom, ChatPromptContainerStyle.userPromptBottomPadding)
                .modifier(UserPromptGlassModifier())
        } else if let attachment = element.attachment {
            if attachment.mimeType.lowercased().hasPrefix("image/") {
                AttachmentThumbnailSurface(
                    image: attachment.preparedThumbnail.map { UIImage(cgImage: $0.image) },
                    name: attachment.name,
                    mimeType: attachment.mimeType
                )
            } else {
                ZStack {
                    AttachmentThumbnailSurface(
                        image: nil,
                        name: attachment.name,
                        mimeType: attachment.mimeType
                    )
                    .opacity(1 - progress)
                    if let blobID = attachment.transportBlobID {
                        TranscriptFileChip(
                            name: attachment.name,
                            mimeType: attachment.mimeType,
                            size: attachment.size,
                            blobID: blobID
                        )
                        .opacity(progress)
                    }
                }
            }
        }
    }

    private func startIfReady() {
        guard !reduceMotion,
              let waiting = registry.flight,
              waiting.phase == .waitingForDestination,
              waiting.generation == layoutTransaction.generation?.id,
              let flight = registry.beginAnimation(lifecycleID: waiting.lifecycleID) else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { progress = 0 }
        guard let animation = layoutTransaction.animation else {
            progress = 1
            finish(flight)
            return
        }
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            progress = 1
        } completion: {
            finish(flight)
        }
    }

    private func finish(_ flight: ChatMorphFrameRegistry.Flight) {
        guard let generation = registry.completeAnimation(lifecycleID: flight.lifecycleID) else { return }
        layoutTransaction.settle(generation, source: .morphFlight)
        progress = 0
    }

    private func failOpen(lifecycleID: String) {
        guard let generation = registry.failOpen(lifecycleID: lifecycleID) else { return }
        layoutTransaction.settle(generation, source: .morphFlight)
        progress = 0
    }

    private func interpolate(_ source: CGFloat, _ destination: CGFloat, _ progress: CGFloat) -> CGFloat {
        source + ((destination - source) * progress)
    }
}
