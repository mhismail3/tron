import Foundation

extension CapabilityInvocationDisplayModel {
    static let technicalSummaryKeys: Set<String> = [
        "afterRevision",
        "classes",
        "grantId",
        "idempotencyKey",
        "includeDocs",
        "includeExamples",
        "kind",
        "kinds",
        "limit",
        "resourceRefs",
        "sessionId",
        "subjectPrefix",
        "traceId",
        "versionId",
        "workspaceId"
    ]

    static func requestRows(
        primitive: String,
        query: String?,
        target: String?,
        capabilityName: String,
        payloadSummary: String?,
        arguments: [String: Any]
    ) -> [CapabilityDisplayRow] {
        var rows: [CapabilityDisplayRow] = []
        func append(_ label: String, _ value: String?) {
            guard let value = value?.nilIfEmpty else { return }
            rows.append(CapabilityDisplayRow(label: label, value: value))
        }

        if let targetArguments = targetArguments(from: arguments) {
            appendPayloadRows(targetArguments, into: &rows)
        } else {
            append("Payload", payloadSummary ?? query)
        }
        append("Operation", target)
        append("Intent", firstString(["intent"], in: arguments))
        append("Reason", firstString(["reason"], in: arguments))
        if let targetArguments = targetArguments(from: arguments) {
            append("Intent", firstString(["intent"], in: targetArguments))
            append("Reason", firstString(["reason"], in: targetArguments))
        }

        if rows.isEmpty, let payloadSummary {
            rows.append(CapabilityDisplayRow(label: "Request", value: payloadSummary))
        }
        return rows
    }

    static func appendPayloadRows(_ payload: [String: Any], into rows: inout [CapabilityDisplayRow]) {
        func append(_ label: String, _ value: String?) {
            guard let value = value?.nilIfEmpty else { return }
            rows.append(CapabilityDisplayRow(label: label, value: value))
        }
        append("Command", firstString(["command", "cmd", "shellCommand"], in: payload))
        append("Execution mode", firstString(["executionMode", "mode"], in: payload))
        append("Query", firstString(["query", "q", "searchQuery", "pattern", "glob", "name"], in: payload))
        append("URL", firstString(["url", "apiUrl", "endpoint"], in: payload))
        if let path = firstString(["path", "filePath"], in: payload) {
            append("Path", compactPathLabel(path))
        }
        if let cwd = firstString(["cwd"], in: payload) {
            append("Working directory", compactPathLabel(cwd))
        }
        if let code = firstString(["code"], in: payload) {
            append("Code", code.lines.first?.trimmed.nilIfEmpty ?? "program")
        }

        let alreadyShown = Set([
            "command", "cmd", "shellCommand", "executionMode", "mode", "query", "q", "searchQuery", "pattern", "glob",
            "name", "url", "apiUrl", "endpoint", "path", "filePath", "cwd", "code"
        ])
        let extraRows = payload
            .filter { key, value in
                !alreadyShown.contains(key) && simplePayloadExtraValue(value) != nil
            }
            .sorted { $0.key < $1.key }
            .prefix(3)
            .compactMap { key, value -> CapabilityDisplayRow? in
                simplePayloadExtraValue(value).map { CapabilityDisplayRow(label: humanizeKey(key), value: $0) }
            }
        rows.append(contentsOf: extraRows)
    }

    static func executionGroups(
        primitive: String,
        data: CapabilityInvocationData,
        details: [String: Any],
        arguments: [String: Any],
        output: [String: Any]
    ) -> [CapabilityDisplayGroup] {
        []
    }

    static func resultRows(
        data: CapabilityInvocationData,
        details _: [String: Any],
        output: [String: Any]
    ) -> [CapabilityDisplayRow] {
        guard CapabilityPresentation.primitiveName(for: data.identity) == "execute" else { return [] }
        let hasProcessOutput = firstString(["exitCode"], in: output) != nil
            || firstString(["timedOut"], in: output) != nil
            || firstString(["stdout"], in: output) != nil
            || firstString(["stderr"], in: output) != nil
        guard hasProcessOutput else { return [] }

        var rows: [CapabilityDisplayRow] = []
        appendRow("Exit code", firstString(["exitCode"], in: output), to: &rows)
        appendRow("Timed out", readableBool(["timedOut"], in: output), to: &rows)
        appendRow("Output truncated", readableBool(["outputTruncated", "truncated"], in: output), to: &rows)
        return rows
    }

