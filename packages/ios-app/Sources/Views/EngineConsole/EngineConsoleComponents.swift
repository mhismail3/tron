import SwiftUI

@available(iOS 26.0, *)
struct EngineConsoleSectionChips: View {
    @Binding var selection: EngineConsoleView.ConsoleSection
    @Binding var showAdvancedSections: Bool

    private var visibleSections: [EngineConsoleView.ConsoleSection] {
        EngineConsoleView.ConsoleSection.allCases.filter { section in
            showAdvancedSections || !section.isAdvanced
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label("Essentials", systemImage: "sparkles")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                Spacer()
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        showAdvancedSections.toggle()
                        if !showAdvancedSections, selection.isAdvanced {
                            selection = .overview
                        }
                    }
                } label: {
                    Label(showAdvancedSections ? "Hide Advanced" : "Show Advanced", systemImage: "slider.horizontal.3")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
                .buttonStyle(.plain)
                .contentShape([.interaction, .hoverEffect], Capsule())
                .hoverEffect(.highlight)
                .accessibilityElement(children: .combine)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visibleSections, id: \.self) { section in
                        Button {
                            withAnimation(.smooth(duration: 0.2)) {
                                selection = section
                            }
                        } label: {
                            Label(section.rawValue, systemImage: section.symbol)
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                                .foregroundStyle(selection == section ? .white : .tronEmerald)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 8)
                                .background(selection == section ? Color.tronEmerald : Color.tronEmerald.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .contentShape([.interaction, .hoverEffect], Capsule())
                        .hoverEffect(.highlight)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

struct EngineConsoleMetric: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let tint: Color

    init(_ title: String, _ value: String, _ tint: Color) {
        self.title = title
        self.value = value
        self.tint = tint
    }
}

struct EngineConsoleReadinessItem: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let message: String
    let tint: Color
}

struct EngineConsoleSearchSuggestion: Identifiable {
    let id = UUID()
    let title: String
    let query: String
    let symbol: String
}

@available(iOS 26.0, *)
struct EngineConsoleSuggestionChips: View {
    private let suggestions = [
        EngineConsoleSearchSuggestion(title: "Read files", query: "read a file", symbol: "doc.text.magnifyingglass"),
        EngineConsoleSearchSuggestion(title: "Run command", query: "run a shell command", symbol: "terminal"),
        EngineConsoleSearchSuggestion(title: "Search web", query: "search the web", symbol: "globe"),
        EngineConsoleSearchSuggestion(title: "Ask user", query: "ask the user a question", symbol: "person.crop.circle.badge.questionmark"),
        EngineConsoleSearchSuggestion(title: "Spawn worker", query: "worker::spawn", symbol: "shippingbox")
    ]
    let select: (EngineConsoleSearchSuggestion) -> Void

