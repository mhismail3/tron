import Foundation

// MARK: - File Operation Error

/// Structured error classification for file operations (Read, Write, Edit).
///
/// Reads `tool.details.errorClass` + `tool.details.error` + `tool.details.path`
/// directly — never scans error message text. The server
/// (`packages/agent/src/tools/utils/fs_errors.rs`) populates these fields for
/// every fs-tool failure.
enum FileOperationError {
    case fileNotFound(path: String)
    case permissionDenied(path: String)
    case directoryNotFound(path: String)
    case isDirectory(path: String)
    case diskFull
    case tooLarge(path: String)
    case invalidPath
    case binaryFile(path: String)
    case emptyPattern
    case identicalStrings
    case patternNotFound(path: String)
    case multipleOccurrences(path: String, count: Int)
    case notADirectory(path: String)
    case generic(message: String, operation: Operation)

    enum Operation: String {
        case read = "Read"
        case write = "Write"
        case edit = "Edit"
    }

    /// Build a FileOperationError from server-provided tool details.
    /// Falls back to `.generic` when `details` is absent or carries an
    /// unknown `errorClass`.
    static func from(
        details: [String: AnyCodable]?,
        result: String?,
        operation: Operation = .write
    ) -> FileOperationError {
        let errorClass = details?["errorClass"]?.value as? String
        let path = (details?["path"]?.value as? String) ?? ""
        let message = (details?["error"]?.value as? String) ?? (result ?? "")

        switch errorClass {
        case "not_found":
            return .fileNotFound(path: path)
        case "permission_denied":
            return .permissionDenied(path: path)
        case "is_a_directory":
            return .isDirectory(path: path)
        case "not_a_directory":
            return .notADirectory(path: path)
        case "disk_full":
            return .diskFull
        case "too_large":
            return .tooLarge(path: path)
        case "invalid_path":
            return .invalidPath
        case "binary":
            return .binaryFile(path: path)
        case "empty_pattern":
            return .emptyPattern
        case "identical_strings":
            return .identicalStrings
        case "pattern_not_found":
            return .patternNotFound(path: path)
        case "multiple_occurrences":
            let count: Int = {
                if let c = details?["occurrences"]?.value as? Int { return c }
                if let c = details?["occurrences"]?.value as? Double { return Int(c) }
                return 0
            }()
            return .multipleOccurrences(path: path, count: count)
        default:
            return .generic(message: message, operation: operation)
        }
    }

    var title: String {
        switch self {
        case .fileNotFound: return "File Not Found"
        case .permissionDenied: return "Permission Denied"
        case .directoryNotFound: return "Directory Not Found"
        case .isDirectory: return "Path Is a Directory"
        case .notADirectory: return "Not a Directory"
        case .diskFull: return "Disk Full"
        case .tooLarge: return "File Too Large"
        case .invalidPath: return "Invalid Path"
        case .binaryFile: return "Binary File"
        case .emptyPattern: return "Empty Pattern"
        case .identicalStrings: return "No Change"
        case .patternNotFound: return "Pattern Not Found"
        case .multipleOccurrences: return "Multiple Matches"
        case .generic(_, let operation): return "\(operation.rawValue) Error"
        }
    }

    var icon: String {
        switch self {
        case .fileNotFound: return "questionmark.folder"
        case .permissionDenied: return "lock.fill"
        case .directoryNotFound: return "questionmark.folder"
        case .isDirectory: return "folder.fill"
        case .notADirectory: return "doc"
        case .diskFull: return "externaldrive.fill.badge.xmark"
        case .tooLarge: return "scalemass"
        case .invalidPath: return "exclamationmark.triangle.fill"
        case .binaryFile: return "doc.badge.ellipsis"
        case .emptyPattern, .identicalStrings: return "text.badge.xmark"
        case .patternNotFound: return "text.magnifyingglass"
        case .multipleOccurrences: return "arrow.2.squarepath"
        case .generic: return "exclamationmark.triangle.fill"
        }
    }

    var errorCode: String? {
        switch self {
        case .fileNotFound: return "ENOENT"
        case .permissionDenied: return "EACCES"
        case .directoryNotFound: return "ENOENT"
        case .isDirectory: return "EISDIR"
        case .notADirectory: return "ENOTDIR"
        case .diskFull: return "ENOSPC"
        default: return nil
        }
    }

    var suggestion: String {
        switch self {
        case .fileNotFound:
            return "Check that the file path is correct and the file exists."
        case .permissionDenied:
            return "The process does not have permission to access this location."
        case .directoryNotFound:
            return "The parent directory does not exist. Create it first."
        case .isDirectory:
            return "This path points to a directory, not a file."
        case .notADirectory:
            return "A component in the path is not a directory."
        case .diskFull:
            return "There is not enough disk space to complete the write."
        case .tooLarge:
            return "The file exceeds the maximum allowed size."
        case .invalidPath:
            return "The file path parameter is missing or invalid."
        case .binaryFile:
            return "The file is binary and cannot be read as text."
        case .emptyPattern:
            return "old_string cannot be empty."
        case .identicalStrings:
            return "old_string and new_string are the same — no changes would be made."
        case .patternNotFound:
            return "old_string was not found in the file. Make it exactly match the file content."
        case .multipleOccurrences(_, let count) where count > 0:
            return "Found \(count) occurrences. Pass replace_all: true to replace them all, or make old_string more specific."
        case .multipleOccurrences:
            return "Pass replace_all: true to replace them all, or make old_string more specific."
        case .generic:
            return "An unexpected error occurred during the file operation."
        }
    }
}
