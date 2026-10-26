import Foundation
import TronMobileCore

struct ChatProviderErrorOccurrence: Hashable, Identifiable, Sendable {
    let id: String
    let semanticID: String
    let raw: String
    let title: String
    let provider: String?
    let model: String?
    let timestamp: String
    let info: UpstreamErrorInfo?

    init?(_ item: TranscriptItem) {
        guard item.role == .assistant, let raw = item.errorMessage, !raw.isEmpty else { return nil }
        id = item.presentationId
        semanticID = item.id
        self.raw = raw
        info = item.errorInfo
        title = item.errorInfo?.message ?? raw
        provider = item.provider
        model = item.modelId
        timestamp = item.timestamp
    }

    struct Identity: Hashable {
        let provider: String?
        let model: String?
        let category: String?
        let type: String?
        let message: String
    }
    var identity: Identity {
        Identity(provider: provider, model: model, category: info?.category,
                 type: info?.type, message: info?.providerMessage ?? title)
    }
    var formatted: String {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let text = String(data: pretty, encoding: .utf8) else { return raw }
        return text
    }
    var modelLabel: String? {
        let value = [provider.map(ModelDisplayFormatting.provider), model].compactMap { $0 }.joined(separator: " · ")
        return value.isEmpty ? nil : value
    }
    var timeLabel: String { ToolInvocationTimestamp.text(for: timestamp) ?? timestamp }
}

struct ChatProviderErrorRun: Hashable, Sendable {
    let occurrences: [ChatProviderErrorOccurrence]

    struct Breakdown: Identifiable {
        let first: ChatProviderErrorOccurrence
        var count: Int
        var id: String { first.id }
    }
    var breakdown: [Breakdown] {
        var rows: [Breakdown] = []
        var indices: [ChatProviderErrorOccurrence.Identity: Int] = [:]
        for occurrence in occurrences {
            if let index = indices[occurrence.identity] { rows[index].count += 1 }
            else {
                indices[occurrence.identity] = rows.count
                rows.append(Breakdown(first: occurrence, count: 1))
            }
        }
        return rows
    }
    var title: String { breakdown.count == 1 ? occurrences[0].title : "Provider errors" }
    var sheetTitle: String { occurrences.count == 1 ? title : "\(occurrences.count) provider errors" }
    var notification: ChatNotificationPresentation {
        ChatNotificationPresentation(
            id: "notification-provider-error-\(occurrences[0].id)", semanticID: occurrences[0].semanticID,
            icon: "exclamationmark.triangle.fill", title: title, detail: nil, body: nil,
            tone: .error, material: .glass, errorRun: self
        )
    }
}
