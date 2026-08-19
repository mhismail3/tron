import Foundation

enum SessionSourceControlMode: String, Codable, CaseIterable, Equatable, Sendable {
    case existingCheckout
    case newBranchWorktree
    case existingBranchWorktree

    var title: String {
        switch self {
        case .existingCheckout: "Use Existing Checkout"
        case .newBranchWorktree: "New Worktree · New Branch"
        case .existingBranchWorktree: "New Worktree · Existing Branch"
        }
    }

    var summary: String {
        switch self {
        case .existingCheckout: "Use the selected checkout at its current commit."
        case .newBranchWorktree: "Create an isolated worktree and branch from the selected commit."
        case .existingBranchWorktree: "Create an isolated worktree from an existing local branch."
        }
    }

    var requiresBranch: Bool {
        self != .existingCheckout
    }
}

struct SessionSourceControlSelection: Codable, Equatable, Sendable {
    var mode: SessionSourceControlMode
    var branch: String?
    var base: String?

    static let existing = Self(mode: .existingCheckout, branch: nil, base: nil)

    var displayName: String {
        switch mode {
        case .existingCheckout: "Use Existing"
        case .newBranchWorktree: "New Worktree"
        case .existingBranchWorktree: branch?.isEmpty == false ? "Worktree · \(branch!)" : "Existing Branch"
        }
    }

    var displayDescription: String {
        switch mode {
        case .existingCheckout:
            return mode.summary
        case .newBranchWorktree:
            if let branch, !branch.isEmpty {
                let base = base?.isEmpty == false ? " from \(base!)" : " from current commit"
                return "\(branch)\(base)"
            }
            return mode.summary
        case .existingBranchWorktree:
            return branch?.isEmpty == false ? "Attach a new worktree to \(branch!)" : mode.summary
        }
    }

    func isAdmissible(for inspection: GitInspection?) -> Bool {
        guard mode != .existingCheckout else { return true }
        guard let inspection, inspection.isRepository else { return false }
        guard let branch, Self.isValidBranchField(branch) else { return false }
        switch mode {
        case .existingCheckout:
            return true
        case .newBranchWorktree:
            guard base?.isEmpty != false || Self.isValidBranchField(base ?? "") else { return false }
            return base?.isEmpty == false || !inspection.isDirty
        case .existingBranchWorktree:
            return branch != inspection.branch
        }
    }

    private static func isValidBranchField(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= 255 && !trimmed.contains(where: { $0.isWhitespace })
    }
}
