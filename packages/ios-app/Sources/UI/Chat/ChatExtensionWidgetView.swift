import SwiftUI

/// One compact, composer-adjacent affordance per opaque widget group. Groups
/// are intentionally not inferred from package names or display text.
struct ExtensionActivityPill: View {
    let group: ExtensionWidgetGroup
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: group.liveActivityCount > 0 ? "circle.dotted" : (group.isWidgetGroup ? "rectangle.3.group" : "sparkles"))
                Text(group.label).lineLimit(1).truncationMode(.tail)
                let count = max(group.liveActivityCount, group.items.count)
                if count > 1 { Text("\(count)").font(TronTypography.caption) }
            }
            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
            .foregroundStyle(Color.tronEmerald)
            .padding(.horizontal, 11).padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .tronGlassSurface(accent: .tronEmerald, cornerRadius: 14, tintOpacity: 0.13, interactive: true)
        .accessibilityLabel("Extension: \(group.label)")
        .accessibilityHint("Opens live extension details")
        .accessibilityIdentifier("extension-pill-\(group.id)")
    }
}

struct ExtensionDetailsSheet: View {
    let sessionID: String
    let groupID: String?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedActivity: ExtensionRunActivity?

    init(sessionID: String, groupID: String? = nil) { self.sessionID = sessionID; self.groupID = groupID }

    private var snapshot: SessionSnapshot? { model.authoritativeSnapshot(for: sessionID) }
    private var presentation: ExtensionPresentationState? { snapshot?.extensionPresentation }
    private var groups: [ExtensionWidgetGroup] {
        guard let presentation else { return [] }
        return ChatExtensionWidgetPolicy.groups(
            presentation,
            executions: snapshot?.toolExecutions ?? [],
            activities: snapshot?.extensionActivities ?? []
        )
    }
    private var selectedGroup: ExtensionWidgetGroup? {
        guard let groupID else { return nil }
        return groups.first(where: { $0.id == groupID })
    }
    private var isExpanded: Bool { presentation?.semanticState.toolsExpanded ?? false }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: TronSpacing.lg) {
                    if let group = selectedGroup {
                        groupSection(group)
                    } else if groups.isEmpty {
                        settledState
                    } else {
                        ForEach(groups) { group in
                            groupSection(group)
                        }
                    }
                }
                .padding(.horizontal, TronSpacing.section)
                .padding(.top, TronSpacing.md).padding(.bottom, TronSpacing.xl)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: selectedGroup?.label ?? "Extension Activity") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(Color.tronEmerald)
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .accessibilityIdentifier("extension-details-sheet")
        .onChange(of: groups) { _, updatedGroups in
            guard let selectedActivity else { return }
            self.selectedActivity = updatedGroups
                .flatMap(\.activities)
                .first(where: { $0.id == selectedActivity.id })
        }
        .sheet(item: $selectedActivity) { activity in
            ExtensionRunDetailsSheet(activity: activity)
        }
    }

    @ViewBuilder private func groupSection(_ group: ExtensionWidgetGroup) -> some View {
        if !group.activities.isEmpty { activitySection(group.activities) }
        if !group.statuses.isEmpty { statusSection(group.statuses) }
        if !group.services.isEmpty { serviceSection(group.services) }
        if !group.items.isEmpty {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(group.items) { item in
                    switch item.content {
                    case .semantic(let widget):
                        ExtensionWidgetView(widget: widget, isExpanded: isExpanded) { toggleExpanded() }
                    case .surface(let surface):
                        ExtensionSurfaceWidgetView(surface: surface, isExpanded: isExpanded) { toggleExpanded() }
                    }
                }
            }
        }
    }

    private func activitySection(_ activities: [ExtensionRunActivity]) -> some View {
        TronSettingsGroup("Live runs", detail: "Structured progress from extension-owned work.", accent: .tronEmerald) {
            VStack(spacing: 0) {
                ForEach(activities) { activity in
                    Button { selectedActivity = activity } label: {
                        HStack(spacing: 10) {
                            Image(systemName: activity.isLive ? "circle.dotted" : (activity.status == .failed ? "exclamationmark.triangle.fill" : "checkmark.circle"))
                                .foregroundStyle(activity.status == .failed ? Color.tronError : Color.tronEmerald)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(activity.title)
                                    .font(TronTypography.bodySM)
                                    .foregroundStyle(Color.tronTextPrimary)
                                    .lineLimit(1)
                                Text(activitySummary(activity))
                                    .font(TronTypography.caption)
                                    .foregroundStyle(Color.tronTextMuted)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(TronTypography.caption)
                                .foregroundStyle(Color.tronTextMuted)
                        }
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(activity.title), \(activitySummary(activity))")
                    if activity.id != activities.last?.id { TronSettingsDivider(accent: .tronEmerald) }
                }
            }
        }
    }

    private func activitySummary(_ activity: ExtensionRunActivity) -> String {
        let state = switch activity.status {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        }
        let metrics = [
            activity.currentTool.map { "\($0)" },
            activity.toolCount.map { "\($0) tools" },
            activity.turnCount.map { "\($0) turns" },
            activity.durationMs.map { durationLabel($0) },
        ].compactMap { $0 }
        return ([state] + metrics).joined(separator: " · ")
    }

    private func durationLabel(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds) / 1_000
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private func statusSection(_ statuses: [ExtensionActivityStatus]) -> some View {
        TronSettingsGroup("Status", detail: "Live information published by the extension.", accent: .tronEmerald) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(statuses) { status in
                    HStack(alignment: .top, spacing: TronSpacing.sm) {
                        Text(status.displayKey).font(TronTypography.caption).foregroundStyle(Color.tronTextMuted).frame(minWidth: 70, alignment: .leading)
                        Text(status.value).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 8).accessibilityElement(children: .combine).accessibilityLabel("\(status.key): \(status.value)")
                }
            }
        }
    }

    private func serviceSection(_ services: [ExtensionActivityServiceItem]) -> some View {
        TronSettingsGroup("Extension activity", detail: "Service work remains grouped outside the conversation.", accent: .tronTeal) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(services) { service in
                    HStack(spacing: 10) {
                        Image(systemName: service.error ? "exclamationmark.triangle.fill" : (service.status == "Running" ? "circle.dotted" : "checkmark.circle")).foregroundStyle(service.error ? Color.tronError : Color.tronTeal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.title).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary).lineLimit(1)
                            Text("\(service.status) · \(service.source)").font(TronTypography.caption).foregroundStyle(Color.tronTextMuted)
                        }
                        Spacer(minLength: 0)
                    }.accessibilityElement(children: .combine).accessibilityLabel("\(service.title), \(service.status)")
                }
            }
        }
    }

    private var settledState: some View {
        VStack(spacing: TronSpacing.sm) {
            Image(systemName: "sparkles").font(TronTypography.sans(size: 30, weight: .medium)).foregroundStyle(Color.tronTextMuted)
            Text("No extension details").font(TronTypography.sans(size: 22, weight: .semibold)).foregroundStyle(Color.tronTextPrimary)
            Text("This extension activity has settled or is no longer mounted.").font(TronTypography.bodySM).foregroundStyle(Color.tronTextMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 42).accessibilityElement(children: .combine)
    }

    private func toggleExpanded() {
        guard let presentation else { return }
        let next = !presentation.semanticState.toolsExpanded
        Task {
            do {
                try await model.setExtensionToolsExpanded(sessionID: sessionID, hostEpoch: presentation.hostEpoch, presentationRevision: presentation.revision, expanded: next)
            } catch let failure as GatewayFailure
                where failure.message.localizedCaseInsensitiveContains("presentation epoch is stale")
                    || failure.message.localizedCaseInsensitiveContains("presentation revision is stale") {
                // A newer authoritative presentation already owns the control.
                // The next live snapshot supplies the converged state.
            } catch {
                model.presentConfigurationActionError(error)
            }
        }
    }
}