    var body: some View {
        WrappingBadgeLayout(spacing: 8, rowSpacing: 8) {
            ForEach(suggestions) { suggestion in
                Button {
                    select(suggestion)
                } label: {
                    Label(suggestion.title, systemImage: suggestion.symbol)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Color.tronEmerald.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .contentShape([.interaction, .hoverEffect], Capsule())
                .hoverEffect(.highlight)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

@available(iOS 26.0, *)
struct EngineConsoleMetricGrid: View {
    let metrics: [EngineConsoleMetric]
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(metrics) { metric in
                EngineConsoleCard(tint: metric.tint) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(metric.title)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                            .foregroundStyle(.tronTextMuted)
                        Text(metric.value)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(.tronTextPrimary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct EngineConsoleStatusLine: View {
    let symbol: String
    let title: String
    let message: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(message)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .regular))
                    .foregroundStyle(.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

@available(iOS 26.0, *)
struct EngineConsoleCard<Content: View>: View {
    var tint: Color = .tronEmerald
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .sectionFill(tint, subtle: true, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct EngineConsoleCardHeader: View {
    let symbol: String
    let title: String
    let subtitle: String
    var tint: Color = .tronEmerald

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

@available(iOS 26.0, *)
struct EngineConsoleSearchBar: View {
    @Binding var text: String
    let placeholder: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tronTextMuted)
            TextField(placeholder, text: $text)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .regular))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(action)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tronTextMuted)
                }
                .buttonStyle(.plain)
            }
            Button(action: action) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                    .foregroundStyle(disabled ? .tronTextDisabled : .tronEmerald)
            }
            .buttonStyle(.plain)
            .disabled(disabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.tronSurface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct EngineConsoleBanner: View {
    let symbol: String
    let title: String
    let message: String
    let tint: Color
    var showsProgress = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
            } else {
                Image(systemName: symbol)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(message)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct EngineConsoleEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.tronTextMuted.opacity(0.7))
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(message)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

struct EngineConsoleKeyValueRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronTextMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value.isEmpty ? "none" : value)
                .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .regular))
                .foregroundStyle(.tronTextPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .minimumScaleFactor(0.78)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

struct EngineConsoleActionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(subtitle)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
        }
        .padding(.vertical, 6)
    }
}

struct EngineConsoleTextField: View {
    let title: String
    @Binding var text: String
    let prompt: String
    let monospace: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
            TextField(prompt, text: $text, axis: .vertical)
                .font(monospace
                    ? TronTypography.code(size: TronTypography.sizeCaption, weight: .regular)
                    : TronTypography.sans(size: TronTypography.sizeBody3, weight: .regular))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(Color.tronSurface.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

@available(iOS 26.0, *)
struct CapabilityHitCard: View {
    let hit: CapabilityIndexHitDTO

    var body: some View {
        EngineConsoleCard(tint: tint) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: CapabilityPresentation.symbol(for: identity))
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 7) {
                    Text(primaryTitle)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(2)
                    if let secondaryTitle {
                        Text(secondaryTitle)
                            .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .regular))
                            .foregroundStyle(.tronTextMuted)
                            .lineLimit(2)
                    }
                    if let snippet = hit.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .regular))
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(3)
                    }
                    EngineConsoleBadgeRow(values: [
                        hit.kind,
                        hit.trustTier,
                        hit.health,
                        hit.riskLevel,
                        hit.matchedBy
                    ])
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
            }
        }
    }

    private var tint: Color {
        CapabilityPresentation.color(for: identity)
    }

    private var primaryTitle: String {
        hit.contractId ?? hit.functionId ?? hit.capabilityId ?? "capability"
    }

    private var secondaryTitle: String? {
        let candidate = hit.functionId ?? hit.implementationId
        guard let candidate, !candidate.isEmpty, candidate != primaryTitle else {
            return nil
        }
        return candidate
    }

    private var identity: CapabilityIdentity {
        CapabilityIdentity(
            modelPrimitiveName: "execute",
            contractId: hit.contractId,
            implementationId: hit.implementationId,
            functionId: hit.functionId,
            pluginId: hit.pluginId,
            workerId: hit.workerId,
            schemaDigest: hit.schemaDigest,
            catalogRevision: hit.catalogRevision,
            trustTier: hit.trustTier,
            riskLevel: hit.riskLevel,
            effectClass: hit.effectClass
        )
    }
}

struct EngineConsoleBadgeRow: View {
    let values: [String?]

    var body: some View {
        WrappingBadgeLayout(spacing: 6, rowSpacing: 6) {
            ForEach(values.compactMap { value in
                value?.isEmpty == false ? value : nil
            }, id: \.self) { value in
                Text(value)
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(.tronEmerald)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.tronEmerald.opacity(0.12), in: Capsule())
            }
        }
    }
}

struct WrappingBadgeLayout: Layout {
    let spacing: CGFloat
    let rowSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var currentX: CGFloat = 0
        var currentRowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextX = currentX == 0 ? size.width : currentX + spacing + size.width
            if nextX > maxWidth, currentX > 0 {
                totalHeight += currentRowHeight + rowSpacing
                measuredWidth = max(measuredWidth, currentX)
                currentX = size.width
                currentRowHeight = size.height
            } else {
                currentX = nextX
                currentRowHeight = max(currentRowHeight, size.height)
            }
        }

        measuredWidth = max(measuredWidth, currentX)
        totalHeight += currentRowHeight
        return CGSize(width: min(measuredWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var currentRowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextX = currentX == bounds.minX ? currentX + size.width : currentX + spacing + size.width
            if nextX > bounds.maxX, currentX > bounds.minX {
                currentX = bounds.minX
                currentY += currentRowHeight + rowSpacing
                currentRowHeight = 0
            } else if currentX > bounds.minX {
                currentX += spacing
            }

            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            currentX += size.width
            currentRowHeight = max(currentRowHeight, size.height)
        }
    }
}

