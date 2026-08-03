import Foundation

/// Closed wire contract between the ordinary `mac-operator` worker and the
/// signed Mac wrapper. The contract contains only observation and actuation
/// mechanics; desired outcomes, planning, recovery, and confirmation policy
/// remain worker-owned.
struct MacOperatorRequest: Equatable, Sendable {
    let requestID: String
    let timeoutMilliseconds: Int
    let action: MacOperatorAction
}

enum MacOperatorAction: Equatable, Sendable {
    case status
    case applications
    case observe(bundleIdentifier: String)
    case screenshot(bundleIdentifier: String, observationID: String)
    case press(bundleIdentifier: String, observationID: String, elementReference: String)
    case setValue(
        bundleIdentifier: String,
        observationID: String,
        elementReference: String,
        text: String
    )
    case key(bundleIdentifier: String, observationID: String, key: MacOperatorKey)
    case scroll(bundleIdentifier: String, observationID: String, deltaX: Int, deltaY: Int)
    case coordinateClick(
        bundleIdentifier: String,
        observationID: String,
        screenshotID: String,
        normalizedX: Double,
        normalizedY: Double
    )

    var kind: String {
        switch self {
        case .status: "status"
        case .applications: "applications"
        case .observe: "observe"
        case .screenshot: "screenshot"
        case .press: "press"
        case .setValue: "set_value"
        case .key: "key"
        case .scroll: "scroll"
        case .coordinateClick: "coordinate_click"
        }
    }
}

enum MacOperatorKey: String, CaseIterable, Equatable, Sendable {
    case enter = "Enter"
    case tab = "Tab"
    case escape = "Escape"
    case arrowUp = "ArrowUp"
    case arrowDown = "ArrowDown"
    case arrowLeft = "ArrowLeft"
    case arrowRight = "ArrowRight"
    case pageUp = "PageUp"
    case pageDown = "PageDown"
    case home = "Home"
    case end = "End"
    case backspace = "Backspace"
    case delete = "Delete"
    case space = "Space"
}

enum MacOperatorProtocolError: Error, Equatable, Sendable {
    case invalidJSON
    case invalidShape
    case invalidField(String)
    case oversized

    var code: String {
        switch self {
        case .invalidJSON: "invalid_json"
        case .invalidShape: "invalid_request_shape"
        case .invalidField: "invalid_request_field"
        case .oversized: "request_oversized"
        }
    }
}

enum MacOperatorProtocol {
    static let maximumRequestBytes = 64 * 1_024
    static let maximumResponseBytes = 3 * 1_024 * 1_024
    static let minimumTimeoutMilliseconds = 500
    static let maximumTimeoutMilliseconds = 20_000

    static func decodeRequest(_ data: Data) throws -> MacOperatorRequest {
        guard !data.isEmpty, data.count <= maximumRequestBytes else {
            throw MacOperatorProtocolError.oversized
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MacOperatorProtocolError.invalidJSON
        }
        guard let root = raw as? [String: Any],
              Set(root.keys) == ["requestId", "timeoutMs", "action"],
              let requestID = root["requestId"] as? String,
              let timeout = root["timeoutMs"] as? Int,
              let action = root["action"] as? [String: Any]
        else {
            throw MacOperatorProtocolError.invalidShape
        }
        try validateIdentifier(requestID, name: "requestId", maximumBytes: 96)
        guard (minimumTimeoutMilliseconds...maximumTimeoutMilliseconds).contains(timeout) else {
            throw MacOperatorProtocolError.invalidField("timeoutMs")
        }
        return MacOperatorRequest(
            requestID: requestID,
            timeoutMilliseconds: timeout,
            action: try decodeAction(action)
        )
    }

    static func successData(requestID: String, result: [String: Any]) -> Data {
        responseData([
            "requestId": requestID,
            "ok": true,
            "result": result,
        ])
    }

    static func failureData(requestID: String, code: String) -> Data {
        responseData([
            "requestId": requestID,
            "ok": false,
            "error": sanitize(code, maximumCharacters: 96),
        ])
    }

