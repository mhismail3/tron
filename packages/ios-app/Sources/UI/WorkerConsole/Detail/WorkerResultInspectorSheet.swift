import Foundation
import SwiftUI

struct WorkerResultSelection: Identifiable {
    let invocationId: String
    var id: String { invocationId }
}

private struct WorkerResultLocation: Hashable {
    let pointer: String
    let offset: UInt64
}

struct WorkerResultFieldPresentation: Equatable, Identifiable, Sendable {
    let pointer: String
    let label: String
    let type: String
    let detail: String
    let sizeBytes: UInt64?

    var id: String { pointer }
}

/// Presentation-only helpers for navigating a bounded JSON result page.
///
/// The server remains authoritative for exact values and JSON-pointer
/// navigation. These helpers only turn the currently loaded bounded page into
/// readable field labels and primitive text.
enum WorkerResultInspectorPresentation {
    private static let preferredFieldOrder = [
        "status", "summary", "answer", "report", "result", "message",
        "warnings", "sources", "citations", "claims",
    ]

    static func fields(in chunk: WorkerResultChunkDTO) -> [WorkerResultFieldPresentation] {
        if !chunk.children.isEmpty {
            return chunk.children.map {
                WorkerResultFieldPresentation(
                    pointer: $0.pointer,
                    label: pointerLabel($0.pointer),
                    type: WorkerConsolePresentation.displayLabel($0.type),
                    detail: $0.preview.isEmpty ? "Open this field" : $0.preview,
                    sizeBytes: $0.sizeBytes
                )
            }
        }

        if let dictionary = chunk.value.dictionaryValue {
            return dictionary.keys.sorted(by: fieldOrder).map { key in
                let value = dictionary[key] ?? NSNull()
                return WorkerResultFieldPresentation(
                    pointer: appending(key, to: chunk.pointer),
                    label: WorkerConsolePresentation.displayLabel(key),
                    type: valueType(value),
                    detail: preview(value),
                    sizeBytes: nil
                )
            }
        }

        if let array = chunk.value.arrayValue {
            return array.indices.map { index in
                let value = array[index]
                return WorkerResultFieldPresentation(
                    pointer: appending(String(index), to: chunk.pointer),
                    label: "Item \(index + 1)",
                    type: valueType(value),
                    detail: preview(value),
                    sizeBytes: nil
                )
            }
        }

        return []
    }

    static func primitiveText(_ value: AnyCodable) -> String? {
        if value.isNull {
            return nil
        }
        if let string = value.stringValue {
            return string
        }
        if let bool = value.boolValue {
            return bool ? "True" : "False"
        }
        if let int = value.intValue {
            return String(int)
        }
        if let double = value.doubleValue {
            return String(double)
        }
        return nil
    }

    static func isEmptyCollection(_ value: AnyCodable) -> Bool {
        value.dictionaryValue?.isEmpty == true || value.arrayValue?.isEmpty == true
    }

    private static func fieldOrder(_ lhs: String, _ rhs: String) -> Bool {
        let lhsRank = preferredFieldOrder.firstIndex(of: lhs) ?? preferredFieldOrder.count
        let rhsRank = preferredFieldOrder.firstIndex(of: rhs) ?? preferredFieldOrder.count
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    private static func pointerLabel(_ pointer: String) -> String {
        guard let component = pointer.split(separator: "/").last else {
            return "Result"
        }
        let decoded = component
            .replacingOccurrences(of: "~1", with: "/")
            .replacingOccurrences(of: "~0", with: "~")
        if let index = Int(decoded) {
            return "Item \(index + 1)"
        }
        return WorkerConsolePresentation.displayLabel(decoded)
    }

    private static func appending(_ component: String, to pointer: String) -> String {
        let escaped = component
            .replacingOccurrences(of: "~", with: "~0")
            .replacingOccurrences(of: "/", with: "~1")
        return "\(pointer)/\(escaped)"
    }

    private static func valueType(_ value: Any) -> String {
        switch value {
        case is NSNull: "Empty"
        case is [String: Any], is NSDictionary: "Object"
        case is [Any], is NSArray: "List"
        case is String: "Text"
        case is Bool: "Boolean"
        case is Int, is Double: "Number"
        default: "Value"
        }
    }

    private static func preview(_ value: Any) -> String {
        switch value {
        case is NSNull:
            "No value"
        case let string as String:
            WorkerConsolePresentation.compactText(string, maxLength: 180)
        case let bool as Bool:
            bool ? "True" : "False"
        case let int as Int:
            String(int)
        case let double as Double:
            String(double)
        case let dictionary as [String: Any]:
            "\(dictionary.count) field\(dictionary.count == 1 ? "" : "s")"
        case let array as [Any]:
            "\(array.count) item\(array.count == 1 ? "" : "s")"
        case let dictionary as NSDictionary:
            "\(dictionary.count) field\(dictionary.count == 1 ? "" : "s")"
        case let array as NSArray:
            "\(array.count) item\(array.count == 1 ? "" : "s")"
        default:
            "Open this value"
        }
    }
}

/// On-demand, bounded reader for the exact durable result owned by the server.
///
/// The primary view is a readable field browser. Raw JSON and integrity
/// metadata are subordinate technical details so large objects never become an
/// empty or arbitrarily clipped container in the result sheet.
struct WorkerResultInspectorSheet: View {
    let invocationId: String
    let repository: any WorkerKernelRepository
    let showsTechnicalDetails: Bool

