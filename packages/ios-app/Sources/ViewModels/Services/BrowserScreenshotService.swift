import UIKit
import Foundation

/// Service for extracting browser screenshots from various sources.
/// Consolidates the 3 different screenshot extraction patterns used in event handling.
enum BrowserScreenshotService {

    /// Result of screenshot extraction
    struct ExtractionResult {
        let image: UIImage
        let source: Source

        enum Source: String {
            case eventDetails   // Full screenshot from event.details (preferred - untruncated)
            case textPattern    // Extracted via regex from text result
            case rawBase64      // Direct base64 decode from raw result
        }
    }

    // MARK: - Main Extraction Methods

    /// Extract screenshot from a ToolEndEvent.
    /// Prefers the full screenshot from event.details, falls back to parsing text output.
    /// - Parameter event: The tool end event to extract screenshot from
    /// - Returns: ExtractionResult if a screenshot was found, nil otherwise
    static func extractScreenshot(from event: ToolEndEvent) -> ExtractionResult? {
        // First, try to get the full screenshot from details (preferred - untruncated)
        if let image = extractFromEventDetails(event) {
            return ExtractionResult(image: image, source: .eventDetails)
        }

        // Fallback: try to extract from text result (may be truncated)
        if let image = extractFromTextResult(event.displayResult) {
            return image
        }

        // Final fallback: check if result is raw base64
        if let image = extractFromRawBase64(event.displayResult) {
            return ExtractionResult(image: image, source: .rawBase64)
        }

        return nil
    }

    /// Extract screenshot from event details (preferred method - untruncated).
    /// - Parameter event: The tool end event with potential details
    /// - Returns: UIImage if found in details, nil otherwise
    static func extractFromEventDetails(_ event: ToolEndEvent) -> UIImage? {
        guard let details = event.details,
              let screenshotBase64 = details.screenshot,
              let imageData = Data(base64Encoded: screenshotBase64),
              let image = UIImage(data: imageData) else {
            return nil
        }
        return image
    }

    /// Extract base64-encoded screenshot from text result using regex patterns.
    /// - Parameter result: The text result to search
    /// - Returns: ExtractionResult if found via pattern, nil otherwise
    static func extractFromTextResult(_ result: String) -> ExtractionResult? {
        // Look for base64 image data in the result
        // Format: "Screenshot captured (base64): iVBORw0KGgo..." or just raw base64
        let patterns = [
            "Screenshot captured \\(base64\\): ([A-Za-z0-9+/=]+)",
            "base64\\): ([A-Za-z0-9+/=]+)",
            "data:image/[^;]+;base64,([A-Za-z0-9+/=]+)"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: result, options: [], range: NSRange(result.startIndex..., in: result)),
               let range = Range(match.range(at: 1), in: result) {
                let base64String = String(result[range])

                // Decode base64 to image
                if let imageData = Data(base64Encoded: base64String),
                   let image = UIImage(data: imageData) {
                    return ExtractionResult(image: image, source: .textPattern)
                }
            }
        }

        return nil
    }

    /// Check if the result is raw base64 image data (PNG/JPEG magic bytes when decoded).
    /// - Parameter result: The text result to check
    /// - Returns: UIImage if result is valid raw base64 image, nil otherwise
    static func extractFromRawBase64(_ result: String) -> UIImage? {
        // PNG base64 starts with "iVBOR", JPEG starts with "/9j/"
        guard result.hasPrefix("iVBOR") || result.hasPrefix("/9j/") else {
            return nil
        }

        guard let imageData = Data(base64Encoded: result),
              let image = UIImage(data: imageData) else {
            return nil
        }

        return image
    }
}
