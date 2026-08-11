import SwiftUI
import UIKit

struct AgentAssignmentsSheet: View {
    let ownerSessionId: String
    let agentId: String
    let agentName: String
    let assignments: [AgentAssignmentDTO]
    let nextCursor: String?
    let isLoadingOlder: Bool
    let pageError: String?
    let isMutating: Bool
    let workerRepository: any WorkerKernelRepository
    let agentRepository: any AgentRepository
    let isConnected: Bool
    let onLoadOlder: () -> Void
    let onRetry: (AgentAssignmentDTO) async -> AgentMutationOutcome

    @State private var selectedResult: AgentResultSummaryDTO?
    @State private var retryingAssignmentId: String?
    @State private var mutationError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if assignments.isEmpty {
                        Label("No assignments are recorded.", systemImage: "checklist.unchecked")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                            .padding(13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: false)
                    } else {
                        ForEach(assignments) { assignment in
                            assignmentCard(assignment)
                        }
                    }

                    if let mutationError {
                        WorkerConsoleErrorBanner(message: mutationError)
                    }

                    if let pageError {
                        WorkerConsoleErrorBanner(message: pageError)
                    }

                    if nextCursor != nil, !isLoadingOlder {
                        loadOlderButton("Load older assignments", action: onLoadOlder)
                    } else if isLoadingOlder {
                        SheetLoadingState(label: "Loading older assignments…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Assignments", color: .tronCyan)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronCyan)
                }
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronCyan)
        .sheet(item: $selectedResult) { result in
            AgentResultInspectorSheet(
                result: result,
                ownerSessionId: ownerSessionId,
                agentId: agentId,
                agentRepository: agentRepository,
                workerRepository: workerRepository
            )
        }
    }

    private func assignmentCard(_ assignment: AgentAssignmentDTO) -> some View {
        let accent = SessionAgentsPresentation.statusColor(assignment.status)
        let retry = SessionAgentsPresentation.action("retry", in: assignment.allowedActions)
        return VStack(alignment: .leading, spacing: 10) {
            AgentAssignmentSummaryView(assignment: assignment)
            if let requesterName = assignment.requesterName {
                Text("Requested by \(requesterName)")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            }
            if let result = assignment.result {
                Button { selectedResult = result } label: {
                    Label(result.preview ?? "View durable result", systemImage: "doc.text.magnifyingglass")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tronAmber)
            }
            if let retry {
                let isRetrying = retryingAssignmentId == assignment.assignmentId
                Button { Task { await retryAssignment(assignment) } } label: {
                    HStack(spacing: 7) {
                        if isRetrying {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.tronCyan)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(
                            isRetrying
                                ? "Retrying as a new assignment…"
                                : retry.enabled
                                    ? "Retry as a new assignment"
                                    : retry.disabledReason ?? "Retry unavailable"
                        )
                    }
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(retry.enabled && isConnected && !isMutating ? .tronCyan : .tronTextMuted)
                .disabled(
                    !retry.enabled
                        || !isConnected
                        || isMutating
                        || retryingAssignmentId != nil
                )
            }
        }
        .padding(12)
        .sectionFill(accent, cornerRadius: 12, subtle: true, interactive: false)
    }

    private func retryAssignment(_ assignment: AgentAssignmentDTO) async {
        guard retryingAssignmentId == nil, !isMutating else { return }
        retryingAssignmentId = assignment.assignmentId
        mutationError = nil
        defer { retryingAssignmentId = nil }
        let outcome = await onRetry(assignment)
        if !outcome.succeeded {
            mutationError = outcome.errorMessage ?? "The assignment could not be retried."
        }
    }

    private func loadOlderButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "clock.arrow.circlepath")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: true)
    }
}

struct AgentMessagesSheet: View {
    let ownerSessionId: String
    let agentId: String
    let agentName: String
    let messages: [AgentMessageSummaryDTO]
    let nextCursor: String?
    let isLoadingOlder: Bool
    let pageError: String?
    let repository: any AgentRepository
    let onLoadOlder: () -> Void

