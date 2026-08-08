import SwiftUI

struct WorkerConsoleSection<Content: View>: View {
    let title: String
    let detail: String
    let accent: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkerConsoleSectionHeader(title: title, detail: detail)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .sectionFill(accent, cornerRadius: 12, subtle: true, interactive: false)
        }
    }
}

/// A labeled group whose children remain first-level sheet containers.
///
/// Use this for collections of independently actionable cards. It avoids a
/// decorative wrapper around cards that already own their own Liquid Glass
/// surface.
struct WorkerConsoleGroup<Content: View>: View {
    let title: String
    let detail: String
    var spacing: CGFloat = 8
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            WorkerConsoleSectionHeader(title: title, detail: detail)
            content()
        }
    }
}

extension View {
    /// Standard presentation policy for worker-console sheets.
    ///
    /// Worker detail surfaces can contain dozens of nested cards. First-level
    /// containers retain Liquid Glass, while nested containers use static
    /// tinted fills to avoid glass-on-glass compositing.
    func workerConsoleSheetPresentation() -> some View {
        firstLevelGlassSectionFills()
            .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
    }
}

struct WorkerConsoleSectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(detail)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct WorkerMetadataRow: View {
    let label: String
    let value: String
    var isCode = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronTextMuted)
            Spacer(minLength: 8)
            Text(value)
                .font(
                    isCode
                        ? TronTypography.code(size: TronTypography.sizeCaption, weight: .medium)
                        : TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium)
                )
                .foregroundStyle(.tronTextPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
    }
}

struct WorkerMetadataDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.tronBorder.opacity(0.6))
            .frame(height: 0.5)
    }
}

struct WorkerSchemaFieldRow: View {
    let field: WorkerInputFieldPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            StructuredDataFieldHeader(
                title: field.name,
                type: WorkerConsolePresentation.displayLabel(field.type),
                qualifier: field.isRequired ? "Required" : nil,
                titleIsCode: true,
                typeColor: .tronInfo
            )
            if let detail = field.detail, !detail.isEmpty {
                Text(detail)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .sectionFill(.tronInfo, cornerRadius: 9, subtle: true, interactive: false)
    }
}

struct WorkerTriggerCard: View {
    let trigger: WorkerTriggerStatusDTO
    let isMutating: Bool
    let rotate: (() -> Void)?

    @State private var showConfiguration = false

    private var color: Color { trigger.enabled ? .tronInfo : .tronTextMuted }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: trigger.enabled ? "alarm.fill" : "alarm")
                    .foregroundStyle(color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(WorkerConsolePresentation.displayLabel(trigger.triggerId))
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text("\(WorkerConsolePresentation.displayLabel(trigger.kind)) · \(trigger.enabled ? "Enabled" : "Disabled")")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                }
                Spacer()
                if trigger.tokenConfigured {
                    Label("Secured", systemImage: "lock.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                        .foregroundStyle(.tronSuccess)
                }
            }

            HStack(spacing: 10) {
                if let nextRun = WorkerConsolePresentation.timestamp(trigger.nextRunAt) {
                    Label(nextRun, systemImage: "calendar")
                }
                Label("Cursor \(trigger.streamCursor)", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronTextMuted)

            Button { showConfiguration = true } label: {
                HStack {
                    Label("Configuration", systemImage: "slider.horizontal.3")
                    Spacer()
                }
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(color)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let rotate {
                Button("Rotate webhook token", action: rotate)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronInfo)
                    .disabled(isMutating)
            }
        }
        .padding(11)
        .sectionFill(color, cornerRadius: 10, subtle: true, interactive: false)
        .sheet(isPresented: $showConfiguration) {
            WorkerJSONDetailSheet(
                title: "Trigger Configuration",
                value: trigger.configuration,
                accent: color
            )
        }
    }
}

struct WorkerVersionRow: View {
    let worker: WorkerSummaryDTO
    let version: WorkerVersionDTO
    let isMutating: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                .foregroundStyle(isActive ? .tronSuccess : .tronPurple)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(WorkerConsolePresentation.compactIdentifier(version.contentHash, length: 12))
                    .font(TronTypography.code(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                if let created = WorkerConsolePresentation.timestamp(version.createdAt) {
                    Text(created)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
            }
            Spacer()
            if let versionAction = WorkerVersionAction.resolve(worker: worker, version: version) {
                Button(versionAction.title, action: action)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(versionAction == .restore ? .tronEmerald : .tronPurple)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background {
                        Capsule().fill(
                            (versionAction == .restore ? Color.tronEmerald : .tronPurple)
                                .opacity(0.13)
                        )
                    }
                    .contentShape(Capsule())
                    .buttonStyle(.plain)
                    .disabled(isMutating)
            } else {
                Text("Active")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronSuccess)
            }
        }
        .padding(.vertical, 8)
    }

    private var isActive: Bool {
        !worker.retired && version.version == worker.activeVersion
    }
}

struct WorkerRunCard: View {
    let run: WorkerInvocationDTO
    var workerName: String?
    var callerWorkerName: String?
    let onOpen: () -> Void

