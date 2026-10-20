#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Test-only mounted UIKit evidence, queried at a display boundary. Unlike the
/// semantic callback cache, this cannot report a frame after native unmount.
final class ChatHostedNativeRowMarker: UIView {
    var physicalID = ""
    var semanticID = ""
    var hostIdentity = UUID()
}

/// Sheet rows do not otherwise own a hosted lifetime token. The native marker's
/// identity is created once per mount, never rewritten by a value update.
struct ChatHostedStableRowProbe: UIViewRepresentable {
    let id: String
    func makeUIView(context: Context) -> ChatHostedNativeRowMarker { ChatHostedNativeRowMarker() }
    func updateUIView(_ view: ChatHostedNativeRowMarker, context: Context) {
        view.physicalID = id
        view.semanticID = id
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
    }
}

struct ChatHostedNativeRowProbe: UIViewRepresentable {
    static let composerID = "hosted-composer"
    let physicalID: String
    let semanticID: String
    let identity: UUID

    func makeUIView(context: Context) -> ChatHostedNativeRowMarker {
        let view = ChatHostedNativeRowMarker()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: ChatHostedNativeRowMarker, context: Context) {
        view.physicalID = physicalID
        view.semanticID = semanticID
        view.hostIdentity = identity
    }
}

/// What the profiling scroll harness samples per display frame.
struct ChatHostedObservation: Sendable {
    let revision: Int
    let visibleRowIDs: [String]
    let scrollSettledDistance: CGFloat?
    let isReady: Bool
}

@MainActor
final class ChatHostedProbe {
    private var geometry = ChatTranscriptGeometry.zero
    private var rowFrames: [String: CGRect] = [:]
    private var rowFrameOrder: [String] = []
    private var rowFrameGeneration: Int?
    private var pendingRowFramesByGeneration: [Int: [String: CGRect]] = [:]
    private var scrollSettledDistance: CGFloat?
    private var renderedIDBySemanticID: [String: String] = [:]
    private var installedProjectionRowCount = 0
    private var isReady = false
    private(set) var revision = 0

    var observation: ChatHostedObservation {
        let visibleRowIDs = rowFrames
            .filter { $0.value.maxY > 0 && $0.value.minY < geometry.containerHeight }
            .sorted {
                if $0.value.minY != $1.value.minY { return $0.value.minY < $1.value.minY }
                return $0.key < $1.key
            }
            .map(\.key)
        return ChatHostedObservation(
            revision: revision,
            visibleRowIDs: visibleRowIDs,
            scrollSettledDistance: scrollSettledDistance,
            isReady: isReady
        )
    }

    func updateGeometry(_ value: ChatTranscriptGeometry) {
        geometry = value
        revision &+= 1
    }

    func updateRowFrame(id: String, frame: CGRect, generation: Int? = nil) {
        if let generation {
            if let current = rowFrameGeneration {
                if generation < current { return }
                if generation > current {
                    bufferFutureRowFrame(id: id, frame: frame, generation: generation)
                    return
                }
            } else {
                bufferFutureRowFrame(id: id, frame: frame, generation: generation)
                return
            }
        }
        admitCurrentRowFrame(id: id, frame: frame)
    }

    private func bufferFutureRowFrame(id: String, frame: CGRect, generation: Int) {
        var frames = pendingRowFramesByGeneration[generation, default: [:]]
        frames[id] = frame
        if frames.count > 256 {
            for key in frames.keys.sorted().prefix(frames.count - 256) { frames[key] = nil }
        }
        pendingRowFramesByGeneration[generation] = frames
        let retainedGenerations = Set(pendingRowFramesByGeneration.keys.sorted().suffix(4))
        pendingRowFramesByGeneration = pendingRowFramesByGeneration
            .filter { retainedGenerations.contains($0.key) }
        revision &+= 1
    }

    private func admitCurrentRowFrame(id: String, frame: CGRect) {
        rowFrames[id] = frame
        rowFrameOrder.removeAll { $0 == id }
        rowFrameOrder.append(id)
        if rowFrameOrder.count > 256 {
            let overflow = rowFrameOrder.count - 256
            let removed = Array(rowFrameOrder.prefix(overflow))
            rowFrameOrder.removeFirst(overflow)
            for removedID in removed { rowFrames[removedID] = nil }
        }
        revision &+= 1
    }

    func recordScrollSettle(distanceFromBottom: CGFloat) {
        guard scrollSettledDistance != distanceFromBottom else { return }
        scrollSettledDistance = distanceFromBottom
        revision &+= 1
    }

    func recordProjectionInstall(
        rowCount: Int,
        sourceOrdinal: Int,
        nextRenderedIDBySemanticID: [String: String]
    ) {
        let previousPhysicalIDs = Set(renderedIDBySemanticID.values)
        let nextPhysicalIDs = Set(nextRenderedIDBySemanticID.values)
        let preservesLayout = rowFrameGeneration != nil
            && rowCount == installedProjectionRowCount
            && previousPhysicalIDs == nextPhysicalIDs
            && renderedIDBySemanticID.allSatisfy {
                nextRenderedIDBySemanticID[$0.key] == $0.value
            }
        let retainedFrames = preservesLayout ? rowFrames : [:]
        let retainedOrder = preservesLayout ? rowFrameOrder : []
        renderedIDBySemanticID = nextRenderedIDBySemanticID
        if rowFrameGeneration != sourceOrdinal {
            rowFrames = retainedFrames
            rowFrameOrder = retainedOrder
            rowFrameGeneration = sourceOrdinal
            if let pending = pendingRowFramesByGeneration.removeValue(forKey: sourceOrdinal) {
                for (id, frame) in pending {
                    admitCurrentRowFrame(id: id, frame: frame)
                }
            }
            pendingRowFramesByGeneration = pendingRowFramesByGeneration
                .filter { $0.key > sourceOrdinal }
        }
        installedProjectionRowCount = max(0, rowCount)
        revision &+= 1
    }

    var fixtureOpenPresentation: (() async throws -> Int)?

    func retirePresentation() {
        // The fixture open closure captures the mounted view and probe; retirement
        // must break that cycle, not merely stop observing.
        fixtureOpenPresentation = nil
        revision &+= 1
    }

    func markReady() {
        guard !isReady else { return }
        isReady = true
        revision &+= 1
    }
}
#endif
