#if HOSTED_TEST
import Foundation
import TronMobileCore

enum HostedManageSessionReview {
    static var enabled: Bool { HostedLaunch.arguments.contains("-manage-session-review") }

    static var contextUsage: ContextUsage? {
        guard enabled else { return nil }
        return try? JSONDecoder.gateway.decode(ContextUsage.self, from: Data(#"{"tokens":311000,"contextWindow":1000000,"percent":31.1}"#.utf8))
    }

    static func handles(_ method: String) -> Bool {
        ["session.workspace.inspect",
         "git.inspect", "trust.inspect"].contains(method)
    }

    static func response(_ method: String) -> JSONValue {
        switch method {
        case "session.workspace.inspect":
            return .object(["root": .string("/workspace"), "revision": .string("fixture-revision"),
                "repository": .object(["root": .string("/workspace"), "branch": .string("main"), "head": .string("0123456789abcdef"),
                    "detached": .bool(false), "unborn": .bool(false), "dirty": .bool(false), "changes": .array([])])])
        case "git.inspect":
            return .object(["isRepository": .bool(true), "branch": .string("main"), "dirty": .bool(false),
                "branches": .array([.object(["name": .string("main"), "checkedOut": .bool(true)])]), "commits": .array([])])
        default:
            return .object(["requiresDecision": .bool(false), "effectiveDecision": .bool(true)])
        }
    }
}
#endif
