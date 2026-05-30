import SwiftUI

@available(iOS 26.0, *)
struct CapabilityResultRenderer: View {
    let content: String
    let details: [String: AnyCodable]?
    let identity: CapabilityIdentity

    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: CapabilityPresentation.primitiveColor(for: identity), colorScheme: colorScheme)
    }

    var body: some View {
        let primitive = CapabilityPresentation.primitiveName(for: identity)
        if primitive == "search", let details {
            CapabilitySearchResultSummary(details: details, tint: tint)
        } else if primitive == "inspect", let details {
            CapabilityInspectionResultSummary(details: details, tint: tint)
        } else if let details, let pretty = Self.prettyJSON(details), !pretty.isEmpty {
            CapabilityInvocationCodeBlock(text: pretty)
        } else if looksLikeJSON(content), let pretty = Self.prettyJSONString(content) {
            CapabilityInvocationCodeBlock(text: pretty)
        } else {
            CapabilityInvocationCodeBlock(text: content)
        }
    }

    private func looksLikeJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    private static func prettyJSON(_ value: [String: AnyCodable]) -> String? {
        let raw = value.mapValues(\.value)
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func prettyJSONString(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
}

@available(iOS 26.0, *)
private struct CapabilitySearchResultSummary: View {
    let details: [String: AnyCodable]
    let tint: TintedColors

    private var results: [[String: Any]] {
        details["results"]?.arrayValue?.compactMap { $0 as? [String: Any] } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CapabilityReadableRows(rows: summaryRows, tint: tint)

            if let mode = details.anyCodableDict("searchMode"),
               let state = mode.string("state") {
                CapabilityInfoPill(
                    icon: state == "ready" ? "checkmark.circle" : "exclamationmark.triangle",
                    label: searchModeLabel(mode: mode),
                    color: state == "ready" ? .tronSuccess : .tronAmber
                )
            }

            if let nextCursor = details.string("nextCursor")?.nilIfEmpty {
                CapabilityInfoPill(icon: "arrow.forward.circle", label: "More results available: \(nextCursor)", color: .tronInfo)
            }

            if results.isEmpty {
                Text(emptyMessage)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(results.prefix(8).enumerated()), id: \.offset) { _, result in
                        CapabilitySearchResultRow(result: result, tint: tint)
                    }
                }
            }
        }
    }

    private var summaryRows: [CapabilityDisplayRow] {
        var rows: [CapabilityDisplayRow] = []
        func append(_ label: String, _ value: String?, technical: Bool = false) {
            guard let value = value?.nilIfEmpty else { return }
            rows.append(CapabilityDisplayRow(label: label, value: value, isTechnical: technical))
        }

        append("Query", details.string("query"))
        append("Results", String(results.count))
        append("Catalog", details.uint64("catalogRevision").map(String.init), technical: true)

        if let mode = details.anyCodableDict("searchMode") {
            append("Index", mode.string("state"))
            append("Vector", mode.bool("localVector").map { $0 ? "Ready" : "Unavailable" })
            append("Lexical", mode.bool("lexical").map { $0 ? "Enabled" : "Disabled" })
            append("Embedding", mode.string("embeddingModel"), technical: true)
            append("Vector store", mode.string("vectorStore"), technical: true)
        }

        return rows
    }

    private var emptyMessage: String {
        if let query = details.string("query")?.nilIfEmpty {
            return "No capabilities matched “\(query)”."
        }
        return "No capabilities matched this search."
    }

    private func searchModeLabel(mode: [String: AnyCodable]) -> String {
        if let degraded = mode.string("degradedReason")?.nilIfEmpty {
            return "Degraded: \(degraded)"
        }
        if mode.bool("localVector") == true {
            return "Hybrid local search ready"
        }
        if mode.bool("lexical") == true {
            return "Lexical search"
        }
        return mode.string("state") ?? "Search status unknown"
    }
}

