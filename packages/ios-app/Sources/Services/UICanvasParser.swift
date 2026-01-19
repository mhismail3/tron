import Foundation

/// Progressive JSON parser for UICanvas component trees
/// Handles partial/truncated JSON during streaming
enum UICanvasParser {

    /// Parse a component tree from JSON, attempting to recover from truncated input
    static func parseProgressively(_ json: String) -> UICanvasComponent? {
        // First try parsing as-is
        if let component = parse(json) {
            return component
        }

        // Try to complete truncated JSON by closing open braces/brackets
        let completed = completeTruncatedJSON(json)
        if let component = parse(completed) {
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
                }
            case "]":
                if stack.last == "]" {
                    stack.removeLast()
                }
            default:
                break
            }
        }

        // If we're in a string, close it first
        var completed = json
        if inString {
            completed += "\""
        }

        // Close any unclosed structures
        while let closer = stack.popLast() {
            completed += String(closer)
        }

        return completed
    }
}
