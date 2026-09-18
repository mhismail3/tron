import SwiftUI

/// General, read-only presentation surface for retained extension content.
///
/// Retained widgets are not transcript rows and not ambient composer chrome.
/// A discrete extension event belongs in a notification pill; retained state is
/// only visible when the user opens this sheet. The sheet owns no extension
/// execution and starts no provider work: it renders the content it was given
/// and disappears with the sheet.
struct SessionActivitySheet: View {
    let sessionID: String
    let extensionContent: ExtensionRetainedContent
    let omittedExtensionContentCount: Int
    let processActivities: [SessionProcessActivity]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedProcess: SessionProcessActivity?
    @State private var detent: PresentationDetent = .medium
    @State private var appSettings = AppLocalBehaviorSettings.shared

    var body: some View {
        NavigationStack {
            TimelineView(.animation(minimumInterval: 1, paused: activities.isEmpty || !PresentationClockPolicy.runs(
                surfaceActive: presentationActivity.allowsContinuousAnimation,
                sceneActive: scenePhase == .active
            ))) { context in
                let processes = SessionProcessButtonPolicy.visibleActivities(
                    activities,
                    retentionMinutes: appSettings.subagentRecentFinishedRetentionMinutes,
                    now: context.date
                )
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        let sections = SessionProcessProjection.sections(processes)
                        if !sections.active.isEmpty {
                            processSection("Running subagents", processes: sections.active, now: context.date)
                        }
                        if !extensionContent.isEmpty {
                            retainedContent
                        }
                        if !sections.recent.isEmpty {
                            processSection("Completed subagents", processes: sections.recent, now: context.date)
                        }
                        if sections.active.isEmpty && sections.recent.isEmpty && extensionContent.isEmpty {
                            TronGlassCard(accent: .tronSlate) {
                                TronPlaceholderState(
                                    title: "No activity",
                                    detail: "Running subagents and retained extension content appear here.",
                                    icon: "square.on.square.dashed",
                                    accent: .tronEmerald
                                )
                            }
                        }
                    }
                    .padding(18)
                }
                .tronScrollEdgeChrome()
            }
            .tronNavigationTitle("Activity", accent: .tronEmerald)
            .toolbar { doneToolbar }
        }
        .tronManagedSheet(item: $selectedProcess, identity: { "activity-process.\($0.id)" }) { process in
            ReadOnlySubagentSessionSheet(parentSessionID: sessionID, process: process)
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tronSettingsVisualTheme(accent: .tronEmerald)
        .tronPresentation()
        .accessibilityIdentifier("session-activity-sheet")
    }

    private var activities: [SessionProcessActivity] { processActivities }

    @ViewBuilder
    private func processSection(_ title: String, processes: [SessionProcessActivity], now: Date) -> some View {
        Text(title)
            .font(TronTypography.caption)
            .foregroundStyle(Color.tronTextMuted)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
        ForEach(processes) { process in
            SessionProcessRow(process: process, style: .activity, now: now) {
                selectedProcess = process
            }
        }
    }

    @ViewBuilder
    private var retainedContent: some View {
        Group {
            if omittedExtensionContentCount > 0 {
                ExtensionContentNotice(
                    text: "Some extension content is not shown on this device yet."
                )
            }
            ForEach(extensionContent.producers, id: \.self) { producer in
                ExtensionContentSectionHeader(title: producer)
                ForEach(extensionContent.entries(forProducer: producer)) { entry in
                    ExtensionContentEntryCard(entry: entry)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button { dismiss() } label: {
                Image(systemName: "checkmark")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(Color.tronEmerald)
            }
            .accessibilityLabel("Done")
        }
    }
}

/// Section header follows the same caption/muted treatment as the Subagents
/// sheet's section headers.
private struct ExtensionContentSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(TronTypography.caption)
            .foregroundStyle(Color.tronTextMuted)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One read-only retained entry. Card geometry and internal padding match the
/// existing activity rows so the sheet reads as part of the same system.
private struct ExtensionContentEntryCard: View {
    let entry: ExtensionRetainedContent.Entry

    var body: some View {
        TronGlassCard(accent: .tronEmerald, cornerRadius: 14) {
            entryContent
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var entryContent: some View {
        switch entry.style {
        case .text(let lines):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .combine)
        case .frame(let frame):
            ExtensionFrameView(frame: frame)
        case .status(let text):
            Text(text)
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
        }
    }
}

/// A partial projection is disclosed rather than presented as complete.
private struct ExtensionContentNotice: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(TronTypography.caption)
                .foregroundStyle(Color.tronTextMuted)
            Text(text)
                .font(TronTypography.caption)
                .foregroundStyle(Color.tronTextMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
    }
}
