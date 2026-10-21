#if HOSTED_TEST
import Foundation
import TronMobileCore

/// Synthetic Gateway changes at a real socket reconnect, not an iOS state injection.
struct HostedForegroundSheetScenario {
    private var connections = 0
    var queueEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-foreground-queued-editor") }
    var queueRevision: Int { queueEnabled ? connections : 0 }
    var queuedItems: [SessionSnapshot.QueuedMessage] {
        guard queueEnabled else { return [] }
        if connections > 1, ProcessInfo.processInfo.arguments.contains("-foreground-queued-removed") { return [] }
        return [.init(id: "foreground-queued-message", behavior: .followUp,
                      text: "Queued message 1607", attachmentCount: 0)]
    }

    mutating func capabilities(_ base: [String]) -> [String] {
        connections += 1
        return base + (queueEnabled ? [QueuedMessageManagementPolicy.capability] : [])
    }

    func settings(_ response: JSONValue) -> JSONValue {
        guard connections > 1, ProcessInfo.processInfo.arguments.contains("-foreground-settings-change"),
              var object = response.objectValue, let keys = object["keys"]?.arrayValue else { return response }
        let retained = ProcessInfo.processInfo.arguments.contains("-foreground-settings-removed")
            ? keys.filter { $0.objectValue?["key"]?.stringValue != "model.thinking[role=worker]" } : keys
        object["keys"] = .array(retained.map { value in
            guard var row = value.objectValue,
                  row["key"]?.stringValue == "model.thinking[role=worker]" else { return value }
            row["value"] = .string("high"); row["display"] = .string("High")
            return .object(row)
        })
        return .object(object)
    }
}
#endif