    private static func decodeAction(_ raw: [String: Any]) throws -> MacOperatorAction {
        guard let kind = raw["kind"] as? String else {
            throw MacOperatorProtocolError.invalidField("action.kind")
        }
        switch kind {
        case "status":
            try requireKeys(raw, exactly: ["kind"])
            return .status
        case "applications":
            try requireKeys(raw, exactly: ["kind"])
            return .applications
        case "observe":
            try requireKeys(raw, exactly: ["kind", "bundleId"])
            return .observe(bundleIdentifier: try bundleIdentifier(raw))
        case "screenshot":
            try requireKeys(raw, exactly: ["kind", "bundleId", "observationId"])
            return .screenshot(
                bundleIdentifier: try bundleIdentifier(raw),
                observationID: try identifier(raw, key: "observationId", maximumBytes: 96)
            )
        case "press":
            try requireKeys(
                raw,
                exactly: ["kind", "bundleId", "observationId", "elementRef"]
            )
            return .press(
                bundleIdentifier: try bundleIdentifier(raw),
                observationID: try identifier(raw, key: "observationId", maximumBytes: 96),
                elementReference: try identifier(raw, key: "elementRef", maximumBytes: 96)
            )
        case "set_value":
            try requireKeys(
                raw,
                exactly: ["kind", "bundleId", "observationId", "elementRef", "text"]
            )
            guard let text = raw["text"] as? String,
                  !text.utf8.isEmpty,
                  text.utf8.count <= 4_000
            else {
                throw MacOperatorProtocolError.invalidField("action.text")
            }
            return .setValue(
                bundleIdentifier: try bundleIdentifier(raw),
                observationID: try identifier(raw, key: "observationId", maximumBytes: 96),
                elementReference: try identifier(raw, key: "elementRef", maximumBytes: 96),
                text: text
            )
        case "key":
            try requireKeys(raw, exactly: ["kind", "bundleId", "observationId", "key"])
            guard let rawKey = raw["key"] as? String,
                  let key = MacOperatorKey(rawValue: rawKey)
            else {
                throw MacOperatorProtocolError.invalidField("action.key")
            }
            return .key(
                bundleIdentifier: try bundleIdentifier(raw),
                observationID: try identifier(raw, key: "observationId", maximumBytes: 96),
                key: key
            )
        case "scroll":
            try requireKeys(
                raw,
                exactly: ["kind", "bundleId", "observationId", "deltaX", "deltaY"]
            )
            guard let deltaX = raw["deltaX"] as? Int,
                  let deltaY = raw["deltaY"] as? Int,
                  deltaX != 0 || deltaY != 0,
                  (-2_000...2_000).contains(deltaX),
                  (-2_000...2_000).contains(deltaY)
            else {
                throw MacOperatorProtocolError.invalidField("action.scrollDelta")
            }
            return .scroll(
                bundleIdentifier: try bundleIdentifier(raw),
                observationID: try identifier(raw, key: "observationId", maximumBytes: 96),
                deltaX: deltaX,
                deltaY: deltaY
            )
        case "coordinate_click":
            try requireKeys(
                raw,
                exactly: [
                    "kind",
                    "bundleId",
                    "observationId",
                    "screenshotId",
                    "normalizedX",
                    "normalizedY",
                ]
            )
            guard let x = number(raw["normalizedX"]),
                  let y = number(raw["normalizedY"]),
                  (0...1).contains(x),
                  (0...1).contains(y)
            else {
                throw MacOperatorProtocolError.invalidField("action.normalizedCoordinate")
            }
            return .coordinateClick(
                bundleIdentifier: try bundleIdentifier(raw),
                observationID: try identifier(raw, key: "observationId", maximumBytes: 96),
                screenshotID: try identifier(raw, key: "screenshotId", maximumBytes: 96),
                normalizedX: x,
                normalizedY: y
            )
        default:
            throw MacOperatorProtocolError.invalidField("action.kind")
        }
    }

    private static func bundleIdentifier(_ raw: [String: Any]) throws -> String {
        let value = try identifier(raw, key: "bundleId", maximumBytes: 255)
        guard value.contains("."),
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
              })
        else {
            throw MacOperatorProtocolError.invalidField("action.bundleId")
        }
        return value
    }

    private static func identifier(
        _ raw: [String: Any],
        key: String,
        maximumBytes: Int
    ) throws -> String {
        guard let value = raw[key] as? String else {
            throw MacOperatorProtocolError.invalidField("action.\(key)")
        }
        try validateIdentifier(value, name: "action.\(key)", maximumBytes: maximumBytes)
        return value
    }

    private static func validateIdentifier(
        _ value: String,
        name: String,
        maximumBytes: Int
    ) throws {
        guard !value.utf8.isEmpty,
              value.utf8.count <= maximumBytes,
              value.utf8.allSatisfy({
                  $0 < 128 && (
                      Character(UnicodeScalar($0)).isLetter
                          || Character(UnicodeScalar($0)).isNumber
                          || [45, 46, 58, 95].contains($0)
                  )
              })
        else {
            throw MacOperatorProtocolError.invalidField(name)
        }
    }

    private static func requireKeys(_ raw: [String: Any], exactly keys: Set<String>) throws {
        guard Set(raw.keys) == keys else {
            throw MacOperatorProtocolError.invalidShape
        }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        return number.doubleValue
    }

    private static func responseData(_ value: [String: Any]) -> Data {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              data.count <= maximumResponseBytes
        else {
            return Data(#"{"requestId":"unknown","ok":false,"error":"response_oversized"}"#.utf8)
        }
        return data
    }

    static func sanitize(_ value: String, maximumCharacters: Int) -> String {
        String(
            value.unicodeScalars
                .filter { !CharacterSet.controlCharacters.contains($0) }
                .prefix(maximumCharacters)
                .map(Character.init)
        )
    }
}
