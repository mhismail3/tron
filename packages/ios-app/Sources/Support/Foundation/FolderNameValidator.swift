import Foundation

/// Validates one folder-name segment for the workspace selector.
enum FolderNameValidator {
    static func isValid(_ name: String) -> Bool {
        return validationError(for: name) == nil
    }

    static func validationError(for name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return "Folder name cannot be empty"
        }
        guard trimmed != ".", trimmed != ".." else {
            return "Folder name cannot be \(trimmed)"
        }
        guard !trimmed.contains("/") else {
            return "Folder name cannot contain /"
        }

        return nil
    }
}
