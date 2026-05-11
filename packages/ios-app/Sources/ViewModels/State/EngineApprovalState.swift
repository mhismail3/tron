import SwiftUI

struct PendingEngineApprovalSubmission {
    let action: String
    let decision: String
    let note: String?
    let engineApprovalId: String?
    let engineFunctionId: String?
}

/// Manages engine-owned approval sheet state for ChatViewModel.
@Observable
@MainActor
final class EngineApprovalState {
    /// Whether to show the engine approval sheet.
    var showSheet = false

    /// Current engine approval chip data when the sheet is open.
    var currentData: EngineApprovalToolData?

    /// Pending approval submission to send after sheet dismissal completes.
    /// Set during prepareSubmission(), consumed by executePendingSubmission().
    var pendingSubmission: PendingEngineApprovalSubmission?

    init() {}

    /// Clear all engine approval sheet state.
    func clearAll() {
        showSheet = false
        currentData = nil
        pendingSubmission = nil
    }
}
