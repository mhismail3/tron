#if HOSTED_TEST
import SwiftUI

struct ChatHostedObservation: Sendable {
    let revision: Int
    let geometry: ChatTranscriptGeometry
    let visibleRowIDs: [String]
    let rowFrames: [String: CGRect]
    let isReady: Bool
}

@MainActor
final class ChatHostedProbe {
    private var geometry = ChatTranscriptGeometry.zero
    private var visibleRowIDs: [String] = []
    private var rowFrames: [String: CGRect] = [:]
    private var isReady = false
    private(set) var revision = 0

    var observation: ChatHostedObservation {
        ChatHostedObservation(
            revision: revision,
            geometry: geometry,
            visibleRowIDs: visibleRowIDs,
            rowFrames: rowFrames,
            isReady: isReady
        )
    }

    func updateGeometry(_ value: ChatTranscriptGeometry) {
        guard geometry != value else { return }
        geometry = value
        revision &+= 1
    }

    func updateVisibleRowIDs(_ value: [String]) {
        guard visibleRowIDs != value else { return }
        visibleRowIDs = value
        revision &+= 1
    }

    func updateRowFrame(id: String, frame: CGRect) {
        guard rowFrames[id] != frame else { return }
        rowFrames[id] = frame
        revision &+= 1
    }

    func markReady() {
        guard !isReady else { return }
        isReady = true
        revision &+= 1
    }
}
#endif
