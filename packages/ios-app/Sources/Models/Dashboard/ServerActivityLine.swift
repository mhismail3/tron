import Foundation

/// Lightweight server-side activity summary line.
/// Enriched client-side with capability identity metadata.
struct ServerActivityLine: Decodable, Hashable, Sendable {
    let kind: String
    let text: String?
    let toolArgs: AnyCodable?
    let durationMs: Int?
    let isError: Bool?
    let turns: Int?
    let modelToolName: String?
    let contractId: String?
    let implementationId: String?
    let functionId: String?
    let pluginId: String?
    let workerId: String?
    let schemaDigest: String?
    let catalogRevision: UInt64?
    let trustTier: String?
    let riskLevel: String?
    let effectClass: String?
    let traceId: String?
    let rootInvocationId: String?
    let bindingDecisionId: String?

    func toActivityLine() -> ActivityLine {
        switch kind {
        case "userPrompt":
            return ActivityLine(kind: .userPrompt, text: text ?? "")
        case "text":
            return ActivityLine(kind: .text, text: text ?? "")
        case "thinking":
            return ActivityLine(kind: .thinking, text: "Thinking")
        case "tool":
            let identity = capabilityIdentity
            let name = identity.stableCapabilityId
            let argsJSON = serializeArgs(toolArgs)
            let durationStr = durationMs.map { SessionStreamBuffer.formatDuration($0) }
            return ActivityLine(
                kind: .capabilityStart,
                text: name,
                icon: CapabilityPresentation.symbol(for: identity),
                iconColor: CapabilityColor.fromCapability(identity),
                modelToolName: name,
                displayName: CapabilityPresentation.title(for: identity),
                summary: argsJSON == "{}" ? nil : argsJSON,
                duration: durationStr,
                status: (isError == true) ? .error : .success
            )
        case "subagentDone":
            let t = turns ?? 0
            let durationStr = durationMs.map { SessionStreamBuffer.formatDuration($0) }
            return ActivityLine(kind: .subagentDone, text: "Agent complete (\(t) turns)", duration: durationStr)
        case "subagentFailed":
            return ActivityLine(kind: .subagentFailed, text: text ?? "Agent failed")
        default:
            return ActivityLine(kind: .text, text: text ?? "")
        }
    }

    private var capabilityIdentity: CapabilityIdentity {
        CapabilityIdentity(
            modelToolName: modelToolName,
            contractId: contractId,
            implementationId: implementationId,
            functionId: functionId,
            pluginId: pluginId,
            workerId: workerId,
            schemaDigest: schemaDigest,
            catalogRevision: catalogRevision,
            trustTier: trustTier,
            riskLevel: riskLevel,
            effectClass: effectClass,
            traceId: traceId,
            rootInvocationId: rootInvocationId,
            bindingDecisionId: bindingDecisionId
        )
    }

    private func serializeArgs(_ args: AnyCodable?) -> String {
        guard let args = args else { return "{}" }
        let val = args.value
        guard JSONSerialization.isValidJSONObject(val) else { return "{}" }
        guard let data = try? JSONSerialization.data(withJSONObject: val),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}
