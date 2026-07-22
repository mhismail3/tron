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
            HStack(spacing: 7) {
                Text(field.name)
                    .font(TronTypography.code(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(field.type)
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .medium))
                    .foregroundStyle(.tronInfo)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .glassEffect(.regular.tint(Color.tronInfo.opacity(0.15)), in: .capsule)
                if field.isRequired {
                    Text("required")
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                        .foregroundStyle(.tronWarning)
                }
                Spacer()
            }
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

            DisclosureGroup {
                WorkerJSONBlock(value: trigger.configuration, accent: color)
                    .padding(.top, 7)
            } label: {
                Text("Configuration")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(color)
            }
            .tint(color)

            if let rotate {
                Button("Rotate webhook token", action: rotate)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronInfo)
                    .disabled(isMutating)
            }
        }
        .padding(11)
        .sectionFill(color, cornerRadius: 10, subtle: true, interactive: false)
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
                    .glassEffect(
                        .regular.tint((versionAction == .restore ? Color.tronEmerald : .tronPurple).opacity(0.16)).interactive(),
                        in: .capsule
                    )
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
    var onCancel: (() -> Void)?

    private var color: Color {
        switch WorkerConsolePresentation.normalized(run.status) {
        case "completed", "succeeded": .tronSuccess
        case "failed", "cancelled": .tronError
        case "running": .tronCyan
        default: .tronWarning
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(WorkerConsolePresentation.displayLabel(run.status))
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text("\(WorkerConsolePresentation.displayLabel(run.triggerKind)) · \(run.attemptCount) attempt\(run.attemptCount == 1 ? "" : "s")")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                }
                Spacer()
                if canCancel, let onCancel {
                    Button("Cancel", role: .destructive, action: onCancel)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .buttonStyle(.plain)
                }
                if let timestamp = WorkerConsolePresentation.timestamp(run.completedAt ?? run.startedAt ?? run.createdAt) {
                    Text(timestamp)
                        .font(TronTypography.sans(size: TronTypography.sizeSM))
                        .foregroundStyle(.tronTextMuted)
                }
            }

            Text(WorkerConsolePresentation.compactIdentifier(run.invocationId, length: 16))
                .font(TronTypography.code(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)

            if let error = run.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronError)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Input")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                    WorkerJSONBlock(value: run.input, accent: color)
                    if let output = run.output {
                        Text("Output")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(.tronTextMuted)
                        WorkerJSONBlock(value: output, accent: color)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Execution detail")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(color)
            }
            .tint(color)
        }
        .padding(11)
        .sectionFill(color, cornerRadius: 10, subtle: true, interactive: false)
    }

    private var canCancel: Bool {
        run.status == "queued" || run.status == "running"
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

    private var color: Color {
        switch WorkerConsolePresentation.normalized(item.severity) {
        case "error", "critical": .tronError
        case "warning": .tronWarning
        default: .tronInfo
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: item.seen ? "tray" : "tray.full.fill")
                    .foregroundStyle(color)
                    .frame(width: 20)
                Text(WorkerConsolePresentation.displayLabel(item.severity))
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                if !item.seen {
                    Text("New")
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                        .foregroundStyle(color)
                }
                Spacer()
                if let timestamp = WorkerConsolePresentation.timestamp(item.createdAt) {
                    Text(timestamp)
                        .font(TronTypography.sans(size: TronTypography.sizeSM))
                        .foregroundStyle(.tronTextMuted)
                }
            }
            WorkerJSONBlock(value: item.result, accent: color)
        }
        .padding(11)
        .sectionFill(color, cornerRadius: 10, subtle: true, interactive: false)
    }
}

struct WorkerAuditCard: View {
    let item: WorkerAuditDTO

    var body: some View {
        DisclosureGroup {
            WorkerJSONBlock(value: item.details, accent: .tronSlate)
                .padding(.top, 8)
        } label: {
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
            }
        }
        .tint(.tronSlate)
        .padding(11)
        .sectionFill(.tronSlate, cornerRadius: 10, subtle: true, interactive: false)
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
                .fixedSize(horizontal: true, vertical: false)
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