    @State private var selectedMessage: AgentMessageSummaryDTO?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if messages.isEmpty {
                        Label("No agent messages are recorded.", systemImage: "bubble.left.and.bubble.right")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                            .padding(13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: false)
                    } else {
                        ForEach(messages) { message in
                            messageCard(message)
                        }
                    }
                    if let pageError {
                        WorkerConsoleErrorBanner(message: pageError)
                    }
                    if nextCursor != nil, !isLoadingOlder {
                        Button(action: onLoadOlder) {
                            Label("Load older messages", systemImage: "clock.arrow.circlepath")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: true)
                    } else if isLoadingOlder {
                        SheetLoadingState(label: "Loading older messages…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Communication", color: .tronPurple)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronPurple)
                }
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronPurple)
        .sheet(item: $selectedMessage) { message in
            AgentMessageDetailSheet(
                ownerSessionId: ownerSessionId,
                agentId: agentId,
                message: message,
                repository: repository
            )
        }
    }

    private func messageCard(_ message: AgentMessageSummaryDTO) -> some View {
        let outgoing = message.direction == "outgoing"
        let accent: Color = outgoing ? .tronCyan : .tronPurple
        return Button { selectedMessage = message } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: outgoing ? "arrow.up.right.circle" : "arrow.down.left.circle")
                    .foregroundStyle(accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(outgoing ? "To \(message.otherAgentName ?? "agent")" : "From \(message.otherAgentName ?? "agent")")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronTextPrimary)
                        Spacer(minLength: 8)
                        Text(SessionAgentsPresentation.displayLabel(message.kind))
                            .font(TronTypography.pillValue)
                            .foregroundStyle(accent)
                    }
                    Text(message.preview)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(3)
                    Text("\(SessionAgentsPresentation.displayLabel(message.provenance)) · \(SessionAgentsPresentation.displayLabel(message.deliveryState))")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        }
        .buttonStyle(.plain)
        .sectionFill(accent, cornerRadius: 12, subtle: true, interactive: true)
    }
}

private struct AgentMessageDetailSheet: View {
    let ownerSessionId: String
    let agentId: String
    let message: AgentMessageSummaryDTO
    let repository: any AgentRepository

    @State private var detail: AgentMessageDetailDTO?
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let detail {
                        WorkerConsoleSection(
                            title: "Message",
                            detail: "Exact durable content with direction and Engine-authored provenance.",
                            accent: .tronPurple
                        ) {
                            Text(detail.content)
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                                .foregroundStyle(.tronTextPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        WorkerConsoleSection(
                            title: "Delivery",
                            detail: "Correlation and observation evidence.",
                            accent: .tronCyan
                        ) {
                            WorkerMetadataRow(label: "Kind", value: SessionAgentsPresentation.displayLabel(detail.kind))
                            WorkerMetadataDivider()
                            WorkerMetadataRow(label: "Provenance", value: SessionAgentsPresentation.displayLabel(detail.provenance))
                            WorkerMetadataDivider()
                            WorkerMetadataRow(label: "State", value: SessionAgentsPresentation.displayLabel(detail.deliveryState))
                            if let assignmentId = detail.assignmentId {
                                WorkerMetadataDivider()
                                WorkerMetadataRow(label: "Assignment", value: assignmentId, isCode: true)
                            }
                            if let replyTo = detail.replyTo {
                                WorkerMetadataDivider()
                                WorkerMetadataRow(label: "Replies to", value: replyTo, isCode: true)
                            }
                        }
                    } else if isLoading {
                        SheetLoadingState(label: "Loading exact message…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
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
                    SheetTitle(title: "Agent Message", color: .tronPurple)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronPurple)
                }
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronPurple)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await repository.agentMessageDetail(
                ownerSessionId: ownerSessionId,
                agentId: agentId,
                messageId: message.messageId
            )
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AgentResultInspectorSheet: View {
    let result: AgentResultSummaryDTO
    let ownerSessionId: String
    let agentId: String
    let agentRepository: any AgentRepository
    let workerRepository: any WorkerKernelRepository

    var body: some View {
        if let resultId = result.resultId {
            AgentPagedResultInspectorSheet(
                ownerSessionId: ownerSessionId,
                agentId: agentId,
                resultId: resultId,
                repository: agentRepository
            )
        } else if let invocationId = result.workerInvocationId {
            WorkerResultInspectorSheet(invocationId: invocationId, repository: workerRepository)
        } else {
            NavigationStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        WorkerConsoleSection(
                            title: SessionAgentsPresentation.displayLabel(result.status),
                            detail: result.preview ?? "Durable assignment result",
                            accent: SessionAgentsPresentation.statusColor(result.status)
                        ) {
                            if let value = result.value {
                                Text(Self.prettyJSON(value))
                                    .font(TronTypography.code(size: TronTypography.sizeCaption))
                                    .foregroundStyle(.tronTextPrimary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("The result is retained by the Engine. This server did not include an inline value or a readable result reference.")
                                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                    .foregroundStyle(.tronTextSecondary)
                            }
                        }
                    }
                    .padding(18)
                }
                .scrollContentBackground(.hidden)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        SheetTitle(title: "Agent Result", color: .tronAmber)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        SheetDismissButton(color: .tronAmber)
                    }
                }
            }
            .workerConsoleSheetPresentation()
            .tint(.tronAmber)
        }
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

