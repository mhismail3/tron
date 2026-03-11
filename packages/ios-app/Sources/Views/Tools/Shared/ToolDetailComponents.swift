import SwiftUI

// MARK: - Shared Tool Detail Components (iOS 26 Liquid Glass)

/// Glass container with section header outside, matching SkillDetailSheet pattern.
/// Reusable across all tool detail sheets.
@available(iOS 26.0, *)
struct ToolDetailSection<Trailing: View, Content: View>: View {
    let title: String
    var accent: Color = .tronSlate
    var tint: TintedColors
    var trailing: Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.heading)

                Spacer()

                trailing
            }

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(accent.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

@available(iOS 26.0, *)
extension ToolDetailSection where Trailing == EmptyView {
    init(title: String, accent: Color = .tronSlate, tint: TintedColors, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accent = accent
        self.tint = tint
        self.trailing = EmptyView()
        self.content = content
    }
}

// MARK: - Status Badge

/// Glass pill for tool status (completed/running/failed)
@available(iOS 26.0, *)
struct ToolStatusBadge: View {
    let status: CommandToolStatus

    private var statusColor: Color {
        switch status {
        case .running: return .tronAmber
        case .success: return .tronSuccess
        case .error: return .tronError
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if status == .running {
                ProgressView()
                    .scaleEffect(0.55)
                    .tint(statusColor)
            } else {
                Image(systemName: status.iconName)
                    .font(TronTypography.sans(size: TronTypography.sizeBody2))
                    .foregroundStyle(statusColor)
            }
            Text(status.label)
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.tint(statusColor.opacity(0.25)), in: Capsule())
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Duration Badge

/// Glass pill with clock icon + formatted duration
@available(iOS 26.0, *)
struct ToolDurationBadge: View {
    let durationMs: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(TronTypography.sans(size: TronTypography.sizeBody2))
            Text(DurationFormatter.format(durationMs, style: .compact))
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
        }
        .foregroundStyle(.tronTextMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.tint(Color.tronSlate.opacity(0.15)), in: Capsule())
        }
    }
}

// MARK: - Info Pill

/// Generic glass pill (icon + label + color), reusable for line counts, truncation, etc.
@available(iOS 26.0, *)
struct ToolInfoPill: View {
    let icon: String
    let label: String
    var color: Color = .tronSlate

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
            Text(label)
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.tint(color.opacity(0.2)), in: Capsule())
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Running Spinner

/// Shared spinner for tool detail sheets in "running" state.
/// Eliminates the duplicated ProgressView + label pattern across 10 tool sheets.
@available(iOS 26.0, *)
struct ToolRunningSpinner: View {
    let title: String
    let accent: Color
    let tint: TintedColors
    let actionText: String

    var body: some View {
        ToolDetailSection(title: title, accent: accent, tint: tint) {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(accent)
                    .scaleEffect(1.1)
                Text(actionText)
                    .font(TronTypography.mono(size: TronTypography.sizeBody))
                    .foregroundStyle(tint.subtle)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }
}

// MARK: - Status Row

/// Shared status row with horizontal scroll of pills: status badge + optional duration + additional pills.
/// Eliminates the duplicated ScrollView + HStack + badges pattern across 10 tool sheets.
@available(iOS 26.0, *)
struct ToolStatusRow<AdditionalPills: View>: View {
    let status: CommandToolStatus
    let durationMs: Int?
    @ViewBuilder let additionalPills: () -> AdditionalPills

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ToolStatusBadge(status: status)
                if let ms = durationMs {
                    ToolDurationBadge(durationMs: ms)
                }
                additionalPills()
            }
        }
    }
}

@available(iOS 26.0, *)
extension ToolStatusRow where AdditionalPills == EmptyView {
    init(status: CommandToolStatus, durationMs: Int?) {
        self.status = status
        self.durationMs = durationMs
        self.additionalPills = { EmptyView() }
    }
}

// MARK: - Error View

// MARK: - File Display Helpers

/// Shared file metadata helpers for tool detail sheets (language colors, icons, sizing).
enum FileDisplayHelpers {

