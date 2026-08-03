import Foundation

struct ToolEvidencePresentation: Equatable {
    enum SectionKind: Equatable {
        case summary
        case target
        case input
        case result
        case error
        case technical
    }

    struct Section: Equatable, Identifiable {
        let kind: SectionKind
        let title: String
        let rows: [ToolDisplayRow]
        let body: String?
        let isDisclosure: Bool

        var id: String { title }
    }

    let title: String
    let qualifier: String?
    let status: ToolInvocationStatus
    let statusLabel: String
    let duration: String?
    let sections: [Section]

    init(data: ToolInvocationData) {
        let display = data.display
        self.title = Self.bestTitle(data: data, display: display)
        self.qualifier = Self.bestQualifier(data: data, display: display)
        self.status = data.status
        self.statusLabel = display.statusText
        self.duration = data.formattedDuration
        self.sections = Self.sections(data: data, display: display, title: title, qualifier: qualifier)
    }

    var chipText: String {
        guard let qualifier else { return title }
        return "\(title) · \(qualifier)"
    }

    private static func bestTitle(
        data: ToolInvocationData,
        display: ToolInvocationDisplayModel
    ) -> String {
        if let workerName = ToolInvocationSurface(identity: data.identity).workerName?.nilIfEmpty {
            return workerName
        }
        if let title = ToolPresentation.presentationString("title", for: data.identity)
            ?? ToolPresentation.presentationString("displayName", for: data.identity)
            ?? ToolPresentation.presentationString("chipTitle", for: data.identity) {
            return title
        }
        if let toolName = data.identity.toolName?.nilIfEmpty {
            return ToolPresentation.humanizeToolId(toolName)
        }
        return display.chipTitle.nilIfEmpty ?? "Tool"
    }

    private static func bestQualifier(
        data: ToolInvocationData,
        display: ToolInvocationDisplayModel
    ) -> String? {
        if data.status == .error {
            if let message = data.errorClassification?.message?.nilIfEmpty {
                return ToolInvocationBriefPresentation.safeTopLevelText(message, limit: 80)
            }
            if let preview = display.resultPreview?.nilIfEmpty {
                return preview.lines.first?.trimmed.nilIfEmpty.map {
                    ToolInvocationBriefPresentation.safeTopLevelText($0, limit: 80)
                }
            }
        }

        if let target = display.actionRows.first(where: { row in
            ["Target", "Path", "File", "URL", "Resource"].contains(row.label)
        })?.value.nilIfEmpty {
            return compactQualifier(target)
        }
        if let target = display.targetId?.nilIfEmpty,
           target != data.identity.toolName {
            return compactQualifier(target)
        }
        if let payload = display.payloadSummary?.nilIfEmpty {
            return compactQualifier(payload)
        }
        if let preview = display.resultPreview?.nilIfEmpty {
            return preview.lines.first?.trimmed.nilIfEmpty?.truncated(to: 80)
        }
        return nil
    }

    private static func sections(
        data: ToolInvocationData,
        display: ToolInvocationDisplayModel,
        title: String,
        qualifier: String?
    ) -> [Section] {
        var sections: [Section] = []

        var summaryRows = [
            ToolDisplayRow(label: "Status", value: display.statusText),
            ToolDisplayRow(label: "Operation", value: title),
        ]
        if let qualifier {
            summaryRows.append(ToolDisplayRow(label: "Summary", value: qualifier))
        }
        if let duration = data.formattedDuration {
            summaryRows.append(ToolDisplayRow(label: "Duration", value: duration))
        }
        sections.append(Section(kind: .summary, title: "Summary", rows: summaryRows, body: nil, isDisclosure: false))

        let targetRows = display.actionRows.filter { ["Target", "Path", "File", "URL", "Resource"].contains($0.label) }
        if let target = display.targetId?.nilIfEmpty {
            sections.append(Section(kind: .target, title: "Target", rows: [ToolDisplayRow(label: "Target", value: compactQualifier(target))], body: nil, isDisclosure: false))
        } else if !targetRows.isEmpty {
            sections.append(Section(kind: .target, title: "Target", rows: targetRows, body: nil, isDisclosure: false))
        }

        let inputRows = display.requestRows.filter { !$0.value.isEmpty && !$0.isTechnical }
        if !inputRows.isEmpty {
            sections.append(Section(kind: .input, title: "Input", rows: inputRows, body: nil, isDisclosure: false))
        } else if let pretty = display.prettyArguments?.nilIfEmpty {
            sections.append(Section(kind: .input, title: "Input", rows: [], body: pretty, isDisclosure: true))
        }

        if data.status == .error || data.errorClassification != nil {
            let errorRows = errorRows(data.errorClassification)
            let body = display.resultPreview?.nilIfEmpty ?? data.result?.nilIfEmpty
            if !errorRows.isEmpty || body != nil {
                sections.append(Section(kind: .error, title: "Error", rows: errorRows, body: body, isDisclosure: false))
            }
        } else if let body = display.resultPreview?.nilIfEmpty ?? data.result?.nilIfEmpty {
            sections.append(Section(kind: .result, title: "Result", rows: display.resultRows, body: body, isDisclosure: false))
        } else if !display.resultRows.isEmpty {
            sections.append(Section(kind: .result, title: "Result", rows: display.resultRows, body: nil, isDisclosure: false))
        }

        var technicalRows = display.technicalRows
        if let toolName = data.identity.toolName?.nilIfEmpty {
            technicalRows.insertIfMissing(ToolDisplayRow(label: "Tool", value: toolName, isTechnical: true), at: 0)
        }
        if !technicalRows.isEmpty || display.prettyArguments != nil || display.prettyResult != nil {
            let raw = [display.prettyArguments, display.prettyResult]
                .compactMap { $0?.nilIfEmpty }
                .joined(separator: "\n\n")
                .nilIfEmpty
            sections.append(Section(kind: .technical, title: "Technical", rows: technicalRows, body: raw, isDisclosure: true))
        }

        return sections
    }

    private static func errorRows(_ error: ToolErrorClassification?) -> [ToolDisplayRow] {
        guard let error else { return [] }
        var rows: [ToolDisplayRow] = []
        if let message = error.message?.nilIfEmpty {
            rows.append(ToolDisplayRow(label: "Message", value: message))
        }
        if let category = error.category?.nilIfEmpty {
            rows.append(ToolDisplayRow(label: "Category", value: category))
        }
        if let recoverable = error.recoverable {
            rows.append(ToolDisplayRow(label: "Recoverable", value: recoverable ? "Yes" : "No"))
        }
        if let code = error.code?.nilIfEmpty {
            rows.append(ToolDisplayRow(label: "Code", value: code, isTechnical: true))
        }
        return rows
    }

    private static func compactQualifier(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("/") {
            return URL(fileURLWithPath: trimmed).lastPathComponent.nilIfEmpty ?? trimmed.truncated(to: 80)
        }
        return trimmed.truncated(to: 80)
    }
}

private extension Array where Element == ToolDisplayRow {
    mutating func insertIfMissing(_ row: ToolDisplayRow, at index: Int) {
        guard !contains(where: { $0.label == row.label && $0.value == row.value }) else { return }
        insert(row, at: index)
    }
}