@available(iOS 26.0, *)
private struct CapabilitySearchResultRow: View {
    let result: [String: Any]
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle {
                Text(subtitle)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(tint.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                ForEach(badges, id: \.self) { badge in
                    CapabilitySourceBadge(label: badge, color: tint.accent)
                }
            }
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.tronTextMuted.opacity(0.18))
                .frame(height: 1)
        }
    }

    private var title: String {
        string(["contractId", "implementationId", "functionId", "id", "name"]) ?? "Capability"
    }

    private var subtitle: String? {
        string(["description", "reason", "pluginId"])
    }

    private var badges: [String] {
        ["kind", "health", "trustTier", "riskLevel"]
            .compactMap { key in string([key]) }
            .filter { !$0.isEmpty }
    }

    private func string(_ keys: [String]) -> String? {
        for key in keys {
            if let value = result[key] as? String, !value.isEmpty {
                return value
            }
            if let value = result[key] as? NSNumber {
                return value.stringValue
            }
        }
        return nil
    }
}

@available(iOS 26.0, *)
private struct CapabilityInspectionResultSummary: View {
    let details: [String: AnyCodable]
    let tint: TintedColors

    var body: some View {
        let contract = details.anyCodableDict("contract")
        let implementation = details.anyCodableDict("implementation")
        let requirements = details.anyCodableDict("executionRequirements")
        let binding = details.anyCodableDict("bindingDecision")
        let provenance = details.anyCodableDict("pluginProvenance") ?? details.anyCodableDict("provenance")

        VStack(alignment: .leading, spacing: 14) {
            CapabilityReadableRows(
                rows: inspectionRows(
                    contract: contract,
                    implementation: implementation,
                    requirements: requirements,
                    binding: binding,
                    provenance: provenance
                ),
                tint: tint
            )

            if requirements?.bool("freshInspectionRequired") == true {
                CapabilityInfoPill(icon: "lock.shield", label: "Fresh inspection required", color: .tronAmber)
            }

            if let approval = approvalRequirement(requirements: requirements, contract: contract) {
                CapabilityInfoPill(icon: "checkmark.shield", label: approval, color: .tronAmber)
            }

            if let examples = contract?.array("examples"), !examples.isEmpty {
                CapabilityRawDisclosure(title: "Examples", text: prettyJSONArray(examples), tint: tint)
            }
        }
    }

    private func inspectionRows(
        contract: [String: AnyCodable]?,
        implementation: [String: AnyCodable]?,
        requirements: [String: AnyCodable]?,
        binding: [String: AnyCodable]?,
        provenance: [String: AnyCodable]?
    ) -> [CapabilityDisplayRow] {
        var rows: [CapabilityDisplayRow] = []
        func append(_ label: String, _ value: String?, technical: Bool = false) {
            guard let value = value?.nilIfEmpty else { return }
            rows.append(CapabilityDisplayRow(label: label, value: value, isTechnical: technical))
        }
        append("Contract", contract?.string("contractId"), technical: true)
        append("Display", contract?.string("displayName"))
        append("Description", contract?.string("description"))
        append("Implementation", implementation?.string("implementationId"), technical: true)
        append("Function", implementation?.string("functionId"), technical: true)
        append("Plugin", implementation?.string("pluginId") ?? provenance?.string("pluginId"), technical: true)
        append("Worker", implementation?.string("workerId"), technical: true)
        append("Trust", implementation?.string("trustTier"))
        append("Health", implementation?.string("health"))
        append("Risk", contract?.string("riskLevel"))
        append("Effect", contract?.string("effectClass"))
        append("Binding", binding?.string("bindingDecisionId") ?? binding?.string("id"), technical: true)
        append("Selection", binding?.string("selectionPolicy") ?? binding?.string("policy"))
        append("Expected revision", requirements?.uint64("expectedRevision").map(String.init), technical: true)
        append("Schema digest", requirements?.string("expectedSchemaDigest"), technical: true)
        append("Inspection handle", requirements?.string("inspectionHandle"), technical: true)
        return rows
    }

    private func approvalRequirement(
        requirements: [String: AnyCodable]?,
        contract: [String: AnyCodable]?
    ) -> String? {
        if requirements?.bool("approvalRequired") == true {
            return "Approval required before execution"
        }
        if let approval = contract?.anyCodableDict("approvalContract"),
           approval.bool("required") == true {
            return "Approval required by contract"
        }
        return nil
    }

    private func prettyJSONArray(_ value: [Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: data, encoding: .utf8)
        else { return "[]" }
        return pretty
    }
}

@available(iOS 26.0, *)
struct CapabilityInvocationCodeBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .regular))
            .foregroundStyle(.tronTextSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.tronSurface.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