    static func resultPreview(
        primitive: String,
        result: String?,
        output: [String: Any]
    ) -> String? {
        guard primitive == "execute" else {
            return nil
        }
        if let stdout = firstString(["stdout"], in: output)?.nilIfEmpty {
            return stdout.truncated(to: 4_000)
        }
        if let stderr = firstString(["stderr"], in: output)?.nilIfEmpty {
            return stderr.truncated(to: 4_000)
        }
        if let content = firstString(["content"], in: output)?.nilIfEmpty {
            return content.truncated(to: 4_000)
        }
        if let diff = firstString(["diff"], in: output)?.nilIfEmpty {
            return diff.truncated(to: 4_000)
        }
        if let entries = output["entries"] as? [[String: Any]] {
            let names = entries.prefix(12).compactMap { firstString(["name", "path"], in: $0) }
            guard !names.isEmpty else { return nil }
            let more = entries.count > names.count ? "\n… \(entries.count - names.count) more" : ""
            return (names.joined(separator: "\n") + more).truncated(to: 4_000)
        }
        if let matches = output["matches"] as? [[String: Any]] {
            let lines = matches.prefix(8).compactMap { match -> String? in
                let file = firstString(["path"], in: match).map(compactPathLabel)
                let line = firstString(["line"], in: match)
                let text = firstString(["text"], in: match)
                return [file, line, text].compactMap { $0?.nilIfEmpty }.joined(separator: ": ")
            }
            guard !lines.isEmpty else { return nil }
            let more = matches.count > lines.count ? "\n… \(matches.count - lines.count) more" : ""
            return (lines.joined(separator: "\n") + more).truncated(to: 4_000)
        }
        guard let result = result?.nilIfEmpty else { return nil }
        let pretty = prettyJSONString(result) ?? result
        return pretty.count <= 1_200 ? pretty : nil
    }

    static func technicalRows(data: CapabilityInvocationData) -> [CapabilityDisplayRow] {
        let identity = data.identity
        let details = data.details?.rawValues ?? [:]
        let output = outputObject(from: data)
        var rows: [CapabilityDisplayRow] = []
        func append(_ label: String, _ value: String?) {
            guard let value = value?.nilIfEmpty else { return }
            rows.append(CapabilityDisplayRow(label: label, value: value, isTechnical: true))
        }
        append("Invocation", data.id)
        append("Primitive", identity.modelPrimitiveName)
        append("Operation", identity.operationName)
        append("Trace", identity.traceId)
        append("Root invocation", identity.rootInvocationId)
        append("Theme color", identity.themeColor)
        append("Server duration", data.serverFormattedDuration)
        append("Observed duration", data.observedDurationMs.map(CapabilityInvocationData.formatDuration))
        append("Engine status", firstString(["status"], in: details))
        append("Exit code", firstString(["exitCode"], in: output))
        append("Timed out", firstString(["timedOut"], in: output))
        append("Output truncated", firstString(["outputTruncated", "truncated"], in: output))
        if let entries = output["entries"] as? [Any] {
            append("Entry count", String(entries.count))
        }
        if let matches = output["matches"] as? [Any] {
            append("Match count", String(matches.count))
        }
        if let path = firstString(["path"], in: output) {
            append("Result path", compactPathLabel(path))
        }
        if let childInvocations = data.details?.rawValues["childInvocations"] as? [Any], !childInvocations.isEmpty {
            append("Child invocations", String(childInvocations.count))
        }
        return rows
    }

    static func appendRow(
        _ label: String,
        _ value: String?,
        to rows: inout [CapabilityDisplayRow],
        technical: Bool = false
    ) {
        guard let value = value?.nilIfEmpty else { return }
        rows.append(CapabilityDisplayRow(label: label, value: value, isTechnical: technical))
    }

    static func argumentObject(from data: CapabilityInvocationData) -> [String: Any] {
        if let payloadJSON = data.payloadJSON {
            return payloadJSON.rawValues
        }
        return objectFromJSONString(data.arguments) ?? [:]
    }

