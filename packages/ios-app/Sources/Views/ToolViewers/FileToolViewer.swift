import SwiftUI

// MARK: - Read Result Viewer

struct ReadResultViewer: View {
    let filePath: String
    let content: String

    private var parsedLines: [ContentLineParser.ParsedLine] {
        ContentLineParser.parse(content)
    }

    private var fileExtension: String {
        URL(fileURLWithPath: filePath).pathExtension.uppercased()
    }

    private var fileName: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }

    private var languageColor: Color {
        switch fileExtension.lowercased() {
        case "swift": return Color(hex: "#F05138")
        case "ts", "tsx": return Color(hex: "#3178C6")
        case "js", "jsx": return Color(hex: "#F7DF1E")
        case "py": return Color(hex: "#3776AB")
        case "rs": return Color(hex: "#CE412B")
        case "go": return Color(hex: "#00ADD8")
        case "md": return Color(hex: "#083FA1")
        case "json": return Color(hex: "#F5A623")
        case "css", "scss": return Color(hex: "#264DE4")
        case "yaml", "yml": return Color(hex: "#CB171E")
        default: return .tronEmerald
        }
    }

    /// Calculate optimal width for line numbers based on max line number
    private var lineNumWidth: CGFloat {
        let maxNum = parsedLines.last?.lineNum ?? parsedLines.count
        let digits = String(maxNum).count
        return CGFloat(max(digits * 8, 14))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File info header
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(languageColor)

                Text(fileName)
                    .font(TronTypography.filePath)
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(1)

                if !fileExtension.isEmpty {
                    Text(fileExtension)
                        .font(TronTypography.pill)
                        .foregroundStyle(.tronTextMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tronSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                Spacer()

                Text("\(parsedLines.count) lines")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.tronSurface)

            // Content lines - show all
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(parsedLines) { line in
                        HStack(spacing: 0) {
                            // Line number
                            Text("\(line.lineNum)")
                                .font(TronTypography.code(size: TronTypography.sizeSM, weight: .medium))
                                .foregroundStyle(.tronTextMuted.opacity(0.4))
                                .frame(width: lineNumWidth, alignment: .trailing)
                                .padding(.trailing, 8)

                            // Line content (cleaned)
                            Text(line.content.isEmpty ? " " : line.content)
                                .font(TronTypography.codeContent)
                                .foregroundStyle(.tronTextSecondary)
                        }
                        .frame(minHeight: 16)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }
}

// MARK: - Write Result Viewer

struct WriteResultViewer: View {
    let filePath: String
    let content: String
    let result: String

    private var contentLines: [String] {
        content.components(separatedBy: "\n")
    }

    private var hasContent: Bool {
        !content.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Success message
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronSuccess)

                Text(result)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Content preview - show all
            if hasContent {
                VStack(alignment: .leading, spacing: 0) {
                    // Divider
                    Rectangle()
                        .fill(Color.tronBorder.opacity(0.3))
                        .frame(height: 0.5)

                    // Content
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(contentLines.enumerated()), id: \.offset) { index, line in
                                HStack(spacing: 0) {
                                    Text("\(index + 1)")
                                        .font(TronTypography.code(size: TronTypography.sizeSM, weight: .medium))
                                        .foregroundStyle(.tronTextMuted.opacity(0.4))
                                        .frame(width: 16, alignment: .trailing)
                                        .padding(.trailing, 8)

                                    Text(line.isEmpty ? " " : line)
                                        .font(TronTypography.codeSM)
                                        .foregroundStyle(.tronTextMuted)
                                }
                                .frame(minHeight: 15)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}

// MARK: - Edit Result Viewer (Diff)

struct EditResultViewer: View {
    let filePath: String
    let result: String
    let details: [String: AnyCodable]?

    private typealias Line = (type: DiffLineType, content: String, oldNum: Int?, newNum: Int?)

    /// Whether structured diff lines are available from server details.
    private var hasDiffFormat: Bool {
        !diffLines.isEmpty
    }

    private var diffStats: (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in diffLines {
            switch line.type {
            case .addition: added += 1
            case .deletion: removed += 1
            default: break
            }
        }
        return (added, removed)
    }

    private var diffLines: [Line] {
        guard let raw = details?["diffLines"]?.value as? [[String: Any]] else {
            return []
        }
        var out: [Line] = []
        for entry in raw {
            guard let type = entry["type"] as? String else { continue }
            switch type {
            case "hunk_header":
                out.append((.hunk, "", nil, nil))
            case "context":
                let content = (entry["content"] as? String) ?? ""
                let oldLine = readLine(entry, "oldLine")
                let newLine = readLine(entry, "newLine")
                out.append((.context, content, oldLine, newLine))
            case "addition":
                let content = (entry["content"] as? String) ?? ""
                let newLine = readLine(entry, "newLine")
                out.append((.addition, content, nil, newLine))
            case "deletion":
                let content = (entry["content"] as? String) ?? ""
                let oldLine = readLine(entry, "oldLine")
                out.append((.deletion, content, oldLine, nil))
            default:
                break
            }
        }
        return out
    }

    private func readLine(_ entry: [String: Any], _ key: String) -> Int? {
        if let i = entry[key] as? Int { return i }
        if let d = entry[key] as? Double { return Int(d) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File info header with stats
            HStack(spacing: 8) {
                Text(URL(fileURLWithPath: filePath).lastPathComponent)
                    .font(TronTypography.filePath)
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(1)

                Spacer()

                // Stats badges
                if diffStats.added > 0 {
                    Text("+\(diffStats.added)")
                        .font(TronTypography.pillValue)
                        .foregroundStyle(.tronSuccess)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tronSuccess.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                if diffStats.removed > 0 {
                    Text("-\(diffStats.removed)")
                        .font(TronTypography.pillValue)
                        .foregroundStyle(.tronError)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tronError.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.tronSurface)

            // Show diff if available, otherwise show the raw result
            if hasDiffFormat && !diffLines.isEmpty {
                // Diff lines - show all
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                            DiffLineView(
                                type: line.type,
                                content: line.content,
                                oldLineNum: line.oldNum,
                                newLineNum: line.newNum
                            )
                        }
                    }
                }
            } else if !result.isEmpty {
                // Fallback: show raw result text
                Text(result)
                    .font(TronTypography.codeContent)
                    .foregroundStyle(.tronTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Diff Line Types

enum DiffLineType {
    case context
    case addition
    case deletion
    case hunk
}

struct DiffLineView: View {
    let type: DiffLineType
    let content: String
    let oldLineNum: Int?
    let newLineNum: Int?

    /// Show the relevant line number (new for additions, old for deletions)
    private var displayLineNum: String {
        if let num = newLineNum ?? oldLineNum {
            return String(num)
        }
        return ""
    }

    var body: some View {
        HStack(spacing: 0) {
            // Line number
            Text(displayLineNum)
                .font(TronTypography.code(size: TronTypography.sizeSM, weight: .medium))
                .foregroundStyle(lineNumColor.opacity(0.6))
                .frame(width: 20, alignment: .trailing)
                .padding(.trailing, 6)
                .background(lineNumBackground)

            // Marker
            Text(marker)
                .font(TronTypography.code(size: TronTypography.sizeBody2, weight: .semibold))
                .foregroundStyle(markerColor)
                .frame(width: 12)

            // Content
            Text(content.isEmpty ? " " : content)
                .font(TronTypography.codeContent)
                .foregroundStyle(contentColor)
        }
        .frame(minHeight: 16)
        .background(lineBackground)
    }

    private var marker: String {
        switch type {
        case .addition: return "+"
        case .deletion: return "-"
        case .hunk: return ""
        case .context: return ""
        }
    }

    private var lineBackground: Color {
        switch type {
        case .addition: return Color.tronSuccess.opacity(0.1)
        case .deletion: return Color.tronError.opacity(0.1)
        case .hunk: return Color.tronSurface
        case .context: return Color.clear
        }
    }

    private var lineNumBackground: Color {
        switch type {
        case .addition: return Color.tronSuccess.opacity(0.08)
        case .deletion: return Color.tronError.opacity(0.08)
        default: return Color.tronSurface
        }
    }

    private var lineNumColor: Color {
        switch type {
        case .addition: return .tronSuccess
        case .deletion: return .tronError
        default: return .tronTextMuted
        }
    }

    private var markerColor: Color {
        switch type {
        case .addition: return .tronSuccess
        case .deletion: return .tronError
        default: return .tronTextMuted
        }
    }

    private var contentColor: Color {
        switch type {
        case .hunk: return .tronEmerald
        default: return .tronTextPrimary
        }
    }
}
