import SwiftUI

/// One compact, composer-adjacent affordance per opaque widget group. Groups
/// are intentionally not inferred from package names or display text.
struct ExtensionActivityPill: View {
    let group: ExtensionWidgetGroup
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: group.isWidgetGroup ? "rectangle.3.group" : "sparkles")
                Text(group.label).lineLimit(1).truncationMode(.tail)
                if group.items.count > 1 { Text("\(group.items.count)").font(TronTypography.code(size: TronTypography.sizeCaption)) }
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

    init(sessionID: String, groupID: String? = nil) { self.sessionID = sessionID; self.groupID = groupID }

    private var snapshot: SessionSnapshot? { model.authoritativeSnapshot(for: sessionID) }
    private var presentation: ExtensionPresentationState? { snapshot?.extensionPresentation }
    private var groups: [ExtensionWidgetGroup] {
        guard let presentation else { return [] }
        return ChatExtensionWidgetPolicy.groups(presentation, executions: snapshot?.toolExecutions ?? [])
    }
    private var selectedGroup: ExtensionWidgetGroup? {
        guard let groupID else { return groups.first }
        return groups.first(where: { $0.id == groupID })
    }
    private var isExpanded: Bool { presentation?.semanticState.toolsExpanded ?? false }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: TronSpacing.lg) {
                    if let group = selectedGroup {
                        groupSection(group)
                    } else {
                        settledState
                    }
                }
                .padding(.horizontal, TronSpacing.section)
                .padding(.top, TronSpacing.md).padding(.bottom, TronSpacing.xl)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: selectedGroup?.label ?? "Extensions") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(Color.tronEmerald)
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .accessibilityIdentifier("extension-details-sheet")
    }

    @ViewBuilder private func groupSection(_ group: ExtensionWidgetGroup) -> some View {
        if !group.statuses.isEmpty { statusSection(group.statuses) }
        if !group.services.isEmpty { serviceSection(group.services) }
        if !group.items.isEmpty {
            TronSettingsGroup("Widget", detail: "Native read-only extension information.", accent: .tronCyan) {
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
    }

    private func statusSection(_ statuses: [ExtensionActivityStatus]) -> some View {
        TronSettingsGroup("Status", detail: "Live information published by the extension.", accent: .tronEmerald) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(statuses) { status in
                    HStack(alignment: .top, spacing: TronSpacing.sm) {
                        Text(status.displayKey).font(TronTypography.code(size: TronTypography.sizeCaption)).foregroundStyle(Color.tronTextMuted).frame(minWidth: 70, alignment: .leading)
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
                            Text(service.title).font(TronTypography.code(size: TronTypography.sizeCaption)).foregroundStyle(Color.tronTextPrimary).lineLimit(1)
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
    private var nativeLabel: String { lines.first ?? widget.key }
    private var hasDetail: Bool { widget.lines.contains { NativeExtensionText.isDetailHint($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(nativeLabel).font(TronTypography.caption).foregroundStyle(Color.tronTextMuted).lineLimit(1)
                Spacer()
                if (hasDetail || isExpanded), let onToggleExpanded {
                    Button(action: onToggleExpanded) {
                        Label(isExpanded ? "Hide detail" : "Show detail", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                            .font(TronTypography.caption).foregroundStyle(Color.tronEmerald)
                    }.buttonStyle(.plain)
                }
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .tronGlassSurface(accent: .tronCyan, tintOpacity: 0.10)
        .accessibilityElement(children: .contain).accessibilityIdentifier("extension-widget-\(widget.key)")
    }
}

struct ExtensionSurfaceWidgetView: View {
    let surface: ExtensionSurface
    var isExpanded = false
    var onToggleExpanded: (() -> Void)? = nil
    private var nativeLabel: String {
        let source = surface.provenance?.source?.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.flatMap { $0.isEmpty ? nil : $0 }
            ?? surface.frame.lines.map { NativeExtensionText.clean($0.plainText) }.first(where: { !$0.isEmpty })
            ?? "Extension widget"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(nativeLabel).font(TronTypography.caption).foregroundStyle(Color.tronTextMuted)
                Spacer()
                if (isExpanded || surface.frame.plainText.split(separator: "\n").contains(where: { NativeExtensionText.isDetailHint(String($0)) })), let onToggleExpanded {
                    Button(action: onToggleExpanded) { Label(isExpanded ? "Hide detail" : "Show detail", systemImage: isExpanded ? "chevron.up" : "chevron.down").font(TronTypography.caption) }.buttonStyle(.plain)
                }
            }
            ExtensionFrameView(frame: surface.frame)
        }
        .padding(14).tronGlassSurface(accent: .tronCyan, tintOpacity: 0.10)
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
}
