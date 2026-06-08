import SwiftUI

// MARK: - File Display Helpers

/// Shared file metadata helpers for capability detail sheets (language colors, icons, sizing).
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
        return CGFloat(max(digits * 8, 14))
    }

    static func lineNumberWidth(lineCount: Int) -> CGFloat {
        let digits = String(lineCount).count
        return CGFloat(max(digits * 8, 14))
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
