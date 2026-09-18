import SwiftUI

/// Shared compact visual treatment for transcript navigation actions.
/// The glass remains content-sized while the owning button supplies a separate
/// 44-point semantic target.
struct ChatTranscriptPillModifier: ViewModifier {
    var tone: ChatNotificationTone = .accent

    func body(content: Content) -> some View {
        ChatCompactPillSurface(tone: tone, material: .glass, interactive: true) {
            content
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(tone.primaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
}

extension View {
    func chatTranscriptPill(tone: ChatNotificationTone = .accent) -> some View {
        modifier(ChatTranscriptPillModifier(tone: tone))
    }
}

/// One visual language for transcript events that are not conversation turns.
/// Detail-bearing events are buttons with Liquid Glass; informational events
/// remain noninteractive and flat. Error notices use a rounded rectangle so
/// multiline diagnostics do not read like an oversized capsule.
struct ChatNotificationView: View {
    let presentation: ChatNotificationPresentation
    @Environment(AppModel.self) private var model
    @State private var showingDetail = false
    @State private var detailID = UUID()
    @State private var titleMeasurement: ChatCompactPillTitleMeasurement?

    private var showsDetailAction: Bool {
        presentation.extensionGroup != nil || presentation.hasDetailSheet
            || (presentation.expandsOnTruncation && titleMeasurement?.isTruncated == true)
    }

    private var resolvedMaterial: ChatNotificationMaterial {
        showsDetailAction ? .glass : presentation.material
    }

    var body: some View {
        Group {
            if showsDetailAction {
                pill
                    .chatCompactPillInteraction(
                        accessibilityLabel: accessibilityLabel,
                        action: {
                            detailID = UUID()
                            model.lifecycleRecordDiagnostic(event: "detail.tap", message: "detailID=\(detailID) sourceBytes=\(presentation.body?.utf8.count ?? 0)")
                            showingDetail = true
                        }
                    )
                    // Preserve the 44-point semantic row target without making
                    // its empty corners compete with the glass surface gesture.
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint(presentation.expandsOnTruncation ? "Shows the full error message" : "Shows details")
            } else {
                pill
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: 44,
            alignment: presentation.extensionGroup?.containsContext == true ? .trailing : .center
        )
        .contentTransition(.interpolate)
        .accessibilityLabel(accessibilityLabel)
        .onPreferenceChange(ChatCompactPillTitleMeasurementKey.self) { measurements in
            let rendered = measurements.first(where: { $0.renderedWidth > 0 })?.renderedWidth
            let intrinsic = measurements.first(where: { $0.intrinsicWidth > 0 })?.intrinsicWidth
            guard let rendered, let intrinsic else { return }
            let next = ChatCompactPillTitleMeasurement(renderedWidth: rendered, intrinsicWidth: intrinsic)
            guard titleMeasurement != next else { return }
            titleMeasurement = next
        }
        .tronManagedSheet(
            isPresented: $showingDetail,
            identity: "chat.transcript-event-detail.\(presentation.id)"
        ) {
            if let group = presentation.extensionGroup {
                ExtensionChipGroupDetailsSheet(group: group)
            } else {
                detailSheet
            }
        }
    }

    private var pill: some View {
        ChatCompactPillSurface(
            tone: presentation.tone,
            material: resolvedMaterial,
            interactive: showsDetailAction
        ) {
            ChatCompactPillLabel(
                icon: presentation.icon,
                title: presentation.title,
                detail: presentation.detail,
                tone: presentation.tone,
                showsProgress: presentation.showsProgress,
                titleWeight: .semibold,
                detailStyle: presentation.hasDetailSheet ? .summary : .status
            )
        }
    }

    private var accessibilityLabel: String {
        if let group = presentation.extensionGroup {
            return "Extension activity, \(group.events.count) updates"
        }
        return [presentation.title, presentation.detail].compactMap { $0 }.joined(separator: ", ")
    }

    private var detailSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let detail = presentation.detail {
                        Text(detail)
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextSecondary)
                    }
                    if let body = presentation.body {
                        ChatPreparedMarkdownDetail(text: body, detailID: detailID)
                            .padding(14)
                            .modifier(DetailBodySurface(
                                usesGlass: presentation.detailUsesGlassSurface,
                                accent: presentation.tone.surfaceColor
                            ))
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: presentation.title, accent: presentation.tone.surfaceColor)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { showingDetail = false } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}

struct ExtensionChipGroupDetailsSheet: View {
    let group: ChatExtensionChipGroup
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent = .medium
    @State private var technicalDetailsExpanded = false

    private var accent: Color { group.containsContext ? .tronPurple : .tronBlue }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TronSpacing.section) {
                    ForEach(Array(group.events.enumerated()), id: \.offset) { index, event in
                        readableEventSection(event, duplicateOf: duplicateEventIndex(for: event, before: index))
                    }
                    DisclosureGroup(isExpanded: $technicalDetailsExpanded) {
                        LazyVStack(alignment: .leading, spacing: TronSpacing.section) {
                            ForEach(Array(group.events.enumerated()), id: \.offset) { _, event in
                                technicalEventSection(event)
                            }
                        }
                        .padding(.top, TronSpacing.sm)
                    } label: {
                        TronTechnicalSectionLabel("Technical details")
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .tronScrollEdgeChrome()
            // Use the shared inline sheet chrome; a default large title leaves
            // an oversized empty region before the first activity section.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Extension activity", accent: accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(accent)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tronPresentation()
    }

    private func duplicateEventIndex(for event: ChatExtensionChipEvent, before index: Int) -> Int? {
        guard let key = userFacingContentKey(for: event) else { return nil }
        return group.events[..<index].firstIndex { userFacingContentKey(for: $0) == key }
    }

    private func userFacingContentKey(for event: ChatExtensionChipEvent) -> String? {
        ChatExtensionChipContentDeduplicationPolicy.key(for: event)
    }

    private func producer(for event: ChatExtensionChipEvent) -> String {
        event.item?.semantic?.origin.title ?? "Extension"
    }

    private func eventKind(_ event: ChatExtensionChipEvent) -> String {
        switch event {
        case .command: return "command"
        case .context: return "context"
        case .notification: return "notification"
        }
    }

    private func duplicateNote(for event: ChatExtensionChipEvent) -> some View {
        Label("Already shown above; retained as a separate \(eventKind(event)) event.", systemImage: "arrow.triangle.merge")
            .font(TronTypography.secondaryDescription)
            .foregroundStyle(Color.tronTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func readableEventSection(_ event: ChatExtensionChipEvent, duplicateOf: Int?) -> some View {
        switch event {
        case .command(let item):
            let resource = item.semantic?.resourceInvocation
            VStack(alignment: .leading, spacing: TronSpacing.sm) {
                readableHeader("Command", producer: producer(for: event))
                if duplicateOf == nil {
                    readableCard("/\(resource?.name ?? "Extension command")", accent: .tronIndigo)
                    if let arguments = resource?.arguments, !arguments.isEmpty {
                        Text(arguments).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary)
                    }
                } else {
                    duplicateNote(for: event)
                }
                if let lifecycle = item.semantic?.lifecycle?.rawValue {
                    statusLine("Status", ComposerResourceNameFormatter.friendly(lifecycle), accent: CommandLifecyclePresentationPolicy.tone(lifecycle).primaryColor)
                }
                if let error = item.errorMessage, !error.isEmpty {
                    statusLine("Error", error, accent: Color.tronError)
                }
            }
        case .context(let item):
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let goal = InboundContextGoalPresentation.project(item.details)
            VStack(alignment: .leading, spacing: TronSpacing.sm) {
                readableHeader("Context", producer: producer(for: event))
                if duplicateOf == nil {
                    TronMarkdownView(text: text.isEmpty ? "No text content" : text, streaming: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .tronGlassSurface(accent: .tronPurple, tintOpacity: 0.08)
                } else {
                    duplicateNote(for: event)
                }
                // Equal message text does not imply equal state or payload.
                // Keep this event's structured facts even when its prose repeats.
                let status = InboundContextCompactPresentationPolicy.status(details: item.details)
                if goal?.status != status {
                    statusLine("Status", status, accent: .tronPurple)
                }
                if let goal {
                    readableMetadata("Goal", goal.metadata, accent: .tronPurple)
                }
            }
        case .notification(let presentation):
            VStack(alignment: .leading, spacing: TronSpacing.sm) {
                readableHeader("Notification", producer: producer(for: event))
                if let body = presentation.body, !body.isEmpty, duplicateOf == nil {
                    readableCard(body, accent: presentation.tone.surfaceColor)
                } else if duplicateOf != nil {
                    duplicateNote(for: event)
                }
                if let detail = presentation.detail {
                    statusLine("Status", detail, accent: presentation.tone.surfaceColor)
                }
            }
        }
    }

    private func readableHeader(_ title: String, producer: String) -> some View {
        VStack(alignment: .leading, spacing: TronSpacing.xs) {
            TronTechnicalSectionLabel(title)
            Text(producer)
                .font(TronTypography.caption)
                .foregroundStyle(Color.tronTextMuted)
        }
    }

    private func readableCard(_ text: String, accent: Color) -> some View {
        Text(text)
            .font(TronTypography.bodySM)
            .foregroundStyle(Color.tronTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .tronGlassSurface(accent: accent, tintOpacity: 0.08)
    }

    private func readableMetadata(_ title: String, _ items: [TronTechnicalMetadataItem], accent: Color) -> some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            Text(title)
                .font(TronTypography.sheetSectionHeader)
                .foregroundStyle(Color.tronTextPrimary)
            VStack(alignment: .leading, spacing: TronSpacing.sm) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    if item.title == "Objective" {
                        VStack(alignment: .leading, spacing: TronSpacing.xs) {
                            Text(item.title)
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                .foregroundStyle(accent)
                            Text(item.value)
                                .font(TronTypography.secondaryDescription)
                                .foregroundStyle(Color.tronTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: TronSpacing.sm) {
                            Text(item.title)
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                .foregroundStyle(accent)
                            Spacer(minLength: TronSpacing.sm)
                            Text(item.value)
                                .font(TronTypography.secondaryDescription)
                                .foregroundStyle(Color.tronTextSecondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .tronGlassSurface(accent: accent, tintOpacity: 0.08)
        }
    }

    private func statusLine(_ label: String, _ value: String, accent: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: TronSpacing.sm) {
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(accent)
            Text(value)
                .font(TronTypography.secondaryDescription)
                .foregroundStyle(Color.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .tronGlassSurface(accent: accent, tintOpacity: 0.08)
    }

    @ViewBuilder
    private func technicalEventSection(_ event: ChatExtensionChipEvent) -> some View {
        let item = event.item
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            Text("\(eventKind(event).capitalized) · \(producer(for: event))")
                .font(TronTypography.sheetSectionHeader)
                .foregroundStyle(Color.tronTextPrimary)
            if let item {
                extensionIdentity(item, accent: accent)
                rawSection(item, accent: accent)
            }
        }
    }

    @ViewBuilder
    private func rawSection(_ item: TranscriptItem, accent: Color) -> some View {
        let payload = (try? JSONValue.encode(item)) ?? .object([:])
        TronTechnicalJSONRow(
            value: payload,
            title: "Inspect raw event",
            subtitle: ToolTechnicalPayloadSummary.summary(for: payload),
            sheetTitle: "Raw extension event",
            accent: accent
        )
    }

    private func extensionIdentity(_ item: TranscriptItem, accent: Color) -> some View {
        let origin = item.semantic?.origin
        var items: [TronTechnicalMetadataItem] = [
            .init(title: "Producer", value: origin?.title ?? "Extension", icon: "puzzlepiece.extension"),
            .init(title: "Type", value: item.customType ?? item.semantic?.kind.rawValue ?? "unknown", icon: "doc.badge.ellipsis")
        ]
        if let goalID = item.details?.objectValue?["goalId"]?.stringValue {
            items.append(.init(title: "Goal", value: goalID, icon: "target"))
        }
        if let invocationID = item.semantic?.invocationId {
            items.append(.init(title: "Invocation", value: invocationID, icon: "point.3.connected.trianglepath.dotted"))
        }
        if let operationID = item.semantic?.operationId {
            items.append(.init(title: "Operation", value: operationID, icon: "number"))
        }
        items.append(contentsOf: [
            .init(title: "Entry", value: item.id, icon: "number"),
            .init(title: "Timestamp", value: item.timestamp, icon: "clock")
        ])
        return TronTechnicalMetadataSection(title: "Source and identity", items: items, accent: accent)
    }
}

struct DetailBodySurface: ViewModifier {
    let usesGlass: Bool
    let accent: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesGlass {
            content.tronGlassSurface(accent: accent, tintOpacity: 0.08)
        } else {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            content
                .background(accent.opacity(0.10), in: shape)
                .overlay(shape.stroke(accent.opacity(0.30), lineWidth: 0.5))
        }
    }
}

private struct ChatPreparedMarkdownDetail: View {
    let text: String
    let detailID: UUID
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(AppModel.self) private var model
    @State private var preparation = ChatDetailDocumentPreparation()

    var body: some View {
        Group {
            if let document = preparation.document, document.source == text {
                TronMarkdownView(document: document, streaming: false)
                    .onChange(of: preparation.revision, initial: true) { _, _ in
                        preparation.mounted(record: record)
                    }
            } else {
                Text("Preparing details…")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                    .accessibilityLabel("Preparing details")
            }
        }
        .task(id: PresentationActivityTaskID(
            source: text,
            presentationActive: presentationActivity.allowsDataPublication
        )) {
            let activity = presentationActivity
            await preparation.load(source: text, isCurrent: {
                presentationActivity == activity && activity.allowsDataPublication
            }, record: record)
        }
        .onDisappear { preparation.retire(record: record) }
    }

    private func record(_ message: String) {
        model.lifecycleRecordDiagnostic(event: "detail.preparation", message: "detailID=\(detailID) \(message)")
    }
}

struct TranscriptNotice: View {
    let title: String
    var value: String? = nil
    var detailBody: String? = nil
    let icon: String
    let tone: ChatNotificationTone
    var expandsOnTruncation = false
    var animatesEntrance = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed: Bool

    init(
        title: String,
        value: String? = nil,
        detailBody: String? = nil,
        icon: String,
        tone: ChatNotificationTone,
        expandsOnTruncation: Bool = false,
        animatesEntrance: Bool = false
    ) {
        self.title = title
        self.value = value
        self.detailBody = detailBody
        self.icon = icon
        self.tone = tone
        self.expandsOnTruncation = expandsOnTruncation
        self.animatesEntrance = animatesEntrance
        _revealed = State(initialValue: !animatesEntrance)
    }

    var body: some View {
        ChatNotificationView(presentation: .init(
            id: "embedded-notice", semanticID: nil, icon: icon, title: title,
            detail: value, body: detailBody, tone: tone,
            material: .flat, expandsOnTruncation: expandsOnTruncation
        ))
        .opacity(revealed ? 1 : 0)
        .scaleEffect(revealed || reduceMotion ? 1 : 0.98)
        .offset(y: revealed || reduceMotion ? 0 : 3)
        .onAppear {
            guard animatesEntrance, !revealed else { return }
            if reduceMotion { revealed = true }
            else {
                withAnimation(.smooth(duration: 0.24)) { revealed = true }
            }
        }
    }
}
