import SwiftUI

// MARK: - Find Result Viewer (also used for Glob)
// Shows a list of matched file paths

struct FindResultViewer: View {
    let pattern: String
    let result: String
    @Binding var isExpanded: Bool  // Kept for API compatibility, but unused

    private var files: [String] {
        result.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File count header
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.cyan)

                Text("\(files.count) files found")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.tronSurface)

            // File list - show all
            VStack(alignment: .leading, spacing: 0) {
                ForEach(files, id: \.self) { file in
                    HStack(spacing: 8) {
                        Image(systemName: fileIcon(for: file))
                            .font(TronTypography.codeSM)
                            .foregroundStyle(fileIconColor(for: file))
                            .frame(width: 14)

                        Text(file)
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func fileIcon(for path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "swift", "ts", "tsx", "js", "jsx", "py", "rs", "go":
            return "doc.text"
        case "json", "yaml", "yml", "xml":
            return "doc.badge.gearshape"
        case "md":
            return "doc.richtext"
        case "css", "scss":
            return "paintbrush"
        case "png", "jpg", "jpeg", "gif", "svg":
            return "photo"
        default:
            return "doc"
        }
    }

    private func fileIconColor(for path: String) -> Color {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "swift": return Color(hex: "#F05138")
        case "ts", "tsx": return Color(hex: "#3178C6")
        case "js", "jsx": return Color(hex: "#F7DF1E")
        case "py": return Color(hex: "#3776AB")
        default: return .tronTextMuted
        }
    }
}

// MARK: - Grep Result Viewer
// Shows search results - just displays raw lines cleanly

struct GrepResultViewer: View {
    let pattern: String
    let result: String
    @Binding var isExpanded: Bool  // Kept for API compatibility, but unused

    private var lines: [String] {
        result.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Match count header
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.purple)

                Text("\(lines.count) matches")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)

                if !pattern.isEmpty {
                    Text("for \"\(pattern)\"")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.tronSurface)

            // Results - show all
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronTextSecondary)
                            .frame(minHeight: 16, alignment: .leading)
                            .padding(.leading, 8)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Ls Result Viewer
// Shows directory listing with file details
// Supports both custom [D]/[F] format and standard ls -la format

struct LsResultViewer: View {
    let path: String
    let result: String
    @Binding var isExpanded: Bool  // Kept for API compatibility, but unused

    private var entries: [LsEntry] {
        result.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { parseLsEntry($0) }
    }

    /// Parse ls output line - handles both custom [D]/[F] format and standard ls -la
    private func parseLsEntry(_ line: String) -> LsEntry? {
        // Skip "total" line
        if line.hasPrefix("total") { return nil }

        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Try custom [D]/[F] format: [D]  128  Dec 27  2025  dirname/
        // or: [F]  601  Dec 27  2025  filename.ext
        if trimmed.hasPrefix("[D]") || trimmed.hasPrefix("[F]") {
            let isDir = trimmed.hasPrefix("[D]")
            let afterMarker = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let components = afterMarker.split(separator: " ", omittingEmptySubsequences: true)

            // Format: size month day year/time name
            if components.count >= 4 {
                let size = Int(components[0])
                // Name is everything after the date parts (month day year/time)
                let name = components.dropFirst(4).joined(separator: " ")
                if !name.isEmpty {
                    return LsEntry(name: name, isDirectory: isDir, size: size, dateStr: formatDateParts(Array(components[1..<4])))
                }
            }
            // Fallback: just extract the name (last component)
            if let lastName = components.last {
                return LsEntry(name: String(lastName), isDirectory: isDir, size: Int(components.first ?? ""), dateStr: nil)
            }
        }

        // Try standard ls -la format: drwxr-xr-x  5 user staff  160 Jan  4 10:00 name
        let components = line.split(separator: " ", omittingEmptySubsequences: true)
        if components.count >= 9 {
            let permissions = String(components[0])
            let isDir = permissions.hasPrefix("d")
            let size = Int(components[4])
            let name = components.dropFirst(8).joined(separator: " ")
            return LsEntry(name: name, isDirectory: isDir, size: size, dateStr: nil)
        }

        // Simple format - just the name
        return LsEntry(name: trimmed, isDirectory: trimmed.hasSuffix("/"), size: nil, dateStr: nil)
    }

    private func formatDateParts(_ parts: [String.SubSequence]) -> String? {
        guard parts.count >= 3 else { return nil }
        return parts.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "folder")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.yellow)

                Text("\(entries.count) items")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.tronSurface)

            // Directory listing - show all
            VStack(alignment: .leading, spacing: 0) {
                ForEach(entries, id: \.name) { entry in
                    HStack(spacing: 6) {
                        // Icon
                        Image(systemName: entry.isDirectory ? "folder.fill" : entryIcon(for: entry.name))
                            .font(TronTypography.codeSM)
                            .foregroundStyle(entry.isDirectory ? .yellow : entryIconColor(for: entry.name))
                            .frame(width: 14)

                        // Name (first, most prominent)
                        Text(entry.name)
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(entry.isDirectory ? .tronTextPrimary : .tronTextSecondary)
                            .lineLimit(1)

                        Spacer()

                        // Size
                        if let size = entry.size {
                            Text(formatSize(size))
                                .font(TronTypography.codeSM)
                                .foregroundStyle(.tronTextMuted)
                        }

                        // Date
                        if let dateStr = entry.dateStr {
                            Text(dateStr)
                                .font(TronTypography.codeSM)
                                .foregroundStyle(.tronTextMuted)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func entryIcon(for name: String) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        switch ext {
        case "swift", "ts", "tsx", "js", "jsx", "py", "rs", "go":
            return "doc.text"
        case "json", "yaml", "yml", "xml":
            return "doc.badge.gearshape"
        case "md":
            return "doc.richtext"
        case "css", "scss":
            return "paintbrush"
        case "png", "jpg", "jpeg", "gif", "svg":
            return "photo"
        case "sh":
            return "terminal"
        case "txt":
            return "doc.plaintext"
        default:
            return "doc"
        }
    }

    private func entryIconColor(for name: String) -> Color {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        switch ext {
        case "swift": return Color(hex: "#F05138")
        case "ts", "tsx": return Color(hex: "#3178C6")
        case "js", "jsx": return Color(hex: "#F7DF1E")
        case "py": return Color(hex: "#3776AB")
        case "sh": return .tronEmerald
        case "md": return Color(hex: "#083FA1")
        default: return .tronTextMuted
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024)K" }
        return "\(bytes / (1024 * 1024))M"
    }
}

/// Structured ls entry
private struct LsEntry: Identifiable {
    var id: String { name }
    let name: String
    let isDirectory: Bool
    let size: Int?
    let dateStr: String?
}
