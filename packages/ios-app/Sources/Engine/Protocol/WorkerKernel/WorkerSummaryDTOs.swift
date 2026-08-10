import Foundation

struct WorkerSummaryDTO: Codable, Equatable, Identifiable, Sendable {
    let workerId: String
    let name: String
    let description: String
    let toolName: String
    let runnerKind: String
    let activeVersion: String
    let enabled: Bool
    let retired: Bool
    let health: String
    let triggerCount: UInt64
    let updatedAt: String
    let presentation: WorkerPresentationDTO?

    var id: String { workerId }
}

struct WorkerPresentationDTO: Codable, Equatable, Sendable {
    let experienceId: String
    let contractVersion: UInt32
    let suiteId: String?
    let componentRole: String?
    let primary: Bool
    let sections: [WorkerPresentationSectionDTO]

    init(
        experienceId: String,
        contractVersion: UInt32,
        suiteId: String?,
        componentRole: String?,
        primary: Bool,
        sections: [WorkerPresentationSectionDTO] = []
    ) {
        self.experienceId = experienceId
        self.contractVersion = contractVersion
        self.suiteId = suiteId
        self.componentRole = componentRole
        self.primary = primary
        self.sections = sections
    }

    private enum CodingKeys: String, CodingKey {
        case experienceId, contractVersion, suiteId, componentRole, primary, sections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        experienceId = try container.decode(String.self, forKey: .experienceId)
        contractVersion = try container.decode(UInt32.self, forKey: .contractVersion)
        suiteId = try container.decodeIfPresent(String.self, forKey: .suiteId)
        componentRole = try container.decodeIfPresent(String.self, forKey: .componentRole)
        primary = try container.decodeIfPresent(Bool.self, forKey: .primary) ?? false
        sections = try container.decodeIfPresent(
            [WorkerPresentationSectionDTO].self,
            forKey: .sections
        ) ?? []
    }
}

struct WorkerPresentationColumnDTO: Codable, Equatable, Sendable {
    let label: String
    let valuePointer: String
}

struct WorkerPresentationActionDTO: Codable, Equatable, Sendable {
    let actionId: String
    let label: String
    let input: AnyCodable
}

struct WorkerPresentationSectionDTO: Codable, Equatable, Identifiable, Sendable {
    let sectionId: String
    let kind: String
    let title: String?
    let detail: String?
    let valuePointer: String?
    let columns: [WorkerPresentationColumnDTO]
    let label: String?
    let url: String?
    let action: WorkerPresentationActionDTO?

    var id: String { sectionId }

    init(
        sectionId: String,
        kind: String,
        title: String? = nil,
        detail: String? = nil,
        valuePointer: String? = nil,
        columns: [WorkerPresentationColumnDTO] = [],
        label: String? = nil,
        url: String? = nil,
        action: WorkerPresentationActionDTO? = nil
    ) {
        self.sectionId = sectionId
        self.kind = kind
        self.title = title
        self.detail = detail
        self.valuePointer = valuePointer
        self.columns = columns
        self.label = label
        self.url = url
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case sectionId, kind, title, detail, valuePointer, columns, label, url, action
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sectionId = try container.decode(String.self, forKey: .sectionId)
        kind = try container.decode(String.self, forKey: .kind)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        valuePointer = try container.decodeIfPresent(String.self, forKey: .valuePointer)
        columns = try container.decodeIfPresent(
            [WorkerPresentationColumnDTO].self,
            forKey: .columns
        ) ?? []
        label = try container.decodeIfPresent(String.self, forKey: .label)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        action = try container.decodeIfPresent(WorkerPresentationActionDTO.self, forKey: .action)
    }
}

struct WorkerListResultDTO: Codable, Equatable, Sendable {
    let workers: [WorkerSummaryDTO]
    let stopAll: Bool
}

struct WorkerScheduledWorkItemDTO: Codable, Equatable, Identifiable, Sendable {
    let scheduledId: String
    let workerId: String
    let workerName: String
    let kind: String
    let triggerId: String?
    let invocationId: String?
    let scheduledAt: String
    let everySeconds: UInt64?
    let triggerKind: String

    var id: String { scheduledId }
}

struct WorkerScheduledWorkResultDTO: Codable, Equatable, Sendable {
    let items: [WorkerScheduledWorkItemDTO]
    let truncated: Bool
    let nextOffset: UInt64?
}

struct WorkerVersionDTO: Codable, Equatable, Identifiable, Sendable {
    let version: String
    let contentHash: String
    let createdAt: String

    var id: String { version }
}

struct WorkerTriggerStatusDTO: Codable, Equatable, Identifiable, Sendable {
    let triggerId: String
    let kind: String
    let configuration: AnyCodable
    let tokenConfigured: Bool
    let nextRunAt: String?
    let streamCursor: Int64
    let enabled: Bool

    var id: String { triggerId }
}

struct WorkerInspectResultDTO: Codable, Equatable, Sendable {
    let worker: WorkerSummaryDTO
    let bundle: [String: AnyCodable]
    let versions: [WorkerVersionDTO]
    let triggers: [WorkerTriggerStatusDTO]
    let audit: [WorkerAuditDTO]
    let versionDirectory: String
}

struct WorkerAuditDTO: Codable, Equatable, Identifiable, Sendable {
    let auditId: String
    let workerId: String
    let action: String
    let details: AnyCodable
    let createdAt: String

    var id: String { auditId }
}

/// Server projection for a successful invocation output.
///
/// Current servers always return an integrity-bound reference. `legacyInline`
/// is decode-only migration compatibility for profiles served by schema-v9
/// binaries; new UI paths must not treat it as authoritative server state.