    static func languageColor(for ext: String) -> Color {
        switch ext.lowercased() {
        case "swift": return Color(hex: "#F05138")
        case "ts", "tsx": return Color(hex: "#3178C6")
        case "js", "jsx": return Color(hex: "#F7DF1E")
        case "py": return Color(hex: "#3776AB")
        case "rs": return Color(hex: "#CE412B")
        case "go": return Color(hex: "#00ADD8")
        case "md", "markdown": return Color(hex: "#083FA1")
        case "json": return Color(hex: "#F5A623")
        case "css", "scss": return Color(hex: "#264DE4")
        case "yaml", "yml": return Color(hex: "#CB171E")
        case "html", "htm": return Color(hex: "#E44D26")
        case "rb": return Color(hex: "#CC342D")
        case "java": return Color(hex: "#B07219")
        case "kt": return Color(hex: "#A97BFF")
        case "c", "h": return Color(hex: "#555555")
        case "cpp", "cc", "hpp": return Color(hex: "#F34B7D")
        case "sh", "bash", "zsh": return Color(hex: "#89E051")
        case "toml": return Color(hex: "#9C4221")
        case "xml": return Color(hex: "#0060AC")
        case "sql": return Color(hex: "#E38C00")
        default: return .tronSlate
        }
    }

    static func fileIcon(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown": return "doc.text"
        case "json": return "curlybraces"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "ts", "tsx", "js", "jsx": return "chevron.left.forwardslash.chevron.right"
        case "swift": return "swift"
        case "sh", "bash", "zsh": return "terminal"
        case "yml", "yaml": return "list.bullet"
        case "rs": return "gearshape"
        case "go": return "chevron.left.forwardslash.chevron.right"
        case "html", "htm": return "globe"
        case "css", "scss": return "paintbrush"
        case "sql": return "cylinder"
        case "xml": return "chevron.left.forwardslash.chevron.right"
        case "toml": return "list.bullet"
        case "txt": return "doc.plaintext"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }

    static func lineNumberWidth(for lines: [ContentLineParser.ParsedLine]) -> CGFloat {
        let maxNum = lines.last?.lineNum ?? lines.count
        let digits = String(maxNum).count
        return CGFloat(max(digits * 8, 16))
    }

    static func lineNumberWidth(lineCount: Int) -> CGFloat {
        let digits = String(lineCount).count
        return CGFloat(max(digits * 8, 16))
    }

    static func formattedSize(_ byteCount: Int) -> String {
        if byteCount < 1024 {
            return "\(byteCount) B"
        } else if byteCount < 1024 * 1024 {
            return String(format: "%.1f KB", Double(byteCount) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(byteCount) / (1024.0 * 1024.0))
        }
    }
}

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

// MARK: - Error Classification

/// Structured error classification returned by tool-specific error classifiers.
struct ErrorClassification {
    let icon: String
    let title: String
    let code: String?
    let suggestion: String
}

/// Protocol for tool-specific error classifiers.
/// Each tool's detail parser conforms with its own domain-specific matching logic.
protocol ErrorClassifying {
    static func classify(_ message: String) -> ErrorClassification
}

// MARK: - Classified Error Section

/// Shared error section that uses `ErrorClassification` to render structured error UI.
/// Replaces the duplicated error section pattern across WebFetch, WebSearch, Remember, and OpenURL sheets.
@available(iOS 26.0, *)
struct ToolClassifiedErrorSection<AdditionalContent: View>: View {
    let errorMessage: String
    let classification: ErrorClassification
    let colorScheme: ColorScheme
    @ViewBuilder let additionalContent: () -> AdditionalContent

    var body: some View {
        let errorTint = TintedColors(accent: .tronError, colorScheme: colorScheme)

        ToolDetailSection(title: "Error", accent: .tronError, tint: errorTint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: classification.icon)
                        .font(TronTypography.sans(size: TronTypography.sizeXL))
                        .foregroundStyle(.tronError)

                    Text(classification.title)
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronError)
                }

                additionalContent()

                if let code = classification.code {
                    ToolInfoPill(icon: "exclamationmark.triangle", label: code, color: .tronError)
                }

                Text(classification.suggestion)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(errorTint.subtle)
            }
        }
    }
}

@available(iOS 26.0, *)
extension ToolClassifiedErrorSection where AdditionalContent == EmptyView {
    init(errorMessage: String, classification: ErrorClassification, colorScheme: ColorScheme) {
        self.errorMessage = errorMessage
        self.classification = classification
        self.colorScheme = colorScheme
        self.additionalContent = { EmptyView() }
    }
}

// MARK: - Error View

/// Structured error display with icon, title, path, error code badge, and suggestion
@available(iOS 26.0, *)
struct ToolErrorView: View {
    let icon: String
    let title: String
    let path: String
    let errorCode: String?
    let suggestion: String
    var tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeXL))
                    .foregroundStyle(.tronError)

                Text(title)
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronError)
            }

            if !path.isEmpty {
                Text(path)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(tint.secondary)
                    .textSelection(.enabled)
            }

            if let code = errorCode {
                ToolInfoPill(icon: "exclamationmark.triangle", label: code, color: .tronError)
            }

            Text(suggestion)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(tint.subtle)
        }
    }
}