private struct AgentResultLocation: Hashable {
    let pointer: String
    let offset: UInt64
}

private struct AgentResultField: Identifiable {
    let pointer: String
    let label: String
    let type: String
    let preview: String
    let sizeBytes: UInt64?

    var id: String { pointer }
}

/// Bounded, on-demand browser for a reusable-agent assignment result. It
/// mirrors the Worker result inspector but addresses the shared result store
/// by opaque `resultId`, preserving integrity and paging for non-worker work.
private struct AgentPagedResultInspectorSheet: View {
    let ownerSessionId: String
    let agentId: String
    let resultId: String
    let repository: any AgentRepository
    var initialPointer: String = ""
    var title = "Agent Result"

    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State private var locations: [AgentResultLocation]
    @State private var chunk: AgentResultChunkDTO?
    @State private var isLoading = false
    @State private var error: String?
    @State private var selectedField: AgentResultField?
    @State private var showTechnical = false
    @State private var loadGeneration = 0
    @State private var projectionOwnerId: UUID?

    init(
        ownerSessionId: String,
        agentId: String,
        resultId: String,
        repository: any AgentRepository,
        initialPointer: String = "",
        title: String = "Agent Result"
    ) {
        self.ownerSessionId = ownerSessionId
        self.agentId = agentId
        self.resultId = resultId
        self.repository = repository
        self.initialPointer = initialPointer
        self.title = title
        _locations = State(initialValue: [
            AgentResultLocation(pointer: initialPointer, offset: 0),
        ])
    }

