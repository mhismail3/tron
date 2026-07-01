import SwiftUI

struct ContextControlSnapshotDisplay: Equatable {
    let model: String
    let contextWindowTokens: Int
    let estimatedTokens: Int
    let tokensRemaining: Int
    let usagePercent: Double
    let currentEpoch: String
    let createdAt: String
    let promptBlocks: [ContextControlPromptBlock]
    let resourceRefCount: Int
    let executionRefCount: Int
    let memory: ContextControlMemoryDisplay
    let proofLine: String

    var usagePercentRounded: Int {
        min(100, max(0, Int((usagePercent * 100).rounded())))
    }

    init?(response: ContextControlResponseDTO) {
        guard
            let snapshot = response.projection.dictionary("snapshot"),
            let session = snapshot.dictionary("session")
        else { return nil }

        let composition = snapshot.dictionary("composition")
        let proof = snapshot.dictionary("proof")
        let memoryDict = snapshot.dictionary("memory")

        self.model = session.string("model") ?? "Unknown"
        self.contextWindowTokens = session.int("contextWindowTokens") ?? 0
        self.estimatedTokens = session.int("estimatedTokens") ?? 0
        self.tokensRemaining = session.int("tokensRemaining") ?? 0
        self.usagePercent = session.double("usagePercent") ?? 0
        self.currentEpoch = session.string("currentEpoch") ?? "epoch-0"
        self.createdAt = response.projection.dictionary("snapshot")?.dictionary("resource")?.string("versionId") ?? "Current"
        self.promptBlocks = composition?
            .array("promptBlocks")?
            .compactMap { ContextControlPromptBlock(raw: $0) } ?? []
        self.resourceRefCount = composition?.array("resourceRefs")?.count ?? 0
        self.executionRefCount = composition?.array("executionRefs")?.count ?? 0
        self.memory = ContextControlMemoryDisplay(raw: memoryDict)
        self.proofLine = proof?.proofLine ?? "Provider-safe projection"
    }
}

struct ContextControlPromptBlock: Identifiable, Equatable {
    let id: String
    let label: String
    let estimatedTokens: Int
    let bodyExcluded: Bool
    let rawContentExcluded: Bool
    let messageCount: Int?

    var detail: String {
        var parts: [String] = []
        if bodyExcluded { parts.append("body excluded") }
        if rawContentExcluded { parts.append("raw content excluded") }
        if let messageCount { parts.append("\(messageCount) messages") }
        return parts.isEmpty ? "provider-safe metadata" : parts.joined(separator: " / ")
    }

    init?(raw: [String: Any]) {
        let kind = raw.string("kind") ?? UUID().uuidString
        self.id = kind
        self.label = raw.string("label") ?? kind
        self.estimatedTokens = raw.int("estimatedTokens") ?? 0
        self.bodyExcluded = raw.bool("bodyExcluded") ?? false
        self.rawContentExcluded = raw.bool("rawContentExcluded") ?? false
        self.messageCount = raw.int("messageCount")
    }
}

struct ContextControlMemoryDisplay: Equatable {
    let status: String
    let policy: String
    let promptTraceRefCount: Int
    let redactedMemoryRefCount: Int

    init(raw: [String: Any]?) {
        status = raw?.string("status") ?? "read_only"
        policy = raw?.string("policy") ?? "Memory refs only in Session Briefing"
        promptTraceRefCount = raw?.array("promptTraceRefs")?.count ?? 0
        redactedMemoryRefCount = raw?.array("redactedMemoryRefs")?.count ?? 0
    }
}

struct ContextControlActionSummaryDisplay: Identifiable, Equatable {
    let id: String
    let resourceId: String
    let kind: String
    let state: String
    let reason: String
    let actorKind: String
    let createdAt: String
    let resultStatus: String

    var title: String {
        "\(kind.capitalized) / \(state)"
    }

    var summaryLine: String {
        "\(kind) \(resultStatus)"
    }

    var icon: String {
        kind == "clear" ? "xmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill"
    }

    var tint: Color {
        kind == "clear" ? .tronError : .tronSky
    }

    static func actions(from response: ContextControlResponseDTO) -> [Self] {
        response.projection.array("actions")?.compactMap { Self(raw: $0) } ?? []
    }

    init?(raw: [String: Any]) {
        guard let resource = raw.dictionary("resource"),
              let resourceId = resource.string("resourceId") else {
            return nil
        }
        self.id = resourceId
        self.resourceId = resourceId
        self.kind = raw.string("kind") ?? "action"
        self.state = raw.string("state") ?? "unknown"
        self.reason = raw.string("reason") ?? "No reason recorded"
        self.actorKind = raw.string("actorKind") ?? "unknown"
        self.createdAt = raw.string("createdAt") ?? "unknown"
        self.resultStatus = raw.string("resultStatus") ?? state
    }
}

struct ContextControlActionDetailDisplay: Equatable {
    let summary: ContextControlActionSummaryDisplay
    let resultStatus: String
    let actorKind: String
    let expectedEffect: String
    let timelineEvent: String
    let auditRefCount: Int
    let proofLine: String

    init?(response: ContextControlResponseDTO) {
        guard
            let action = response.projection.dictionary("action"),
            let summary = ContextControlActionSummaryDisplay(raw: action)
        else { return nil }
        let result = response.projection.dictionary("result")
        let preflight = response.projection.dictionary("preflight")
        let proof = response.projection.dictionary("proof")
        self.summary = summary
        self.resultStatus = result?.string("status") ?? summary.resultStatus
        self.actorKind = action.string("actorKind") ?? summary.actorKind
        self.expectedEffect = preflight?.string("expectedEffect") ?? "Recorded context-control action"
        self.timelineEvent = result?.dictionary("timelineEvent")?.string("eventType") ?? "none"
        self.auditRefCount = response.projection.array("auditRefs")?.count ?? 0
        self.proofLine = proof?.proofLine ?? "Provider-safe projection"
    }
}

struct ContextControlMetric: Identifiable {
    let id = UUID()
    let label: String
    let value: String
}

extension Dictionary where Key == String, Value == AnyCodable {
    func dictionary(_ key: String) -> [String: Any]? {
        self[key]?.dictionaryValue
    }

    func array(_ key: String) -> [[String: Any]]? {
        self[key]?.arrayValue?.compactMap { $0 as? [String: Any] }
    }
}

extension Dictionary where Key == String, Value == Any {
    func dictionary(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func array(_ key: String) -> [[String: Any]]? {
        self[key] as? [[String: Any]]
    }

    func string(_ key: String) -> String? {
        self[key] as? String
    }

    func int(_ key: String) -> Int? {
        if let int = self[key] as? Int { return int }
        if let double = self[key] as? Double { return Int(double) }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let double = self[key] as? Double { return double }
        if let int = self[key] as? Int { return Double(int) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        self[key] as? Bool
    }

    var proofLine: String {
        let safe = bool("providerSafe") == true
        let redacted = bool("redactionApplied") == true
        let network = string("networkPolicy") ?? "none"
        if safe && redacted {
            return "provider safe / redacted / network \(network)"
        }
        return "provider safety proof incomplete"
    }
}