    private var color: Color {
        switch WorkerConsolePresentation.normalized(run.status) {
        case "completed", "succeeded": .tronSuccess
        case "failed", "cancelled": .tronError
        case "running": .tronCyan
        default: .tronWarning
        }
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: statusSymbol)
                    .font(
                        TronTypography.sans(
                            size: TronTypography.sizeBodySM,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(color)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(workerName ?? "Worker run")
                            .font(
                                TronTypography.sans(
                                    size: TronTypography.sizeBodySM,
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(.tronTextPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)

                        Text(WorkerConsolePresentation.displayLabel(run.status))
                            .font(
                                TronTypography.sans(
                                    size: TronTypography.sizeSM,
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(color)
                            .lineLimit(1)
                    }

                    if let error = run.error {
                        Text(error)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronError)
                            .lineLimit(1)
                    } else if let summary = WorkerConsolePresentation.runSummary(run) {
                        Text(summary)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(1)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(
                            WorkerConsolePresentation.runCompactMetadata(
                                run,
                                callerWorkerName: callerWorkerName
                            )
                        )
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                        Spacer(minLength: 6)

                        if let timestamp = WorkerConsolePresentation.timestamp(run.createdAt) {
                            Text(timestamp)
                                .font(TronTypography.sans(size: TronTypography.sizeSM))
                                .foregroundStyle(.tronTextMuted)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .sectionFill(color, cornerRadius: 10, subtle: true, interactive: true)
        }
        .buttonStyle(.plain)
    }

    private var statusSymbol: String {
        switch WorkerConsolePresentation.normalized(run.status) {
        case "completed", "succeeded": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "cancelled": "stop.circle"
        case "running": "waveform.path.ecg"
        default: "clock"
        }
    }
}

struct WorkerInboxCard: View {
    let item: WorkerInboxItemDTO
    var workerName: String?
    let onOpen: () -> Void

    private var color: Color {
        switch WorkerConsolePresentation.normalized(item.severity) {
        case "error", "critical": .tronError
        case "warning": .tronWarning
        default: .tronInfo
        }
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: item.contextAttached ? "tray" : "tray.full.fill")
                    .foregroundStyle(color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(workerName ?? WorkerConsolePresentation.displayLabel(item.severity))
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronTextPrimary)
                            .lineLimit(1)
                        if workerName != nil,
                           WorkerConsolePresentation.normalized(item.severity) != "info" {
                            Text(WorkerConsolePresentation.displayLabel(item.severity))
                                .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                                .foregroundStyle(color)
                        }
                        if !item.contextAttached,
                           item.triggerKind != "manual" {
                            Text("Context pending")
                                .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                                .foregroundStyle(color)
                        }
                    }
                    Text(WorkerConsolePresentation.inboxSummary(item))
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(2)
                    if let timestamp = WorkerConsolePresentation.timestamp(item.createdAt) {
                        Text(timestamp)
                            .font(TronTypography.sans(size: TronTypography.sizeSM))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                Spacer(minLength: 8)
                Text(WorkerConsolePresentation.resultDisposition(item).title)
                    .font(TronTypography.pillValue)
                    .foregroundStyle(WorkerConsolePresentation.resultDisposition(item).color)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(11)
        .sectionFill(color, cornerRadius: 10, subtle: true, interactive: true)
    }
}

extension WorkerResultDisposition {
    var color: Color {
        switch self {
        case .available: .tronInfo
        case .usedByAgent: .tronSuccess
        case .needsAttention: .tronError
        case .resolved: .tronPurple
        }
    }
}

struct WorkerAuditCard: View {
    let item: WorkerAuditDTO

    @State private var showDetail = false

    var body: some View {
        Button { showDetail = true } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "checklist")
                    .foregroundStyle(.tronSlate)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(WorkerConsolePresentation.displayLabel(item.action))
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    if let timestamp = WorkerConsolePresentation.timestamp(item.createdAt) {
                        Text(timestamp)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(11)
        .sectionFill(.tronSlate, cornerRadius: 10, subtle: true, interactive: true)
        .sheet(isPresented: $showDetail) {
            WorkerJSONDetailSheet(
                title: WorkerConsolePresentation.displayLabel(item.action),
                value: item.details,
                accent: .tronSlate
            )
        }
    }
}

struct WorkerJSONBlock: View {
    let value: AnyCodable
    let accent: Color

    var body: some View {
        WorkerCodeBlock(text: WorkerConsoleViewModel.prettyJSON(value), accent: accent)
    }
}

struct WorkerCodeBlock: View {
    let text: String
    let accent: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(TronTypography.code(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                .fixedSize(horizontal: true, vertical: true)
                .textSelection(.enabled)
                .padding(9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(accent, cornerRadius: 8, subtle: true, compact: false, interactive: false)
    }
}

struct WorkerLifecycleButton: View {
    let title: String
    let symbol: String
    let color: Color
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .sectionFill(color, cornerRadius: 9, subtle: true, interactive: true)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

struct WorkerConsoleErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.tronError)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text("Worker state could not fully refresh")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(message)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(.tronError, cornerRadius: 10, subtle: true, interactive: false)
    }
}

/// Non-destructive continuity status shown above a retained server snapshot.
/// The shared transport owns recovery; sheets remain useful and read-only
/// instead of replacing known-good content with an error screen.
struct WorkerConsoleContinuityBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.tronWarning)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text("Reconnecting to engine")
                    .font(TronTypography.sans(
                        size: TronTypography.sizeBodySM,
                        weight: .semibold
                    ))
                    .foregroundStyle(.tronTextPrimary)
                Text("Showing the last server update. This sheet will catch up automatically.")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(.tronWarning, cornerRadius: 10, subtle: true, interactive: false)
    }
}

struct WorkerConsoleLoadingState: View {
    let title: String

    var body: some View {
        VStack(spacing: 9) {
            ProgressView().tint(.tronEmerald)
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }
}

struct WorkerConsoleEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(detail)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 18)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }
}

struct WorkerConsoleInlineEmptyState: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
            .foregroundStyle(.tronTextSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .sectionFill(.tronSlate, cornerRadius: 9, subtle: true, interactive: false)
    }
}

extension WorkerConsoleStatus {
    var color: Color {
        switch kind {
        case .healthy: .tronSuccess
        case .paused: .tronWarning
        case .retired: .tronTextMuted
        case .needsAttention: .tronError
        }
    }
}
