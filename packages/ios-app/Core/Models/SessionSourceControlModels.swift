import Foundation

package enum SessionSourceControlMode: String, Codable, CaseIterable, Equatable, Sendable {
    case existingCheckout
    case newBranchWorktree
    case existingBranchWorktree

    package var title: String {
        switch self {
        case .existingCheckout: "Use Existing Checkout"
        case .newBranchWorktree: "New Worktree · New Branch"
        case .existingBranchWorktree: "New Worktree · Existing Branch"
        }
    }

    package var summary: String {
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

package struct SessionSourceControlSelection: Codable, Equatable, Sendable {
    package var mode: SessionSourceControlMode
    package var branch: String?
    package var base: String?

    package static let existing = Self(mode: .existingCheckout, branch: nil, base: nil)

    package var displayName: String {
        switch mode {
        case .existingCheckout: "Use Existing"
        case .newBranchWorktree: "New Worktree"
        case .existingBranchWorktree: branch?.isEmpty == false ? "Worktree · \(branch!)" : "Existing Branch"
        }
    }

    package var displayDescription: String {
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

    package func isAdmissible(for inspection: GitInspection?) -> Bool {
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

    package init(mode: SessionSourceControlMode, branch: String? = nil, base: String? = nil) {
        self.mode = mode
        self.branch = branch
        self.base = base
    }
}

package struct GitInspection: Equatable, Sendable {
    package let isRepository: Bool
    package let branch: String?
    package let isDirty: Bool
    package var branches: [Branch] = []
    package var commits: [Commit] = []

    package struct Branch: Equatable, Sendable, Identifiable {
        package let name: String
        package let checkedOut: Bool

        package init(name: String, checkedOut: Bool) {
            self.name = name
            self.checkedOut = checkedOut
        }
        package var id: String { name }
    }

    package struct Commit: Equatable, Sendable, Identifiable {
        package let oid: String
        package let subject: String

        package init(oid: String, subject: String) {
            self.oid = oid
            self.subject = subject
        }
        package var id: String { oid }
    }

    package init(isRepository: Bool, branch: String?, isDirty: Bool, branches: [Branch] = [], commits: [Commit] = []) {
        self.isRepository = isRepository
        self.branch = branch
        self.isDirty = isDirty
        self.branches = branches
        self.commits = commits
    }
}