@available(iOS 26.0, *)
struct PluginCard: View {
    let plugin: CapabilityPluginManifestDTO
    let mutatingDisabled: Bool
    let runConformance: () -> Void
    let promote: () -> Void
    let quarantine: () -> Void
    let disable: () -> Void

    var body: some View {
        EngineConsoleCard(tint: .tronPurple) {
            EngineConsoleCardHeader(
                symbol: "puzzlepiece.extension",
                title: plugin.name ?? plugin.id,
                subtitle: plugin.id
            )
            EngineConsoleKeyValueRow("Trust", plugin.trustTier ?? "unknown")
            EngineConsoleKeyValueRow("Signature", plugin.signatureStatus ?? "unknown")
            EngineConsoleKeyValueRow("Conformance", plugin.conformanceState ?? "unknown")
            EngineConsoleKeyValueRow("Namespaces", plugin.namespaceClaims?.joined(separator: ", ") ?? "none")
            if !mutatingDisabled {
                EngineConsoleBadgeRow(values: [
                    plugin.runtime,
                    plugin.visibilityCeiling,
                    "\(plugin.providedContracts?.count ?? 0) contracts"
                ])
                WrappingBadgeLayout(spacing: 12, rowSpacing: 8) {
                    Button("Conformance", action: runConformance)
                    Button("Promote", action: promote)
                        .disabled(plugin.visibilityCeiling == "system")
                    Button("Quarantine", role: .destructive, action: quarantine)
                        .disabled(plugin.conformanceState == "quarantined")
                    Button("Disable", role: .destructive, action: disable)
                        .disabled(plugin.conformanceState == "disabled")
                }
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronEmerald)
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }
}

extension CapabilityIndexDocumentDTO {
    var engineConsoleStableId: String {
        [
            kind,
            capabilityId,
            contractId,
            implementationId,
            pluginId,
            workerId,
            functionId,
            schemaDigest,
            text,
            catalogRevision.map(String.init)
        ]
        .compactMap { $0 }
        .joined(separator: "|")
    }
}

@available(iOS 26.0, *)
struct WorkerCard: View {
    let worker: CapabilityIndexDocumentDTO

    var body: some View {
        EngineConsoleCard(tint: worker.health == "healthy" || worker.health == "ready" ? .tronSuccess : .tronAmber) {
            EngineConsoleCardHeader(
                symbol: "server.rack",
                title: worker.capabilityId ?? worker.workerId ?? "worker",
                subtitle: worker.pluginId ?? "unknown plugin"
            )
            EngineConsoleKeyValueRow("Worker", worker.workerId ?? "unknown")
            EngineConsoleKeyValueRow("Health", worker.health ?? "unknown")
            EngineConsoleKeyValueRow("Visibility", worker.visibility ?? "unknown")
            EngineConsoleKeyValueRow("Catalog", worker.catalogRevision.map(String.init) ?? "unknown")
        }
    }
}

@available(iOS 26.0, *)
struct BindingCard: View {
    let binding: CapabilityBindingDTO
    let mutatingDisabled: Bool
    let setEnabled: (Bool) -> Void

