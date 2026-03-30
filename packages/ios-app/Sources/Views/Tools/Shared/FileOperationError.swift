import Foundation

// MARK: - File Operation Error

/// Unified error classifier for file operations (read, write, edit).
/// Replaces the former ReadError and FileWriteError enums.
enum FileOperationError {
    case fileNotFound(path: String)
    case permissionDenied(path: String)
    case directoryNotFound(path: String)
    case isDirectory(path: String)
    case diskFull
    case invalidPath
    case generic(message: String, operation: Operation)

    enum Operation: String {
        case read = "Read"
        case write = "Write"
    }

    static func parse(from result: String, operation: Operation = .write) -> FileOperationError {
        // "File not found:" is a read-specific prefix — map to .fileNotFound
        if result.contains("File not found:") || result.contains("file not found") {
            let path = extractPath(from: result, prefix: "File not found:")
            return .fileNotFound(path: path)
        }
        if result.contains("Permission denied") || result.contains("permission denied") || result.contains("EACCES") {
            let path = extractPath(from: result, prefix: "Permission denied:")
            return .permissionDenied(path: path)
        }
        if result.contains("is a directory") || result.contains("EISDIR") {
            let path = extractPath(from: result, prefix: "Path is a directory, not a file:")
                .isEmpty ? extractPath(from: result, prefix: "EISDIR:") : extractPath(from: result, prefix: "Path is a directory, not a file:")
            return .isDirectory(path: path)
        }
        // "directory does not exist" or bare ENOENT (without "File not found") → directoryNotFound
        if result.contains("no such file or directory") || result.contains("ENOENT") || result.contains("directory does not exist") {
            let path = extractPath(from: result, prefix: "ENOENT:")
            return .directoryNotFound(path: path)
        }
        if result.contains("ENOSPC") || result.contains("No space left") || result.contains("disk full") {
            return .diskFull
        }
        if result.contains("Missing required parameter") || result.contains("Invalid") && result.contains("path") {
            return .invalidPath
        }
        return .generic(message: result, operation: operation)
    }

    var title: String {
        switch self {
        case .fileNotFound: return "File Not Found"
        case .permissionDenied: return "Permission Denied"
        case .directoryNotFound: return "Directory Not Found"
        case .isDirectory: return "Path Is a Directory"
        case .diskFull: return "Disk Full"
        case .invalidPath: return "Invalid Path"
        case .generic(_, let operation): return "\(operation.rawValue) Error"
        }
    }

    var icon: String {
        switch self {
        case .fileNotFound: return "questionmark.folder"
        case .permissionDenied: return "lock.fill"
        case .directoryNotFound: return "questionmark.folder"
        case .isDirectory: return "folder.fill"
        case .diskFull: return "externaldrive.fill.badge.xmark"
        case .invalidPath: return "exclamationmark.triangle.fill"
        case .generic: return "exclamationmark.triangle.fill"
        }
    }

    var errorCode: String? {
        switch self {
        case .fileNotFound: return "ENOENT"
        case .permissionDenied: return "EACCES"
        case .directoryNotFound: return "ENOENT"
        case .isDirectory: return "EISDIR"
        case .diskFull: return "ENOSPC"
        case .invalidPath: return nil
        case .generic: return nil
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
        case .diskFull:
            return "There is not enough disk space to complete the write."
        case .invalidPath:
            return "The file path parameter is missing or invalid."
        case .generic:
            return "An unexpected error occurred during the file operation."
        }
    }

    private static func extractPath(from result: String, prefix: String) -> String {
        if let range = result.range(of: prefix) {
            return result[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
}