struct ExtensionRunDetailsSheet: View {
    let activity: ExtensionRunActivity
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: TronSpacing.lg) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        summaryCard(now: context.date)
                    }
                    if !activity.children.isEmpty { childSection }
                    if let output = activity.output, !output.isEmpty {
                        TronSettingsGroup("Recent output", detail: "A bounded live tail from the extension run.", accent: .tronCyan) {
                            Text(output)
                                .font(TronTypography.codeContent)
                                .foregroundStyle(Color.tronTextPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, TronSpacing.section)
                .padding(.top, TronSpacing.md).padding(.bottom, TronSpacing.xl)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: activity.title, accent: .tronEmerald) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(Color.tronEmerald)
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .accessibilityIdentifier("extension-run-details-sheet")
    }

    private func summaryCard(now: Date) -> some View {
        let state = switch activity.status {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        }
        let metrics = [
            (state, "Status"),
            (activity.toolCount.map(String.init) ?? "—", "Tools"),
            (activity.turnCount.map(String.init) ?? "—", "Turns"),
            (durationLabel(activeDurationMs(now)), "Active time"),
        ]
        return VStack(alignment: .leading, spacing: 12) {
            Text(activity.mode?.capitalized ?? "Extension run")
                .font(TronTypography.caption)
                .foregroundStyle(Color.tronTextMuted)
            HStack(spacing: 0) {
                ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                    VStack(spacing: 3) {
                        Text(metric.0)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                            .foregroundStyle(Color.tronTextPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(metric.1)
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronTextMuted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if let currentTool = activity.currentTool {
                Label(currentTool, systemImage: "wrench.and.screwdriver")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronEmerald)
            }
        }
        .padding(14)
        .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.14)
    }

    private func activeDurationMs(_ now: Date) -> Int {
        guard activity.isLive, let started = ISO8601DateFormatter().date(from: activity.startedAt) else {
            return activity.durationMs ?? 0
        }
        return max(activity.durationMs ?? 0, Int(max(0, now.timeIntervalSince(started) * 1_000).rounded()))
    }

    private var childSection: some View {
        TronSettingsGroup("Subagents", detail: "Each child keeps its own stable progress identity.", accent: .tronTeal) {
            VStack(spacing: 0) {
                ForEach(activity.children) { child in
                    HStack(spacing: 10) {
                        Image(systemName: child.status == .running ? "circle.dotted" : (child.status == .failed ? "xmark.circle" : "checkmark.circle"))
                            .foregroundStyle(child.status == .failed ? Color.tronError : Color.tronTeal)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(child.label).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary)
                            Text(childSummary(child)).font(TronTypography.caption).foregroundStyle(Color.tronTextMuted).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)
                    if child.id != activity.children.last?.id { TronSettingsDivider(accent: .tronTeal) }
                }
            }
        }
    }

    private func childSummary(_ child: ExtensionRunChild) -> String {
        let status = switch child.status {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        }
        let detail = [
            child.currentTool,
            child.toolCount.map { "\($0) tools" },
            child.turnCount.map { "\($0) turns" },
            child.durationMs.map(durationLabel),
        ].compactMap { $0 }
        return ([status] + detail).joined(separator: " · ")
    }

    private func durationLabel(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds) / 1_000
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

