import SwiftUI

/// Diff line type classifications for unified diff rendering.
enum EditDiffLineType {
    case context
    case addition
    case deletion
    case separator
}

/// Shared diff line styling helpers.
/// Shared diff formatting for source changes and generated capability results.
enum DiffFormatting {

    static func marker(for type: EditDiffLineType) -> String {
        switch type {
        case .addition: return "+"
        case .deletion: return "\u{2212}"
        case .context, .separator: return ""
        }
    }

    static func markerColor(for type: EditDiffLineType) -> Color {
        switch type {
        case .addition: return .tronSuccess
        case .deletion: return .tronError
        case .context, .separator: return .clear
        }
    }

    static func lineNumColor(for type: EditDiffLineType) -> Color {
        switch type {
        case .addition: return .tronSuccess
        case .deletion: return .tronError
        case .context, .separator: return .tronTextMuted
        }
    }

    static func lineBackground(for type: EditDiffLineType) -> Color {
        switch type {
        case .addition: return Color.tronSuccess.opacity(0.08)
        case .deletion: return Color.tronError.opacity(0.08)
        case .context, .separator: return .clear
        }
    }
}

enum SourceDiffParser {
    static func parse(from diff: String) -> [SourceDiffLine] {
        var lines: [SourceDiffLine] = []
        var oldLineNum = 0
        var newLineNum = 0
        var index = 0
        var inDiff = false

        for rawLine in diff.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("@@") {
                inDiff = true
                if let match = rawLine.firstMatch(of: /@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/) {
                    oldLineNum = Int(match.1) ?? 0
                    newLineNum = Int(match.2) ?? 0
                }
                if !lines.isEmpty {
                    lines.append(SourceDiffLine(id: index, type: .separator, content: "", lineNum: nil))
                    index += 1
                }
            } else if rawLine.hasPrefix("+") && !rawLine.hasPrefix("+++") {
                lines.append(SourceDiffLine(id: index, type: .addition, content: String(rawLine.dropFirst()), lineNum: newLineNum))
                newLineNum += 1
                index += 1
            } else if rawLine.hasPrefix("-") && !rawLine.hasPrefix("---") {
                lines.append(SourceDiffLine(id: index, type: .deletion, content: String(rawLine.dropFirst()), lineNum: oldLineNum))
                oldLineNum += 1
                index += 1
            } else if inDiff && !rawLine.hasPrefix("+++") && !rawLine.hasPrefix("---") {
                let content = rawLine.hasPrefix(" ") ? String(rawLine.dropFirst()) : rawLine
                lines.append(SourceDiffLine(id: index, type: .context, content: content, lineNum: newLineNum))
                oldLineNum += 1
                newLineNum += 1
                index += 1
            }
        }
        return lines
    }

    static func lineNumberWidth(for lines: [SourceDiffLine]) -> CGFloat {
        let maxNum = lines.compactMap(\.lineNum).max() ?? 0
        let digits = max(String(maxNum).count, 1)
        return CGFloat(max(digits * 8, 14))
    }
}

struct SourceDiffLine: Identifiable {
    let id: Int
    let type: EditDiffLineType
    let content: String
    let lineNum: Int?
}
