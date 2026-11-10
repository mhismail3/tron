import SwiftUI

enum TronDisclosureDirection: Equatable {
    case collapse
    case expand
}

struct TronDisclosureTransition: Equatable {
    let groupID: String
    let direction: TronDisclosureDirection
    let generation: Int
}

struct TronDisclosureState: Equatable {
    private enum Phase: Equatable {
        case expanded
        case collapsing
        case collapsed
        case expanding
    }

    private var phaseByGroupID: [String: Phase] = [:]
    private var generationByGroupID: [String: Int] = [:]

    func isExpanded(_ groupID: String) -> Bool {
        switch phaseByGroupID[groupID] ?? .expanded {
        case .expanded, .expanding:
            true
        case .collapsing, .collapsed:
            false
        }
    }

    func shouldRenderRows(_ groupID: String) -> Bool {
        phaseByGroupID[groupID] != .collapsed
    }

    func areRowsVisible(_ groupID: String) -> Bool {
        phaseByGroupID[groupID] == .expanded || phaseByGroupID[groupID] == nil
    }

    func toggleDirection(for groupID: String) -> TronDisclosureDirection {
        isExpanded(groupID) ? .collapse : .expand
    }

    mutating func beginToggle(_ groupID: String) -> TronDisclosureTransition {
        let direction = toggleDirection(for: groupID)
        let generation = (generationByGroupID[groupID] ?? 0) + 1
        generationByGroupID[groupID] = generation
        phaseByGroupID[groupID] = direction == .collapse ? .collapsing : .expanding
        return TronDisclosureTransition(
            groupID: groupID,
            direction: direction,
            generation: generation
        )
    }

    @discardableResult
    mutating func complete(_ transition: TronDisclosureTransition) -> Bool {
        guard generationByGroupID[transition.groupID] == transition.generation else { return false }
        phaseByGroupID[transition.groupID] = transition.direction == .collapse ? .collapsed : .expanded
        return true
    }

    mutating func reconcile(groupIDs: Set<String>) {
        phaseByGroupID = phaseByGroupID.filter { groupIDs.contains($0.key) }
        generationByGroupID = generationByGroupID.filter { groupIDs.contains($0.key) }
    }
}

enum TronDisclosureLayout {
    static let expansionAnimation = Animation.smooth(duration: 0.18)
    static let contentAnimation = Animation.smooth(duration: 0.34)
}

struct TronDisclosureChevron: View {
    let isExpanded: Bool
    var size: CGFloat = 10
    var animation: Animation = TronDisclosureLayout.expansionAnimation

    var body: some View {
        Image(systemName: "chevron.right")
            .font(TronTypography.sans(size: size, weight: .bold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(animation, value: isExpanded)
    }
}