    private var location: AgentResultLocation {
        locations.last ?? AgentResultLocation(pointer: initialPointer, offset: 0)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if isLoading, chunk == nil {
                        SheetLoadingState(label: "Loading durable result…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else if let chunk {
                        if location.pointer.isEmpty {
                            resultSummary(chunk.reference)
                        }
                        resultContent(chunk)
                        resultNavigation(chunk)
                        Button { showTechnical = true } label: {
                            Label("Integrity and technical details", systemImage: "checkmark.shield")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tronTextMuted)
                    } else if let error {
                        Button { Task { await load() } } label: {
                            WorkerConsoleErrorBanner(message: error)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: title, color: .tronSuccess)
                }
                ToolbarItem(placement: .topBarLeading) {
                    if locations.count > 1 {
                        Button { locations.removeLast() } label: {
                            Image(systemName: "arrow.backward")
                        }
                        .accessibilityLabel("Previous result path or page")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronSuccess)
                }
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronSuccess)
        .sheet(item: $selectedField) { field in
            AgentPagedResultInspectorSheet(
                ownerSessionId: ownerSessionId,
                agentId: agentId,
                resultId: resultId,
                repository: repository,
                initialPointer: field.pointer,
                title: field.label
            )
        }
        .sheet(isPresented: $showTechnical) {
            if let chunk {
                AgentResultTechnicalSheet(chunk: chunk)
            }
        }
        .task(id: AgentResultRefreshKey(
            resultId: resultId,
            pointer: location.pointer,
            offset: location.offset,
            continuity: dependencies.connectionRepository.continuity
        )) {
            let ownerId = dependencies.connectionRepository.continuityOwnerId
            if let projectionOwnerId, projectionOwnerId != ownerId {
                dismiss()
                return
            }
            projectionOwnerId = ownerId
            await load()
        }
    }

    private func resultSummary(_ reference: AgentResultReferenceDTO) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(reference.preview.isEmpty ? "Durable assignment result" : reference.preview)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Label(ByteCountFormatter.string(
                fromByteCount: Int64(clamping: reference.sizeBytes),
                countStyle: .file
            ), systemImage: "externaldrive")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func resultContent(_ chunk: AgentResultChunkDTO) -> some View {
        let fields = fields(in: chunk)
        if !fields.isEmpty {
            WorkerConsoleGroup(
                title: location.pointer.isEmpty ? "Result fields" : "Fields",
                detail: "Open one field at a time; large collections remain paged."
            ) {
                ForEach(fields) { field in
                    Button { selectedField = field } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundStyle(.tronSuccess)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(field.label)
                                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                    .foregroundStyle(.tronTextPrimary)
                                Text(field.preview)
                                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                    .foregroundStyle(.tronTextSecondary)
                                    .lineLimit(3)
                                Text(field.type)
                                    .font(TronTypography.pillValue)
                                    .foregroundStyle(.tronTextMuted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(11)
                    }
                    .buttonStyle(.plain)
                    .sectionFill(.tronSuccess, cornerRadius: 11, subtle: true, interactive: true)
                }
            }
        } else {
            WorkerConsoleSection(
                title: location.pointer.isEmpty ? "Result" : pointerLabel(location.pointer),
                detail: "Exact value at this result path.",
                accent: .tronSuccess
            ) {
                Text(preview(chunk.value.value, expanded: true))
                    .font(TronTypography.code(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func resultNavigation(_ chunk: AgentResultChunkDTO) -> some View {
        if let nextOffset = chunk.nextOffset {
            Button {
                locations.append(AgentResultLocation(pointer: chunk.pointer, offset: nextOffset))
            } label: {
                Label(
                    "Load next page (\(chunk.offset + chunk.returned) of \(chunk.total))",
                    systemImage: "arrow.right.circle"
                )
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .sectionFill(.tronSuccess, cornerRadius: 12, subtle: true, interactive: true)
        }
    }

    private func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let loaded = try await repository.agentResult(
                ownerSessionId: ownerSessionId,
                agentId: agentId,
                resultId: resultId,
                pointer: location.pointer,
                offset: location.offset,
                limit: 20
            )
            guard generation == loadGeneration, !Task.isCancelled else { return }
            chunk = loaded
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            self.error = error.localizedDescription
        }
    }

    private func fields(in chunk: AgentResultChunkDTO) -> [AgentResultField] {
        if !chunk.children.isEmpty {
            return chunk.children.map {
                AgentResultField(
                    pointer: $0.pointer,
                    label: pointerLabel($0.pointer),
                    type: SessionAgentsPresentation.displayLabel($0.type),
                    preview: $0.preview.isEmpty ? "Open this field" : $0.preview,
                    sizeBytes: $0.sizeBytes
                )
            }
        }
        guard let dictionary = chunk.value.dictionaryValue else { return [] }
        return dictionary.keys.sorted().map { key in
            let value = dictionary[key] ?? NSNull()
            return AgentResultField(
                pointer: appending(key, to: chunk.pointer),
                label: SessionAgentsPresentation.displayLabel(key),
                type: valueType(value),
                preview: preview(value, expanded: false),
                sizeBytes: nil
            )
        }
    }

    private func appending(_ component: String, to pointer: String) -> String {
        let escaped = component.replacingOccurrences(of: "~", with: "~0")
            .replacingOccurrences(of: "/", with: "~1")
        return pointer + "/" + escaped
    }

    private func pointerLabel(_ pointer: String) -> String {
        guard let component = pointer.split(separator: "/").last else { return "Result" }
        return SessionAgentsPresentation.displayLabel(
            String(component)
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
        )
    }

    private func valueType(_ value: Any) -> String {
        switch value {
        case is NSNull: "Null"
        case is Bool: "Boolean"
        case is Int, is Double: "Number"
        case is String: "Text"
        case is [Any]: "List"
        case is [String: Any]: "Object"
        default: "Value"
        }
    }

    private func preview(_ value: Any, expanded: Bool) -> String {
        if value is NSNull { return "null" }
        if let string = value as? String {
            return expanded ? string : string.truncated(to: 240)
        }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let number = value as? NSNumber { return number.stringValue }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: expanded ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
              ) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self).truncated(to: expanded ? 20_000 : 240)
    }
}

private struct AgentResultRefreshKey: Equatable {
    let resultId: String
    let pointer: String
    let offset: UInt64
    let continuity: EngineConnectionContinuity
}

private struct AgentResultTechnicalSheet: View {
    let chunk: AgentResultChunkDTO

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    WorkerConsoleSection(
                        title: "Integrity",
                        detail: "Server-owned reference for the exact immutable assignment result.",
                        accent: .tronTextMuted
                    ) {
                        WorkerMetadataRow(label: "Result", value: chunk.reference.resultId, isCode: true)
                        WorkerMetadataDivider()
                        WorkerMetadataRow(label: "SHA-256", value: chunk.reference.contentSha256, isCode: true)
                        WorkerMetadataDivider()
                        WorkerMetadataRow(label: "Bytes", value: "\(chunk.reference.sizeBytes)")
                        WorkerMetadataDivider()
                        WorkerMetadataRow(label: "Path", value: chunk.pointer.isEmpty ? "/" : chunk.pointer, isCode: true)
                        WorkerMetadataDivider()
                        WorkerMetadataRow(label: "Page", value: "\(chunk.offset) · \(chunk.returned) of \(chunk.total)")
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Result Details", color: .tronTextMuted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronTextMuted)
                }
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronTextMuted)
    }
}