    static func outputObject(from data: CapabilityInvocationData) -> [String: Any] {
        if let output = data.details?.anyCodableDict("output")?.rawValues {
            return output
        }
        if let result = data.result, let object = objectFromJSONString(result) {
            return object
        }
        return [:]
    }

    static func objectFromJSONString(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    static func prettyJSONString(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }

    static func prettyJSON(_ value: [String: AnyCodable]) -> String? {
        let raw = value.mapValues(\.value)
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: data, encoding: .utf8)
        else { return nil }
        return pretty
    }

    static func firstString(_ keys: [String], in object: [String: Any]) -> String? {
        for key in keys {
            if let value = object[key], let string = simpleDisplayValue(value)?.nilIfEmpty {
                return string
            }
        }
        return nil
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        if let dictionary = value as? [String: AnyCodable] {
            return dictionary.rawValues
        }
        if let value = value as? AnyCodable {
            return value.dictionaryValue
        }
        return nil
    }

    static func array(_ value: Any?) -> [Any]? {
        if let array = value as? [Any] {
            return array
        }
        if let value = value as? AnyCodable {
            return value.arrayValue
        }
        return nil
    }

    static func stringArray(_ value: Any?) -> [String]? {
        array(value)?.compactMap { item in
            if let string = item as? String {
                return string
            }
            return simpleDisplayValue(item)
        }
    }

    static func string(_ value: Any?) -> String? {
        if let value {
            return simpleDisplayValue(value)
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let value = value as? AnyCodable {
            return value.boolValue
        }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        return nil
    }

    static func simpleDisplayValue(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let int as Int:
            return String(int)
        case let double as Double:
            return String(double)
        case let bool as Bool:
            return String(bool)
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    static func humanizeToken(_ token: String?) -> String? {
        guard let token = token?.nilIfEmpty else { return nil }
        let withWordBreaks = token
            .replacingOccurrences(
                of: #"([a-z0-9])([A-Z])"#,
                with: "$1 $2",
                options: .regularExpression
            )
        return withWordBreaks
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    static func readableBool(_ keys: [String], in object: [String: Any]) -> String? {
        for key in keys {
            if let bool = object[key] as? Bool {
                return bool ? "Yes" : "No"
            }
            if let number = object[key] as? NSNumber {
                return number.boolValue ? "Yes" : "No"
            }
            if let string = (object[key] as? String)?.trimmed.lowercased() {
                switch string {
                case "true", "yes", "1":
                    return "Yes"
                case "false", "no", "0":
                    return "No"
                default:
                    continue
                }
            }
        }
        return nil
    }

    static func correctionSummary(_ corrections: [Any]) -> String {
        guard !corrections.isEmpty else { return "None" }
        let labels = corrections.prefix(3).compactMap { item -> String? in
            if let item = item as? [String: Any] {
                return firstString(["message", "kind"], in: item)
            }
            if let item = item as? [String: AnyCodable] {
                return firstString(["message", "kind"], in: item.rawValues)
            }
            return simpleDisplayValue(item)
        }
        if labels.isEmpty {
            return "\(corrections.count) applied"
        }
        let more = corrections.count > labels.count ? " +\(corrections.count - labels.count) more" : ""
        return labels.joined(separator: "; ") + more
    }

    static func compactIdentifier(_ id: String) -> String {
        guard id.count > 28 else { return id }
        let prefix = id.prefix(12)
        let suffix = id.suffix(10)
        return "\(prefix)…\(suffix)"
    }

    static func simplePayloadExtraValue(_ value: Any) -> String? {
        if let bool = value as? Bool {
            return bool ? "true" : nil
        }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : nil
        }
        return simpleDisplayValue(value)
    }

    static func compactPathLabel(_ path: String) -> String {
        let abbreviated = path.abbreviatingHomeDirectory
        let last = (abbreviated as NSString).lastPathComponent
        if !last.isEmpty, last != "/" {
            return last
        }
        return abbreviated
    }

    static func humanizeKey(_ key: String) -> String {
        key
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}

extension Dictionary where Key == String, Value == AnyCodable {
    var rawValues: [String: Any] {
        mapValues(\.value)
    }
}
