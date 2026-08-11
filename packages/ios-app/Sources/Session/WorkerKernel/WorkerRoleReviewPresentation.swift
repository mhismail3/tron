import Foundation

enum WorkerAgentRoleReviewDecision: Equatable, Sendable {
    case enabled
    case disabled
    case unknown(String)
}

struct WorkerAgentRoleReviewField: Identifiable, Equatable, Sendable {
    let label: String
    let value: String

    var id: String { label }
}

struct WorkerAgentRoleReviewPresentation: Equatable, Sendable {
    let decision: WorkerAgentRoleReviewDecision
    let title: String
    let detail: String
    let fields: [WorkerAgentRoleReviewField]

    static func declaration(_ value: AnyCodable) -> Self {
        guard let role = value.dictionaryValue,
              let status = role["status"] as? String else {
            return Self(
                decision: .unknown("unknown"),
                title: "Unrecognized declaration",
                detail: "The server returned a declaration shape this app does not understand.",
                fields: [
                    WorkerAgentRoleReviewField(
                        label: "Raw declaration",
                        value: prettyJSON(value)
                    ),
                ]
            )
        }

        if status == "disabled" {
            return Self(
                decision: .disabled,
                title: "Reusable role disabled",
                detail: "This immutable version records that the worker is not a reusable agent role.",
                fields: []
            )
        }

        guard status == "enabled" else {
            return Self(
                decision: .unknown(status),
                title: "Unrecognized decision",
                detail: "This app will preserve the server declaration without offering inferred actions.",
                fields: [WorkerAgentRoleReviewField(label: "Status", value: status)]
            )
        }

        var fields: [WorkerAgentRoleReviewField] = []
        appendString("Display name", key: "displayName", from: role, to: &fields)
        appendString("Summary", key: "summary", from: role, to: &fields)
        fields.append(WorkerAgentRoleReviewField(
            label: "Discoverable",
            value: (role["discoverable"] as? Bool) == true ? "Yes" : "No"
        ))
        appendString(
            "Collaboration instructions",
            key: "collaborationInstructions",
            from: role,
            to: &fields
        )
        appendString("Default model", key: "defaultModel", from: role, to: &fields)
        appendString(
            "Default reasoning",
            key: "defaultReasoningLevel",
            from: role,
            to: &fields
        )
        if let tools = AnyCodable(role["toolCeiling"]).arrayValue?.compactMap({ $0 as? String }) {
            fields.append(WorkerAgentRoleReviewField(
                label: "Tool ceiling",
                value: tools.isEmpty ? "No delegated tools" : tools.joined(separator: ", ")
            ))
        }
        if let limits = AnyCodable(role["limits"]).dictionaryValue, !limits.isEmpty {
            fields.append(WorkerAgentRoleReviewField(
                label: "Limits",
                value: compactLimits(limits)
            ))
        }
        appendString("Result mode", key: "resultMode", from: role, to: &fields)

        return Self(
            decision: .enabled,
            title: "Reusable role enabled",
            detail: "Applying publishes a new immutable worker version with this explicit role declaration.",
            fields: fields
        )
    }

    static func statusTitle(_ status: String) -> String {
        switch status {
        case "proposed": "Ready for review"
        case "applying": "Publishing"
        case "applied": "Applied"
        case "rejected": "Rejected"
        case "stale": "Stale"
        default: WorkerConsolePresentation.displayLabel(status)
        }
    }

    private static func appendString(
        _ label: String,
        key: String,
        from object: [String: Any],
        to fields: inout [WorkerAgentRoleReviewField]
    ) {
        guard let value = object[key] as? String, !value.isEmpty else { return }
        fields.append(WorkerAgentRoleReviewField(label: label, value: value))
    }

    private static func compactLimits(_ limits: [String: Any]) -> String {
        let order = [
            ("maxAssignmentSeconds", "seconds"),
            ("maxAssignmentTurns", "turns"),
            ("maxChildExecutions", "children"),
            ("maxQueuedAssignments", "queued"),
        ]
        let values = order.compactMap { key, label -> String? in
            guard let value = numericString(limits[key]) else { return nil }
            return "\(value) \(label)"
        }
        return values.isEmpty ? "Engine defaults" : values.joined(separator: " · ")
    }

    private static func numericString(_ value: Any?) -> String? {
        if let number = value as? NSNumber { return number.stringValue }
        if let integer = value as? Int { return String(integer) }
        if let unsigned = value as? UInt64 { return String(unsigned) }
        return nil
    }

    private static func prettyJSON(_ value: AnyCodable) -> String {
        guard JSONSerialization.isValidJSONObject(value.value),
              let data = try? JSONSerialization.data(
                withJSONObject: value.value,
                options: [.prettyPrinted, .sortedKeys]
              ) else {
            return String(describing: value.value)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
