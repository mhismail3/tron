import SwiftUI

// MARK: - File Info Properties

/// Extracts and caches the 4 computed file properties duplicated across Read, Write, and Edit sheets.
/// Construct once from the tool arguments string, then pass to `ToolFileInfoSection`.
struct FileInfoProperties {
    let filePath: String
    let fileName: String
    let fileExtension: String
    var langColor: Color { FileDisplayHelpers.languageColor(for: fileExtension) }

    init(arguments: String) {
        self.filePath = ToolArgumentParser.filePath(from: arguments)
        self.fileName = filePath.isEmpty ? "" : URL(fileURLWithPath: filePath).lastPathComponent
        self.fileExtension = filePath.isEmpty ? "" : URL(fileURLWithPath: filePath).pathExtension.lowercased()
    }
}
