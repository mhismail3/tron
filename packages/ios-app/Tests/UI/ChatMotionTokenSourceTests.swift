import Foundation
import Testing

@Suite("Chat motion token source contract")
struct ChatMotionTokenSourceTests {
    @Test("chat-owned Swift files use the motion vocabulary")
    func noInlineMotionCurves() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/UI/Chat")
        let tokenFile = "ChatMotion.swift"
        let outOfScopeFiles: [String: String] = [
            "ArchivedSessionsSection.swift": "session-shell archived list, not chat motion",
            "NewSessionSheet.swift": "session creation sheet, not chat motion",
            "SessionProcessSheets.swift": "session process sheet, not chat motion",
            "SessionShellView.swift": "session shell and dashboard, not chat motion",
            "SessionTreeSheet.swift": "session-list tree sheet, not chat motion",
            "WorkspaceInspectorSheet.swift": "session workspace sheet, not chat motion"
        ]
        let patterns = [
            #"ChatMotion\.\w+\(\s*duration\s*:\s*[0-9]"#,
            #"(?<!ChatMotion)\.(smooth|spring|snappy|bouncy|interpolatingSpring|interactiveSpring|timingCurve|easeInOut|easeIn|easeOut|linear)\("#,
            #"Animation\(\s*[0-9]"#,
            #"Animation\.(smooth|spring|snappy|easeInOut|easeIn|easeOut|linear|interpolatingSpring|interactiveSpring|timingCurve|bouncy)\("#
        ]
        #expect(outOfScopeFiles.values.allSatisfy { !$0.isEmpty })
        let regexes = try patterns.map { try NSRegularExpression(pattern: $0) }
        let enumCasePattern = try NSRegularExpression(
            pattern: #"(?m)^\s*case\s+(?:let\s+)?\.[A-Za-z_]\w*(?:\([^\n)]*\))?"#
        )
        let enumerator = try #require(FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))
        let chatFiles = enumerator.compactMap { $0 as? URL }.filter { file in
            guard file.pathExtension == "swift" else { return false }
            let relativePath = String(file.path.dropFirst(sourceRoot.path.count + 1))
            return relativePath != tokenFile && outOfScopeFiles[relativePath] == nil
        }
        let sharedChatFiles = [sourceRoot.deletingLastPathComponent()
            .appending(path: "Components/ProcessActivityOrb.swift")]
        let files = chatFiles + sharedChatFiles
        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
            let scanSource = enumCasePattern.stringByReplacingMatches(
                in: source,
                range: sourceRange,
                withTemplate: ""
            )
            let range = NSRange(scanSource.startIndex..<scanSource.endIndex, in: scanSource)
            let matches = regexes.flatMap { $0.matches(in: scanSource, range: range) }
            for match in matches {
                guard let swiftRange = Range(match.range, in: scanSource) else { continue }
                let line = scanSource[..<swiftRange.lowerBound].filter { $0 == "\n" }.count + 1
                offenders.append("\(file.lastPathComponent):\(line): \(scanSource[swiftRange])")
            }
        }
        #expect(offenders.isEmpty, "Inline chat motion curves:\n\(offenders.sorted().joined(separator: "\n"))")
    }
}