    @State private var locations: [WorkerResultLocation]
    @State private var chunk: WorkerResultChunkDTO?
    @State private var isLoading = false
    @State private var error: String?
    @State private var showTechnicalDetails = false

    private var location: WorkerResultLocation {
        locations.last ?? WorkerResultLocation(pointer: "", offset: 0)
    }

    init(
        invocationId: String,
        repository: any WorkerKernelRepository,
        initialPointer: String = "",
        showsTechnicalDetails: Bool = true
    ) {
        self.invocationId = invocationId
        self.repository = repository
        self.showsTechnicalDetails = showsTechnicalDetails
        _locations = State(
            initialValue: [WorkerResultLocation(pointer: initialPointer, offset: 0)]
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if isLoading {
                        ProgressView("Loading durable result…")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    } else if let chunk {
                        if location.pointer.isEmpty {
                            resultSummary(chunk.reference)
                        } else {
                            resultPath
                        }
                        resultContent(chunk)
                        resultNavigation(chunk)
                        if showsTechnicalDetails {
                            technicalDetailsLink
                        }
                    } else if let error {
                        WorkerConsoleErrorBanner(message: error)
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Worker Result", color: .tronSuccess)
                }
                ToolbarItem(placement: .topBarLeading) {
                    if locations.count > 1 {
                        Button {
                            locations.removeLast()
                        } label: {
                            Image(systemName: "arrow.backward")
                        }
                        .accessibilityLabel("Previous result path or page")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronSuccess)
                }
            }
            .sheet(isPresented: $showTechnicalDetails) {
                if let chunk {
                    WorkerResultTechnicalSheet(chunk: chunk)
                }
            }
            .task(id: "\(invocationId)|\(location.pointer)|\(location.offset)") {
                await load()
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronSuccess)
    }

    private func resultSummary(_ reference: WorkerResultReferenceDTO) -> some View {
        let result = WorkerRunGraphPresentation.resultPresentation(reference.preview)
        return VStack(alignment: .leading, spacing: 8) {
            if let status = result.status {
                Text(status.uppercased())
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(.tronSuccess)
            }
            Text(result.summary)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Label(byteCount(reference.sizeBytes), systemImage: "externaldrive")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
        }
        .padding(.bottom, 4)
        .accessibilityIdentifier("worker-result-readable-summary")
    }

