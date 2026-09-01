import Foundation

/// The result of validating the bounded transcript carried by one authority
/// frame. A frame is either complete enough to install, or it remains outside
/// the mounted authority until a fresh snapshot repairs the gap.
enum SessionTranscriptWindowAdmission: Equatable, Sendable {
    case accepted
    case rejected(Reason)

    enum Reason: Equatable, Sendable {
        case negativeStart
        case missingBounds
        case totalBeforeEnd
        case countExceedsLimit
        case duplicateOrEmptyID
        case nonMonotonicTotal
        case gap
        case conflictingOverlap
    }

    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

enum SessionTranscriptWindowAdmissionPolicy {
    /// Validates both the shape of an authority transcript and, when a prior
    /// frame exists in the same runtime, its canonical-window evolution.
    /// Legacy snapshots with no bounds remain admissible; partially bounded
    /// snapshots are rejected because their ordinals cannot be trusted.
    static func evaluate(
        current: SessionSnapshot?,
        incoming: SessionSnapshot
    ) -> SessionTranscriptWindowAdmission {
        guard admitsShape(incoming) else {
            return .rejected(shapeReason(for: incoming))
        }
        guard let current else { return .accepted }
        guard current.sessionId == incoming.sessionId,
              current.runtimeGeneration == incoming.runtimeGeneration else {
            return .accepted
        }
        guard admitsShape(current) else {
            // The existing frame is already outside the contract. Do not
            // allow it to make a valid authority frame look incompatible.
            return .accepted
        }
        guard let oldWindow = window(for: current),
              let newWindow = window(for: incoming) else {
            // Both snapshots are legacy/unbounded. There is no ordinal claim
            // to compare, so cursor admission remains the authority fence.
            return .accepted
        }
        guard newWindow.total >= oldWindow.total else {
            return .rejected(.nonMonotonicTotal)
        }

        let overlapStart = max(oldWindow.start, newWindow.start)
        let overlapEnd = min(oldWindow.end, newWindow.end)
        let adjacentAppend = newWindow.start == oldWindow.end
            && (newWindow.total > oldWindow.total || oldWindow.ids.isEmpty)
        guard adjacentAppend || (overlapStart < overlapEnd) else {
            return .rejected(.gap)
        }
        guard overlapStart >= oldWindow.start,
              overlapEnd <= oldWindow.end,
              overlapStart >= newWindow.start,
              overlapEnd <= newWindow.end else {
            return .rejected(.conflictingOverlap)
        }
        if overlapStart < overlapEnd {
            for ordinal in overlapStart..<overlapEnd {
                let oldID = oldWindow.ids[ordinal - oldWindow.start]
                let newID = newWindow.ids[ordinal - newWindow.start]
                guard oldID == newID else {
                    return .rejected(.conflictingOverlap)
                }
            }
        }
        return .accepted
    }

    static func admitsShape(_ snapshot: SessionSnapshot) -> Bool {
        guard snapshot.transcript.count <= SessionSnapshot.maximumTranscriptItems else {
            return false
        }
        let ids = snapshot.transcript.map(\.id)
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
            return false
        }
        switch (snapshot.transcriptStart, snapshot.transcriptTotal) {
        case (nil, nil):
            return true
        case let (start?, total?):
            guard start >= 0, total >= start else { return false }
            let (end, overflow) = start.addingReportingOverflow(snapshot.transcript.count)
            return !overflow && end <= total
        default:
            return false
        }
    }

    private static func shapeReason(for snapshot: SessionSnapshot) -> SessionTranscriptWindowAdmission.Reason {
        if snapshot.transcript.count > SessionSnapshot.maximumTranscriptItems {
            return .countExceedsLimit
        }
        let ids = snapshot.transcript.map(\.id)
        if ids.contains(where: { $0.isEmpty }) || Set(ids).count != ids.count {
            return .duplicateOrEmptyID
        }
        switch (snapshot.transcriptStart, snapshot.transcriptTotal) {
        case (nil, nil): return .missingBounds
        case (nil, _), (_, nil): return .missingBounds
        case let (start?, total?):
            if start < 0 { return .negativeStart }
            if total < start { return .totalBeforeEnd }
            let (end, overflow) = start.addingReportingOverflow(snapshot.transcript.count)
            if overflow || end > total { return .totalBeforeEnd }
        }
        return .missingBounds
    }

    private struct Window {
        let start: Int
        let end: Int
        let total: Int
        let ids: [String]
    }

    private static func window(for snapshot: SessionSnapshot) -> Window? {
        guard let start = snapshot.transcriptStart,
              let total = snapshot.transcriptTotal else { return nil }
        return Window(
            start: start,
            end: start + snapshot.transcript.count,
            total: total,
            ids: snapshot.transcript.map(\.id)
        )
    }
}
