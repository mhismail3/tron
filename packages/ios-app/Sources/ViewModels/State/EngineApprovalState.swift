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
    var currentData: EngineApprovalData?

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

    /// Clear the open sheet if it is showing the approval that just reached a
    /// terminal engine state.
    func clearSheetIfShowingApproval(_ approvalId: String) {
        guard currentData?.engineApprovalId == approvalId
            || currentData?.invocationId == "engine-approval:\(approvalId)"
        else {
            return
        }
        showSheet = false
        currentData = nil
        pendingSubmission = nil
    }
}
