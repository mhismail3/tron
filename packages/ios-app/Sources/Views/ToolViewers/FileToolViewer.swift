import SwiftUI

// MARK: - Read Result Viewer

struct ReadResultViewer: View {
    let filePath: String
    let content: String
    @Binding var isExpanded: Bool

    private var parsedLines: [ContentLineParser.ParsedLine] {
        ContentLineParser.parse(content)
    }

    private var displayLines: [ContentLineParser.ParsedLine] {
        isExpanded ? parsedLines : Array(parsedLines.prefix(12))
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
        return CGFloat(max(digits * 8, 16)) // ~8pt per digit, min 16pt
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
            .overlay(
                Rectangle()
                    .fill(languageColor)
                    .frame(width: 3),
                alignment: .leading
            )

            // Content lines
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(displayLines) { line in
                        HStack(spacing: 0) {
                            // Line number
                            Text("\(line.lineNum)")
                                .font(TronTypography.pill)
                                .foregroundStyle(.tronTextMuted.opacity(0.4))
                                .frame(width: lineNumWidth, alignment: .trailing)
                                .padding(.leading, 4)
                                .padding(.trailing, 8)

                            // Line content (cleaned)
                            Text(line.content.isEmpty ? " " : line.content)
                                .font(TronTypography.codeCaption)
                                .foregroundStyle(.tronTextSecondary)
                        }
                        .frame(minHeight: 16)
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(maxHeight: isExpanded ? .infinity : 200)

            // Expand/collapse button
            if parsedLines.count > 12 {
                Button {
                    withAnimation(.tronFast) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Text(isExpanded ? "Show less" : "Show more")
                            .font(TronTypography.codeCaption)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(TronTypography.codeSM)
                    }
                    .foregroundStyle(.tronTextMuted)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(Color.tronSurface)
                }
            }
        }
    }
}

// MARK: - Write Result Viewer

struct WriteResultViewer: View {
    let filePath: String
    let content: String
    let result: String
    @State private var isExpanded = false

    private var contentLines: [String] {
        content.components(separatedBy: "\n")
    }

    private var displayLines: [String] {
        isExpanded ? contentLines : Array(contentLines.prefix(6))
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

            // Content preview (expandable)
            if hasContent {
                VStack(alignment: .leading, spacing: 0) {
                    // Divider
                    Rectangle()
                        .fill(Color.tronBorder.opacity(0.3))
                        .frame(height: 0.5)

                    // Content preview
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(displayLines.enumerated()), id: \.offset) { index, line in
                                HStack(spacing: 0) {
                                    Text("\(index + 1)")
                                        .font(TronTypography.pill)
                                        .foregroundStyle(.tronTextMuted.opacity(0.4))
                                        .frame(width: 16, alignment: .trailing)
                                        .padding(.leading, 4)
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
                    .frame(maxHeight: isExpanded ? .infinity : 100)

                    // Expand/collapse button
                    if contentLines.count > 6 {
                        Button {
                            withAnimation(.tronFast) {
                                isExpanded.toggle()
                            }
                        } label: {
                            HStack {
                                Text(isExpanded ? "Hide content" : "Show all \(contentLines.count) lines")
                                    .font(TronTypography.codeSM)
                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(TronTypography.pill)
                            }
                            .foregroundStyle(.tronTextMuted)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background(Color.tronSurface)
                        }
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
    @Binding var isExpanded: Bool

    /// Check if result contains a proper diff format
    private var hasDiffFormat: Bool {
        result.contains("@@") && (result.contains("-") || result.contains("+"))
    }

    /// Extract the success message if present (e.g., "Successfully replaced 1 occurrence...")
    private var successMessage: String? {
        let lines = result.components(separatedBy: "\n")
        if let firstLine = lines.first,
           firstLine.contains("Successfully") || firstLine.contains("successfully") {
            return firstLine
        }
        return nil
    }

    private var diffStats: (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in result.components(separatedBy: "\n") {
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                added += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                removed += 1
            }
        }
        return (added, removed)
    }

    private var diffLines: [(type: DiffLineType, content: String, oldNum: Int?, newNum: Int?)] {
        var lines: [(type: DiffLineType, content: String, oldNum: Int?, newNum: Int?)] = []
        var oldLineNum = 0
        var newLineNum = 0
        var inDiff = false

        for line in result.components(separatedBy: "\n") {
            // Skip the "Successfully replaced..." line
            if line.contains("Successfully") || line.contains("successfully") {
                continue
            }

            if line.hasPrefix("@@") {
                inDiff = true
                // Parse hunk header for line numbers
                if let match = line.firstMatch(of: /@@ -(\d+),?\d* \+(\d+),?\d* @@/) {
                    oldLineNum = Int(match.1) ?? 0
                    newLineNum = Int(match.2) ?? 0
                }
                lines.append((.hunk, line, nil, nil))
            } else if line.hasPrefix("+") && !line.hasPrefix("+++") {
                lines.append((.addition, String(line.dropFirst()), nil, newLineNum))
                newLineNum += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                lines.append((.deletion, String(line.dropFirst()), oldLineNum, nil))
                oldLineNum += 1
            } else if inDiff && !line.hasPrefix("+++") && !line.hasPrefix("---") && !line.isEmpty {
                let content = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                lines.append((.context, content, oldLineNum, newLineNum))
                oldLineNum += 1
                newLineNum += 1
            }
        }
        return lines
    }

    private var displayLines: [(type: DiffLineType, content: String, oldNum: Int?, newNum: Int?)] {
        isExpanded ? diffLines : Array(diffLines.prefix(15))
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
                // Diff lines
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
                            DiffLineView(
                                type: line.type,
                                content: line.content,
                                oldLineNum: line.oldNum,
                                newLineNum: line.newNum
                            )
                        }
                    }
                }
                .frame(maxHeight: isExpanded ? .infinity : 280)

                // Expand/collapse button
                if diffLines.count > 15 {
                    Button {
                        withAnimation(.tronFast) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            Text(isExpanded ? "Show less" : "Show more")
                                .font(TronTypography.codeCaption)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(TronTypography.codeSM)
                        }
                        .foregroundStyle(.tronTextMuted)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(Color.tronSurface)
                    }
                }
            } else if !result.isEmpty {
                // Fallback: show raw result text
                Text(result)
                    .font(TronTypography.codeCaption)
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
                .font(TronTypography.pill)
                .foregroundStyle(lineNumColor.opacity(0.6))
                .frame(width: 20, alignment: .trailing)
                .padding(.leading, 4)
                .padding(.trailing, 6)
                .background(lineNumBackground)

            // Marker
            Text(marker)
                .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .semibold))
                .foregroundStyle(markerColor)
                .frame(width: 12)

            // Content
            Text(content.isEmpty ? " " : content)
                .font(TronTypography.codeCaption)
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
