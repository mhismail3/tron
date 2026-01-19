import Foundation

/// Progressive JSON parser for UICanvas component trees
/// Handles partial/truncated JSON during streaming
enum UICanvasParser {

    /// Parse a component tree from tool arguments JSON, attempting to recover from truncated input.
    /// The arguments JSON has structure: {"canvasId": "...", "ui": {...}, "state": {...}}
    /// This method extracts the "ui" field and parses it progressively.
    static func parseFromArguments(_ argumentsJson: String) -> UICanvasComponent? {
        // First, try to extract the "ui" field from the arguments
        guard let uiJson = extractUIField(from: argumentsJson) else {
            return nil
        }

        // Parse the extracted UI JSON progressively
        return parseProgressively(uiJson)
    }

    /// Extract the "ui" field value from tool arguments JSON.
    /// Handles truncated JSON by finding the "ui" key and extracting its value.
    private static func extractUIField(from argumentsJson: String) -> String? {
        // Look for "ui": or "ui" : pattern to find the start of the ui field
        guard let uiKeyRange = argumentsJson.range(of: #""ui"\s*:\s*"#, options: .regularExpression) else {
            return nil
        }

        // Get everything after "ui":
        let afterUiKey = String(argumentsJson[uiKeyRange.upperBound...])

        // The ui value should start with { - find it
        guard let startIndex = afterUiKey.firstIndex(of: "{") else {
            return nil
        }

        // Extract from the opening brace to the end
        let uiValueStart = String(afterUiKey[startIndex...])

        // Now we need to find the matching closing brace, accounting for nested structures
        var braceCount = 0
        var bracketCount = 0
        var inString = false
        var escape = false
        var endIndex: String.Index?

        for (offset, char) in uiValueStart.enumerated() {
            if escape {
                escape = false
                continue
            }

            if char == "\\" && inString {
                escape = true
                continue
            }

            if char == "\"" {
                inString.toggle()
                continue
            }

            if inString {
                continue
            }

            switch char {
            case "{":
                braceCount += 1
            case "}":
                braceCount -= 1
                if braceCount == 0 {
                    // Found the matching closing brace
                    endIndex = uiValueStart.index(uiValueStart.startIndex, offsetBy: offset)
                }
            case "[":
                bracketCount += 1
            case "]":
                bracketCount -= 1
            default:
                break
            }

            if let end = endIndex {
                // Include the closing brace
                let endInclusive = uiValueStart.index(after: end)
                return String(uiValueStart[..<endInclusive])
            }
        }

        // If we didn't find a matching close, return everything we have (truncated)
        // This will be handled by parseProgressively's recovery logic
        return uiValueStart
    }

    /// Parse a component tree from JSON, attempting to recover from truncated input
    static func parseProgressively(_ json: String) -> UICanvasComponent? {
        // First try parsing as-is (fastest path for complete JSON)
        if let component = parse(json) {
            return component
        }

        // Try to complete truncated JSON by closing open braces/brackets
        let completed = completeTruncatedJSON(json)
        if let component = parse(completed) {
            return component
        }

        // Try more aggressive recovery strategies
        if let recovered = recoverTruncatedJSON(json),
           let component = parse(recovered) {
            return component
        }

        return nil
    }

    /// Parse complete JSON string into component tree
    static func parse(_ json: String) -> UICanvasComponent? {
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        return parse(data)
    }

    /// Parse complete JSON data into component tree
    static func parse(_ data: Data) -> UICanvasComponent? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return UICanvasComponent.decode(from: dict)
    }

    /// Parse a dictionary (from tool arguments) into component tree
    static func parse(_ dict: [String: Any]) -> UICanvasComponent? {
        return UICanvasComponent.decode(from: dict)
    }

    /// Attempt to complete truncated JSON by closing open structures
    private static func completeTruncatedJSON(_ json: String) -> String {
        var stack: [Character] = []
        var inString = false
        var escape = false
        var lastNonWhitespace: Character?

        for char in json {
            if escape {
                escape = false
                continue
            }

            if char == "\\" && inString {
                escape = true
                continue
            }

            if char == "\"" {
                inString.toggle()
                lastNonWhitespace = char
                continue
            }

            if inString {
                continue
            }

            if !char.isWhitespace {
                lastNonWhitespace = char
            }

            switch char {
            case "{":
                stack.append("}")
            case "[":
                stack.append("]")
            case "}":
                if stack.last == "}" {
                    stack.removeLast()
                }
            case "]":
                if stack.last == "]" {
                    stack.removeLast()
                }
            default:
                break
            }
        }

        var completed = json

        // If we're in a string, close it first
        if inString {
            completed += "\""
            lastNonWhitespace = "\""
        }

        // Handle trailing commas before closing brackets
        // If the last character is a comma, we need to remove it or add a null value
        if let last = lastNonWhitespace, last == "," {
            // Remove trailing comma
            if let range = completed.range(of: ",", options: .backwards) {
                completed.removeSubrange(range)
            }
        }

        // Handle partial property names (e.g., {"type": "vstack", "chi)
        // If we have an unclosed colon, add a null value
        if let last = lastNonWhitespace, last == ":" {
            completed += "null"
        }

        // Close any unclosed structures
        while let closer = stack.popLast() {
            completed += String(closer)
        }

        return completed
    }

    /// More aggressive recovery for badly truncated JSON
    private static func recoverTruncatedJSON(_ json: String) -> String? {
        // Strategy: Find the last valid JSON object/array boundary and truncate there

        var stack: [Character] = []
        var inString = false
        var escape = false
        var lastValidIndex: String.Index?

        for (offset, char) in json.enumerated() {
            let index = json.index(json.startIndex, offsetBy: offset)

            if escape {
                escape = false
                continue
            }

            if char == "\\" && inString {
                escape = true
                continue
            }

            if char == "\"" {
                inString.toggle()
                continue
            }

            if inString {
                continue
            }

            switch char {
            case "{":
                stack.append("}")
            case "[":
                stack.append("]")
            case "}":
                if stack.last == "}" {
                    stack.removeLast()
                    // This is a potential valid ending point
                    if stack.isEmpty || stack.last == "]" || stack.last == "}" {
                        lastValidIndex = index
                    }
                }
            case "]":
                if stack.last == "]" {
                    stack.removeLast()
                    if stack.isEmpty || stack.last == "]" || stack.last == "}" {
                        lastValidIndex = index
                    }
                }
            default:
                break
            }
        }

        // If we found a valid boundary, try parsing up to there
        if let validIndex = lastValidIndex {
            let truncated = String(json[...validIndex])
            // Complete any remaining structure
            return completeTruncatedJSON(truncated)
        }

        return nil
    }
}
