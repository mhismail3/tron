import Foundation

/// Lightweight server-side activity summary line.
/// Enriched client-side with capability identity metadata.
struct ServerActivityLine: Decodable, Hashable, Sendable {
    let kind: String
    let text: String?
    let capabilityArgs: AnyCodable?
    let durationMs: Int?
    let isError: Bool?
    let turns: Int?
    let modelPrimitiveName: String?
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
    let presentationHints: [String: AnyCodable]?
    let summary: String?

    func toActivityLine() -> ActivityLine {
        switch kind {
        case "userPrompt":
            return ActivityLine(kind: .userPrompt, text: text ?? "")
        case "text":
            return ActivityLine(kind: .text, text: text ?? "")
        case "thinking":
            return ActivityLine(kind: .thinking, text: "Thinking")
        case "capability":
            let identity = capabilityIdentity
            let name = identity.stableCapabilityId
            let durationStr = durationMs.map { SessionStreamBuffer.formatDuration($0) }
            return ActivityLine(
                kind: .capabilityInvocationStarted,
                text: name,
                icon: CapabilityActivityPresentation.symbol(for: identity, arguments: capabilityArgs),
                iconColor: CapabilityColor.fromCapability(identity),
                modelPrimitiveName: name,
                displayName: CapabilityActivityPresentation.title(for: identity, arguments: capabilityArgs),
                summary: CapabilityActivityPresentation.summary(
                    explicit: summary,
                    arguments: capabilityArgs,
                    identity: identity
                ),
                duration: durationStr,
                status: (isError == true) ? .error : .success,
                capabilityIdentity: identity
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
            modelPrimitiveName: modelPrimitiveName,
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
            bindingDecisionId: bindingDecisionId,
            presentationHints: presentationHints
        )
    }
}