struct AgentOperatorMessageSheet: View {
    let agentName: String
    let isBusy: Bool
    let onSend: (String) async -> AgentMutationOutcome

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var isSending = false
    @State private var mutationError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Instruction")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(.tronTextMuted)
                        Text("Sent with Operator provenance. It enters at the next safe boundary and cannot expand the agent’s authority.")
                            .font(TronTypography.sans(size: TronTypography.sizeSM))
                            .foregroundStyle(.tronTextSecondary)
                        TextEditor(text: $content)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextPrimary)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 140)
                            .padding(9)
                            .sectionFill(.tronSlate, cornerRadius: 10, subtle: true, interactive: false)
                    }
                    if let mutationError {
                        WorkerConsoleErrorBanner(message: mutationError)
                    }
                    TronPrimaryActionButton(
                        title: "Send to \(agentName)",
                        systemImage: "paperplane.fill",
                        accent: .tronEmerald,
                        isBusy: isSending || isBusy,
                        isEnabled: !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        Task { await send() }
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Operator Instruction", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronEmerald)
    }

    private func send() async {
        guard !isSending else { return }
        isSending = true
        mutationError = nil
        defer { isSending = false }
        let outcome = await onSend(content)
        if outcome.succeeded {
            dismiss()
        } else {
            mutationError = outcome.errorMessage ?? "The instruction could not be sent."
        }
    }
}

