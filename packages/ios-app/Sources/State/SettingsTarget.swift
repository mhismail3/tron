import Foundation
import TronMobileCore

enum SettingsTarget: Hashable, Sendable {
    case global

    static func sessionGatewayTarget(_ sessionID: String) -> JSONValue {
        .object(["kind": .string("session"), "sessionId": .string(sessionID)])
    }

    var gatewayTarget: JSONValue { .object(["kind": .string("global")]) }

    func keyChange(_ key: String, value: JSONValue?) -> JSONValue {
        var change: [String: JSONValue] = ["key": .string(key), "layer": .string("global")]
        if let value {
            change["op"] = .string("set")
            change["value"] = value
        } else {
            change["op"] = .string("unset")
        }
        return .object(change)
    }
}