    var body: some View {
        EngineConsoleCard(tint: .tronCyan) {
            EngineConsoleCardHeader(
                symbol: "point.3.connected.trianglepath.dotted",
                title: binding.contractId,
                subtitle: binding.selectionPolicy ?? "resolver policy"
            )
            EngineConsoleKeyValueRow("Implementation", binding.selectedImplementation)
            EngineConsoleKeyValueRow("Scope", [binding.scopeKind, binding.scopeValue].compactMap { $0 }.joined(separator: ":"))
            EngineConsoleKeyValueRow("Enabled", (binding.enabled ?? false) ? "yes" : "no")
            EngineConsoleKeyValueRow("Secondary", binding.secondaryImplementations?.joined(separator: ", ") ?? "none")
            if !mutatingDisabled {
                Button((binding.enabled ?? false) ? "Disable Binding" : "Enable Binding") {
                    setEnabled(!(binding.enabled ?? false))
                }
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle((binding.enabled ?? false) ? .tronError : .tronEmerald)
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }
}

@available(iOS 26.0, *)
struct PolicyCard: View {
    let id: String
    let policy: CapabilityExecutionPolicyDTO

    var body: some View {
        EngineConsoleCard(tint: .tronSlate) {
            EngineConsoleCardHeader(
                symbol: "checkmark.shield",
                title: id,
                subtitle: "Profile execution policy"
            )
            EngineConsoleKeyValueRow("Search", policy.searchPolicy ?? "default")
            EngineConsoleKeyValueRow("Primer", policy.contextPrimerPolicy ?? "default")
            EngineConsoleKeyValueRow("Allowed actions", (policy.allowedContracts ?? []).joined(separator: ", "))
            EngineConsoleKeyValueRow("Denied actions", (policy.deniedContracts ?? []).joined(separator: ", "))
            EngineConsoleKeyValueRow("Allowed plugins", (policy.allowedPlugins ?? []).joined(separator: ", "))
            EngineConsoleKeyValueRow("Denied plugins", (policy.deniedPlugins ?? []).joined(separator: ", "))
            EngineConsoleKeyValueRow("Max risk", policy.maxRisk ?? "profile default")
            EngineConsoleKeyValueRow("Trust level", policy.minimumTrustTier ?? "profile default")
        }
    }
}

@available(iOS 26.0, *)
struct AuditCard: View {
    let event: CapabilityAuditEventDTO

    var body: some View {
        EngineConsoleCard(tint: .tronSlate) {
            EngineConsoleCardHeader(
                symbol: "list.bullet.rectangle",
                title: event.eventType ?? event.id ?? "audit",
                subtitle: event.createdAt ?? "unknown time"
            )
            EngineConsoleKeyValueRow("Trace", event.traceId ?? "none")
            EngineConsoleKeyValueRow("Redacted", (event.redacted ?? true) ? "yes" : "no")
            if let summary = event.payloadSummary?.dictionaryValue {
                ForEach(summary.keys.sorted(), id: \.self) { key in
                    EngineConsoleKeyValueRow(key, String(describing: summary[key] ?? ""))
                }
            }
        }
    }
}

@available(iOS 26.0, *)
struct TraceCard: View {
    let event: CapabilityAuditEventDTO

    var body: some View {
        EngineConsoleCard(tint: .tronTeal) {
            EngineConsoleCardHeader(
                symbol: "waterfall",
                title: event.traceId ?? "trace",
                subtitle: event.eventType ?? "audit event"
            )
            EngineConsoleKeyValueRow("Created", event.createdAt ?? "unknown")
            EngineConsoleKeyValueRow("Redacted", (event.redacted ?? true) ? "yes" : "no")
        }
    }
}

@available(iOS 26.0, *)
struct ProgramRunCard: View {
    let run: CapabilityProgramRunDTO

    var body: some View {
        EngineConsoleCard(tint: statusTint) {
            EngineConsoleCardHeader(
                symbol: "curlybraces.square",
                title: run.programRunId ?? "program run",
                subtitle: run.status ?? "unknown status"
            )
            EngineConsoleKeyValueRow("Trace", run.traceId ?? "unknown")
            EngineConsoleKeyValueRow("Root", run.rootInvocationId ?? "unknown")
            EngineConsoleKeyValueRow("Binding", run.bindingDecisionId ?? "none")
            EngineConsoleKeyValueRow("Code", run.codeHash ?? "unknown")
            EngineConsoleKeyValueRow("Args", run.argsHash ?? "unknown")
            EngineConsoleKeyValueRow("Children", String(run.childInvocations?.count ?? 0))
            EngineConsoleKeyValueRow("Selected", (run.selectedImplementations ?? []).joined(separator: ", "))
            EngineConsoleKeyValueRow("Redacted", (run.redacted ?? true) ? "yes" : "no")
            if let summary = run.payloadSummary?.dictionaryValue {
                ForEach(summary.keys.sorted(), id: \.self) { key in
                    EngineConsoleKeyValueRow(key, String(describing: summary[key] ?? ""))
                }
            }
        }
    }

    private var statusTint: Color {
        switch run.status {
        case "ok": .tronSuccess
        case "paused_for_approval": .tronAmber
        case "failed", "timeout", "policy_denied", "worker_disconnected": .tronError
        default: .tronSlate
        }
    }
}

struct CapabilityInspectionSheet: View {
    let inspection: CapabilityInspectionDTO

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    EngineConsoleCard(tint: tint) {
                        EngineConsoleCardHeader(
                            symbol: "doc.text.magnifyingglass",
                            title: inspection.contract?.displayName ?? inspection.contract?.contractId ?? "Inspection",
                            subtitle: inspection.implementation?.implementationId ?? "No implementation selected",
                            tint: tint
                        )
                        EngineConsoleKeyValueRow("Contract", inspection.contract?.contractId ?? "unknown")
                        EngineConsoleKeyValueRow("Effect", inspection.contract?.effectClass ?? "unknown")
                        EngineConsoleKeyValueRow("Risk", inspection.contract?.riskLevel ?? "unknown")
                    }

                    EngineConsoleCard(tint: tint) {
                        EngineConsoleCardHeader(
                            symbol: "shippingbox",
                            title: "Implementation",
                            subtitle: inspection.implementation?.functionId ?? "unknown function",
                            tint: tint
                        )
                        EngineConsoleKeyValueRow("ID", inspection.implementation?.implementationId ?? "unknown")
                        EngineConsoleKeyValueRow("Plugin", inspection.implementation?.pluginId ?? "unknown")
                        EngineConsoleKeyValueRow("Health", inspection.implementation?.health ?? "unknown")
                        EngineConsoleKeyValueRow("Conformance", inspection.implementation?.conformanceState ?? "unknown")
                        EngineConsoleKeyValueRow("Schema", inspection.implementation?.schemaDigest ?? "unknown")
                    }

                    EngineConsoleCard(tint: tint) {
                        EngineConsoleCardHeader(
                            symbol: "key",
                            title: "Execution Handle",
                            subtitle: "Fresh handles are required for mutating or elevated-risk execution.",
                            tint: tint
                        )
                        EngineConsoleKeyValueRow("Handle", inspection.inspectionHandle?.handle ?? "missing")
                        EngineConsoleKeyValueRow("Revision", inspection.inspectionHandle?.functionRevision.map(String.init) ?? "missing")
                        EngineConsoleKeyValueRow("Catalog", inspection.inspectionHandle?.catalogRevision.map(String.init) ?? "missing")
                    }
                }
                .padding(20)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Inspection", color: tint)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: tint)
                }
            }
        }
        .tint(tint)
    }

    private var tint: Color {
        CapabilityPresentation.color(for: identity)
    }

    private var identity: CapabilityIdentity {
        CapabilityIdentity(
            modelPrimitiveName: "inspect",
            contractId: inspection.contract?.contractId ?? inspection.implementation?.contractId,
            implementationId: inspection.implementation?.implementationId,
            functionId: inspection.implementation?.functionId ?? inspection.bindingDecision?.selectedFunctionId,
            pluginId: inspection.implementation?.pluginId,
            workerId: inspection.implementation?.workerId,
            schemaDigest: inspection.inspectionHandle?.schemaDigest ?? inspection.implementation?.schemaDigest,
            catalogRevision: inspection.inspectionHandle?.catalogRevision ?? inspection.implementation?.catalogRevision,
            trustTier: inspection.implementation?.trustTier,
            riskLevel: inspection.contract?.riskLevel,
            effectClass: inspection.contract?.effectClass
        )
    }
}