struct AgentConfigurationSheet: View {
    let agentName: String
    let limits: [AgentLimitDTO]
    let writeScopes: [AgentWriteScopeDTO]
    let isBusy: Bool
    let onSave: (AnyCodable) async -> AgentMutationOutcome

    @Environment(\.dismiss) private var dismiss
    @State private var maxTurns = ""
    @State private var maxMinutes = ""
    @State private var scopes = ""
    @State private var isSaving = false
    @State private var mutationError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    AgentFormField(
                        title: "Maximum turns",
                        detail: "Applies to future assignments and remains subject to the server hard ceiling.",
                        text: $maxTurns,
                        keyboard: .numberPad
                    )
                    AgentFormField(
                        title: "Maximum minutes",
                        detail: "Wall-clock ceiling for future assignments.",
                        text: $maxMinutes,
                        keyboard: .numberPad
                    )
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Write scopes")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(.tronTextMuted)
                        Text("One canonical workspace-relative path prefix per line. Broadening remains bounded by your own grant.")
                            .font(TronTypography.sans(size: TronTypography.sizeSM))
                            .foregroundStyle(.tronTextSecondary)
                        TextEditor(text: $scopes)
                            .font(TronTypography.code(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextPrimary)
                            .scrollContentBackground(.hidden)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .frame(minHeight: 110)
                            .padding(9)
                            .sectionFill(.tronSlate, cornerRadius: 10, subtle: true, interactive: false)
                    }
                    if let mutationError {
                        WorkerConsoleErrorBanner(message: mutationError)
                    }
                    TronPrimaryActionButton(
                        title: "Save defaults",
                        systemImage: "checkmark.circle.fill",
                        accent: .tronCyan,
                        isBusy: isSaving || isBusy
                    ) { Task { await save() } }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Configure \(agentName)", color: .tronCyan)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronCyan)
                }
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronCyan)
        .onAppear {
            maxTurns = limitValue(named: "max_turns")
            maxMinutes = limitValue(named: "max_minutes")
            scopes = writeScopes.map(\.path).joined(separator: "\n")
        }
    }

    private func limitValue(named name: String) -> String {
        guard let value = limits.first(where: { $0.name == name })?.limit else { return "" }
        return String(Int(value))
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        mutationError = nil
        defer { isSaving = false }
        var limitValues: [String: Any] = [:]
        if let turns = Int(maxTurns), turns > 0 { limitValues["maxTurns"] = turns }
        if let minutes = Int(maxMinutes), minutes > 0 { limitValues["maxMinutes"] = minutes }
        let paths = scopes.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let payload = AnyCodable([
            "limits": limitValues,
            "writeScopes": paths,
        ])
        let outcome = await onSave(payload)
        if outcome.succeeded {
            dismiss()
        } else {
            mutationError = outcome.errorMessage ?? "The agent defaults could not be saved."
        }
    }
}

private struct AgentFormField: View {
    let title: String
    let detail: String
    @Binding var text: String
    let keyboard: UIKeyboardType

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
            Text(detail)
                .font(TronTypography.sans(size: TronTypography.sizeSM))
                .foregroundStyle(.tronTextSecondary)
            TextField("Inherit server default", text: $text)
                .keyboardType(keyboard)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .padding(11)
                .sectionFill(.tronSlate, cornerRadius: 10, subtle: true, interactive: false)
        }
    }
}

struct AgentManagementAccessSheet: View {
    let agentName: String
    let contacts: [AgentLineageItemDTO]
    let allowedActions: [AgentAllowedActionDTO]
    let isConnected: Bool
    let isBusy: Bool
    let onSave: (String, AnyCodable) async -> AgentMutationOutcome

