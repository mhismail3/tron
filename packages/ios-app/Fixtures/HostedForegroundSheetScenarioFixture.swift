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
        return [.init(id: "foreground-queued-message",
                      behavior: ProcessInfo.processInfo.arguments.contains("-foreground-queued-steer") ? .steer : .followUp,
                      text: queuedText, attachmentCount: 0)]
    }

    private var queuedText: String {
        guard ProcessInfo.processInfo.arguments.contains("-foreground-queued-annotation") else {
            return "Queued message 1607"
        }
        return ChatAnnotationEnvelope.compose(annotations: [ChatAnnotation(
            quote: "Tron project (6 notes): rule — keep one owner per lifecycle.",
            comment: "Apply this rule to the queued card.", anchor: nil
        )], body: "")
    }

    mutating func capabilities(_ base: [String]) -> [String] {
        connections += 1
        return base + (queueEnabled ? [QueuedMessageManagementPolicy.capability] : [])
    }

    var devices: JSONValue {
        let changed = connections > 1 && ProcessInfo.processInfo.arguments.contains("-foreground-device-change")
        return .object(["devices": .array(changed ? [.object([
            "id": .string("foreground-device"), "name": .string("Foreground device"),
            "createdAt": .string("2026-01-01T00:00:00Z"),
        ])] : [])])
    }

    func providers(_ response: JSONValue) -> JSONValue {
        guard connections > 1, ProcessInfo.processInfo.arguments.contains("-foreground-provider-change"),
              var object = response.objectValue, let rows = object["providers"]?.arrayValue else { return response }
        object["providers"] = .array(rows.map { value in
            guard var provider = value.objectValue, let name = provider["name"]?.stringValue else { return value }
            provider["name"] = .string(name + " refreshed")
            return .object(provider)
        })
        return .object(object)
    }


}
#endif
