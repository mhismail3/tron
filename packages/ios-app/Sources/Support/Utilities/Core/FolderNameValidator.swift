import Foundation

/// Validates folder names for the workspace selector folder creation feature.
/// Ensures names don't contain invalid characters and aren't hidden folders.
enum FolderNameValidator {
    /// Characters that are invalid in folder names (cross-platform safety)
    private static let invalidCharacters = CharacterSet(charactersIn: "<>:\"|?*")

    /// Checks if a folder name is valid
    /// - Parameter name: The folder name to validate
    /// - Returns: true if the name is valid, false otherwise
    static func isValid(_ name: String) -> Bool {
        return validationError(for: name) == nil
    }

    /// Returns an error message if the folder name is invalid, nil if valid
    /// - Parameter name: The folder name to validate
    /// - Returns: Error message string if invalid, nil if valid
    static func validationError(for name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check empty
        guard !trimmed.isEmpty else {
            return "Folder name cannot be empty"
        }

        // Check hidden (starts with .)
        guard !trimmed.hasPrefix(".") else {
            return "Hidden folders not allowed"
        }

        // Check for invalid characters
        if trimmed.rangeOfCharacter(from: invalidCharacters) != nil {
            return "Name contains invalid characters"
        }

        return nil
    }
}