    @Environment(\.dismiss) private var dismiss
    @State private var mode = "grant_management"
    @State private var selectedAgentId = ""
    @State private var canAssign = true
    @State private var canCancel = false
    @State private var canConfigure = false
    @State private var canClose = false
    @State private var isSaving = false
    @State private var mutationError: String?

    private var availableModes: [AgentAllowedActionDTO] {
        ["grant_management", "revoke_management"].compactMap { action in
            SessionAgentsPresentation.action(action, in: allowedActions)
        }
    }

    private var selectedAuthorization: AgentAllowedActionDTO? {
        availableModes.first { $0.action == mode }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if availableModes.count > 1 {
                        Picker("Action", selection: $mode) {
                            ForEach(availableModes) { authorization in
                                Text(authorization.action == "grant_management" ? "Grant" : "Revoke")
                                    .tag(authorization.action)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    if let reason = selectedAuthorization?.disabledReason,
                       selectedAuthorization?.enabled != true {
                        Label(reason, systemImage: "info.circle")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: false)
                    }

                    if contacts.isEmpty {
                        Label(
                            "No related agents are eligible for management access.",
                            systemImage: "person.crop.circle.badge.xmark"
                        )
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                            .padding(13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: false)
                    } else {
                        WorkerConsoleSection(
                            title: "Agent",
                            detail: "Management access is bounded to this owned subtree and is non-transitive.",
                            accent: .tronPurple
                        ) {
                            Picker("Related agent", selection: $selectedAgentId) {
                                ForEach(contacts) { contact in
                                    Text("\(contact.name) · \(SessionAgentsPresentation.displayLabel(contact.relationship))")
                                        .tag(contact.agentId)
                                }
                            }
                        }

                        if mode == "grant_management" {
                            WorkerConsoleSection(
                                title: "Rights",
                                detail: "Select only the lifecycle operations this agent needs.",
                                accent: .tronCyan
                            ) {
                                Toggle("Assign work", isOn: $canAssign)
                                WorkerMetadataDivider()
                                Toggle("Cancel work", isOn: $canCancel)
                                WorkerMetadataDivider()
                                Toggle("Configure defaults", isOn: $canConfigure)
                                WorkerMetadataDivider()
                                Toggle("Close agent", isOn: $canClose)
                            }
                        }

                        if let mutationError {
                            WorkerConsoleErrorBanner(message: mutationError)
                        }

                        TronPrimaryActionButton(
                            title: mode == "grant_management" ? "Grant access" : "Revoke access",
                            systemImage: mode == "grant_management" ? "person.badge.key.fill" : "person.crop.circle.badge.minus",
                            accent: mode == "grant_management" ? .tronPurple : .tronError,
                            isBusy: isSaving || isBusy,
                            isEnabled: !selectedAgentId.isEmpty
                                && isConnected
                                && selectedAuthorization?.enabled == true
                        ) { Task { await save() } }
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Management Access", color: .tronPurple)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronPurple)
                }
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronPurple)
        .onAppear {
            mode = availableModes.first(where: \.enabled)?.action
                ?? availableModes.first?.action
                ?? mode
            if selectedAgentId.isEmpty { selectedAgentId = contacts.first?.agentId ?? "" }
        }
    }

    private func save() async {
        guard !isSaving,
              !selectedAgentId.isEmpty,
              isConnected,
              selectedAuthorization?.enabled == true else { return }
        isSaving = true
        mutationError = nil
        defer { isSaving = false }
        let rights = mode == "grant_management" ? [
            canAssign ? "assign" : nil,
            canCancel ? "cancel" : nil,
            canConfigure ? "configure" : nil,
            canClose ? "close" : nil,
        ].compactMap { $0 } : []
        let payload = AnyCodable([
            "targetAgentId": selectedAgentId,
            "rights": rights,
        ])
        let outcome = await onSave(mode, payload)
        if outcome.succeeded {
            dismiss()
        } else {
            mutationError = outcome.errorMessage ?? "Management access could not be changed."
        }
    }
}