// Retained for diagnostic callers.
struct ExtensionWidgetStackView: View {
    let items: [ChatExtensionWidgetItem]
    var body: some View {
        if !items.isEmpty {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 6) { ForEach(items) { item in
                    switch item.content { case .semantic(let widget): ExtensionWidgetView(widget: widget); case .surface(let surface): ExtensionSurfaceWidgetView(surface: surface) }
                }}.padding(.vertical, 2)
            }.frame(maxHeight: ChatExtensionWidgetPolicy.maximumStackHeight)
        }
    }
}

struct ExtensionWidgetView: View {
    let widget: ExtensionWidget
    var isExpanded = false
    var onToggleExpanded: (() -> Void)? = nil

    private var lines: [String] { widget.lines.map(NativeExtensionText.clean).filter { !$0.isEmpty } }
    private var hasDetail: Bool { widget.lines.contains { NativeExtensionText.isDetailHint($0) } }
    private var visibleLines: [String] { isExpanded ? lines : Array(lines.prefix(1)) }

    var body: some View {
        Group {
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Spacer()
                        if (hasDetail || isExpanded), let onToggleExpanded {
                            Button(action: onToggleExpanded) {
                                Label(isExpanded ? "Hide detail" : "Show detail", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(TronTypography.caption).foregroundStyle(Color.tronEmerald)
                            }.buttonStyle(.plain)
                        }
                    }
                    ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
                        nativeRow(line)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain).accessibilityIdentifier("extension-widget-\(widget.key)")
    }

    private func nativeRow(_ line: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.fill").font(TronTypography.sans(size: 5)).foregroundStyle(Color.tronCyan).padding(.top, 7)
            Text(line).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

struct ExtensionSurfaceWidgetView: View {
    let surface: ExtensionSurface
    var isExpanded = false
    var onToggleExpanded: (() -> Void)? = nil
    private var meaningfulLines: [String] {
        surface.frame.plainText.split(separator: "\n").map(String.init).map(NativeExtensionText.clean).filter { !$0.isEmpty }
    }
    private var hasDetail: Bool { surface.frame.plainText.split(separator: "\n").contains { NativeExtensionText.isDetailHint(String($0)) } }
    var body: some View {
        Group {
            if !meaningfulLines.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer()
                        if (hasDetail || isExpanded), let onToggleExpanded {
                            Button(action: onToggleExpanded) { Label(isExpanded ? "Hide detail" : "Show detail", systemImage: isExpanded ? "chevron.up" : "chevron.down").font(TronTypography.caption) }.buttonStyle(.plain)
                        }
                    }
                    if isExpanded {
                        ExtensionFrameView(frame: surface.frame)
                    } else {
                        Text(meaningfulLines[0]).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 7)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extension-surface-widget-\(surface.id)")
    }
}

enum NativeExtensionText {
    private static let navigationGlyphs = "↓←→↑↔⇣⇡⇠⇢"

    /// Recognizes complete terminal navigation affordance lines only. Content
    /// that merely mentions an arrow or keyboard remains meaningful content.
    static func isDetailHint(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text.range(of: #"^press\b[^\n]*\blive\s+detail\b\s*[.!…]*$"#, options: .regularExpression.union(.caseInsensitive)) != nil {
            return true
        }
        guard text.range(of: #"\bto\s+inspect\b"#, options: .regularExpression.union(.caseInsensitive)) != nil else { return false }
        return text.unicodeScalars.contains { navigationGlyphs.unicodeScalars.contains($0) }
    }

    static func clean(_ raw: String) -> String {
        guard !isDetailHint(raw) else { return "" }
        return raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func safeURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        if scheme == "http" || scheme == "https" { return url.host == nil ? nil : url }
        return url
    }
}