    private var resultPath: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SELECTED FIELD")
                .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
            Text(location.pointer)
                .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func resultContent(_ chunk: WorkerResultChunkDTO) -> some View {
        let fields = WorkerResultInspectorPresentation.fields(in: chunk)
        if !fields.isEmpty {
            WorkerConsoleSection(
                title: location.pointer.isEmpty ? "Result fields" : "Fields",
                detail: "Open a field to load only that value from the durable result.",
                accent: .tronPurple
            ) {
                VStack(spacing: 0) {
                    ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                        if index > 0 {
                            WorkerMetadataDivider()
                        }
                        resultField(field)
                    }
                }
            }
        } else if let text = WorkerResultInspectorPresentation.primitiveText(chunk.value) {
            WorkerConsoleSection(
                title: location.pointer.isEmpty ? "Result" : "Value",
                detail: "Exact schema-validated value.",
                accent: .tronCyan
            ) {
                Text(text)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if WorkerResultInspectorPresentation.isEmptyCollection(chunk.value) {
            WorkerConsoleInlineEmptyState(
                symbol: "tray",
                text: "This result contains an empty collection."
            )
        } else if chunk.value.isNull {
            WorkerConsoleInlineEmptyState(
                symbol: "nosign",
                text: "This result path has no value."
            )
        }
    }

    private func resultField(_ field: WorkerResultFieldPresentation) -> some View {
        Button {
            locations.append(WorkerResultLocation(pointer: field.pointer, offset: 0))
        } label: {
            HStack(alignment: .center, spacing: 11) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.tronPurple)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    StructuredDataFieldHeader(
                        title: field.label,
                        type: fieldMetadata(field)
                    )
                    Text(field.detail)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func resultNavigation(_ chunk: WorkerResultChunkDTO) -> some View {
        if let nextOffset = chunk.nextOffset {
            Button {
                locations.append(
                    WorkerResultLocation(pointer: chunk.pointer, offset: nextOffset)
                )
            } label: {
                Label("Load next result page", systemImage: "arrow.forward.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .sectionFill(.tronCyan, cornerRadius: 10, subtle: true, interactive: true)
        }
    }

    private var technicalDetailsLink: some View {
        WorkerConsoleSection(
            title: "Technical details",
            detail: "Raw JSON and integrity metadata.",
            accent: .tronSlate
        ) {
            WorkerRunDisclosureRow(
                title: "Open technical details",
                detail: "Selected-path JSON, immutable version, schema, and content digest.",
                symbol: "curlybraces.square",
                accent: .tronSlate
            ) {
                showTechnicalDetails = true
            }
        }
    }

    private func load() async {
        chunk = nil
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            chunk = try await repository.workerResult(
                invocationId: invocationId,
                pointer: location.pointer,
                offset: location.offset,
                limit: 20
            )
        } catch {
            self.error = "Exact worker result could not load: \(error.localizedDescription)"
        }
    }

    private func fieldMetadata(_ field: WorkerResultFieldPresentation) -> String {
        guard let sizeBytes = field.sizeBytes else {
            return field.type
        }
        return "\(field.type) · \(byteCount(sizeBytes))"
    }

    private func byteCount(_ value: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(min(value, UInt64(Int64.max))),
            countStyle: .file
        )
    }
}

private struct WorkerResultTechnicalSheet: View {
    let chunk: WorkerResultChunkDTO

    @State private var showRawJSON = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    WorkerConsoleSection(
                        title: "Result reference",
                        detail: "Integrity and immutable-version evidence.",
                        accent: .tronSlate
                    ) {
                        VStack(spacing: 0) {
                            metadata(
                                "Invocation",
                                chunk.reference.invocationId,
                                length: 18
                            )
                            WorkerMetadataDivider()
                            metadata("Version", chunk.reference.workerVersion, length: 12)
                            WorkerMetadataDivider()
                            metadata("Content", chunk.reference.contentSha256, length: 18)
                            WorkerMetadataDivider()
                            metadata("Schema", chunk.reference.outputSchemaSha256, length: 18)
                            if !chunk.pointer.isEmpty {
                                WorkerMetadataDivider()
                                WorkerMetadataRow(label: "JSON pointer", value: chunk.pointer, isCode: true)
                            }
                        }
                    }

                    WorkerConsoleSection(
                        title: "Raw value",
                        detail: "Exact schema-validated JSON for the selected bounded page.",
                        accent: .tronCyan
                    ) {
                        WorkerRunDisclosureRow(
                            title: "Open raw JSON",
                            detail: chunk.truncated
                                ? "\(chunk.returned) of \(chunk.total) values in this page."
                                : "View or copy the selected JSON value.",
                            symbol: "curlybraces",
                            accent: .tronCyan
                        ) {
                            showRawJSON = true
                        }
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Result Details", color: .tronSlate)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronSlate)
                }
            }
            .sheet(isPresented: $showRawJSON) {
                WorkerJSONDetailSheet(
                    title: "Raw Result JSON",
                    value: chunk.value,
                    accent: .tronCyan
                )
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronSlate)
    }

    private func metadata(_ label: String, _ value: String, length: Int) -> some View {
        WorkerMetadataRow(
            label: label,
            value: WorkerConsolePresentation.compactIdentifier(value, length: length),
            isCode: true
        )
    }
}
