import Foundation
import TronMobileCore

enum SettingsScope: String, Hashable, Sendable {
    case global
    case project
}

enum SettingsTarget: Hashable, Sendable {
    case global
    case project(cwd: String)

    init?(scope: SettingsScope, projectCWD: String?) {
        switch scope {
        case .global:
            self = .global
        case .project:
            guard let projectCWD, !projectCWD.isEmpty else { return nil }
            self = .project(cwd: projectCWD)
        }
    }

    var scope: SettingsScope {
        switch self {
        case .global: .global
        case .project: .project
        }
    }

    var cwd: String? {
        switch self {
        case .global: nil
        case let .project(cwd): cwd
        }
    }
}

extension SettingsTarget {
    var writeLayer: String { scope == .global ? "global" : "project" }

    static func sessionGatewayTarget(_ sessionID: String) -> JSONValue {
        .object(["kind": .string("session"), "sessionId": .string(sessionID)])
    }

    var gatewayTarget: JSONValue {
        switch self {
        case .global: .object(["kind": .string("global")])
        case let .project(cwd): .object(["kind": .string("project"), "cwd": .string(cwd)])
        }
    }

    func keyChange(_ key: String, value: JSONValue?) -> JSONValue {
        var change: [String: JSONValue] = ["key": .string(key), "layer": .string(writeLayer)]
        if let value {
            change["op"] = .string("set")
            change["value"] = value
        } else {
            change["op"] = .string("unset")
        }
        return .object(change)
    }
}
