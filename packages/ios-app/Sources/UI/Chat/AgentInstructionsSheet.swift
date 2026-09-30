import SwiftUI
import TronMobileCore

/// The Gateway's attributed projection of the prompt the model receives
/// (`session.context` → `instructions`). The Gateway owns splitting and
/// attribution; this type only decodes it.
struct AgentInstructionsProjection: Equatable {
    struct Source: Equatable {
        let kind: String
        let name: String?
        let path: String?
        let scope: String?

        init(_ value: JSONValue?) {
            let object = value?.objectValue ?? [:]
            kind = object["kind"]?.stringValue ?? "unknown"
            name = object["name"]?.stringValue
            path = object["path"]?.stringValue
            scope = object["scope"]?.stringValue
        }
    }

    struct Entry: Identifiable, Equatable {
        let id: String
        let name: String?
        let path: String?
        let text: String
        let tools: [String]
        let source: Source
    }

    struct Section: Identifiable, Equatable {
        let id: String
        /// Added at the start of each turn rather than stored in the session.
        let perTurn: Bool
        let text: String
        let source: Source?
        let entries: [Entry]
    }

    let text: String
    let sections: [Section]

    init?(context: JSONValue?) {
        guard let object = context?.objectValue?["instructions"]?.objectValue,
              let text = object["text"]?.stringValue,
              let rawSections = object["sections"]?.arrayValue else { return nil }
        self.text = text
        sections = rawSections.compactMap { value in
            guard let section = value.objectValue,
                  let id = section["id"]?.stringValue,
                  let body = section["text"]?.stringValue else { return nil }
            let entries = (section["entries"]?.arrayValue ?? []).enumerated().compactMap { index, value -> Entry? in
                guard let entry = value.objectValue, let text = entry["text"]?.stringValue else { return nil }
                return Entry(
                    id: "\(id).\(index)",
                    name: entry["name"]?.stringValue,
                    path: entry["path"]?.stringValue,
                    text: text,
                    tools: entry["tools"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                    source: Source(entry["source"])
                )
            }
            return Section(
                id: id,
                perTurn: section["timing"]?.stringValue == "turn",
                text: body,
                source: section["source"].map { Source($0) },
                entries: entries
            )
        }
    }
}

/// Wording for each section and source. Section ids and source kinds are the
/// Gateway's `agent-instructions.ts` contract.
enum AgentInstructionsPresentation {
    struct SectionCopy: Equatable {
        let title: String
        let icon: String
        let purpose: String
    }

    static func copy(for section: AgentInstructionsProjection.Section) -> SectionCopy {
        switch section.id {
        case "preamble":
            SectionCopy(title: "Opening", icon: "text.quote",
                        purpose: "Sets the agent's basic role. Pi writes it unless a SYSTEM.md file replaces it; a replacement also removes the Tools, Rules and Pi Documentation sections.")
        case "tools":
            SectionCopy(title: "Tools", icon: "wrench.and.screwdriver",
                        purpose: "A one-line summary of each tool the model can call right now. Pi builds this list from the active tools; each tool's full input schema is sent separately.")
        case "rules":
            SectionCopy(title: "Rules", icon: "checklist",
                        purpose: "Working rules. Pi adds its own defaults, then the guidelines each active tool contributes, with duplicates removed.")
        case "docs":
            SectionCopy(title: "Pi Documentation", icon: "book",
                        purpose: "Where the agent finds Pi's SDK documentation, used only when you ask about Pi itself.")
        case "addendum":
            SectionCopy(title: "Appended Instructions", icon: "text.append",
                        purpose: "Text from an APPEND_SYSTEM.md file, added after Pi's own sections.")
        case "project_context":
            SectionCopy(title: "Project Instructions", icon: "doc.text",
                        purpose: "AGENTS.md or CLAUDE.md files, included in full. Pi reads the one in Tron's agent folder, then one per folder from the root down to the working directory.")
        case "skills":
            SectionCopy(title: "Skills", icon: "sparkles",
                        purpose: "An index of available skills. Only each name, description and location is included; the agent reads a skill's file when a task matches it.")
        case "cwd":
            SectionCopy(title: "Working Directory", icon: "folder",
                        purpose: "The folder this session works in. Relative paths resolve against it.")
        case "tron":
            SectionCopy(title: "Tron Operating Context", icon: "iphone.and.arrow.forward",
                        purpose: "Added by Tron at the start of every turn: who the agent is, where it works, and Tron's safety rules. It reflects the current tools and workspace and is never saved in the session.")
        case "appended":
            SectionCopy(title: "Added This Turn", icon: "plus.bubble",
                        purpose: "Text an extension appended to the prompt for the current turn.")
        case "prompt":
            SectionCopy(title: "Replaced Prompt", icon: "exclamationmark.bubble",
                        purpose: "An extension replaced the prompt for this turn, so it can't be split into sections. This is the exact text the model receives.")
        default:
            SectionCopy(title: section.id.replacingOccurrences(of: "_", with: " ").capitalized, icon: "puzzlepiece.extension",
                        purpose: "A section an extension added for the current turn.")
        }
    }

    /// One-line row summary so the overview says what each section holds.
    static func summary(for section: AgentInstructionsProjection.Section) -> String {
        switch section.id {
        case "tools": return count(section.entries.count, "tool")
        case "rules":
            let fromTools = section.entries.filter { !$0.tools.isEmpty }.count
            return "\(count(section.entries.count, "rule")) · \(fromTools) from tools"
        case "project_context", "addendum": return section.entries.compactMap { $0.name }.joined(separator: ", ")
        case "skills": return count(section.entries.count, "skill")
        case "cwd": return displayPath(section.text)
        default: return section.source.map(sourceDetail) ?? ""
        }
    }

    static func sourceTag(_ source: AgentInstructionsProjection.Source) -> String {
        switch source.kind {
        case "pi": "Pi"
        case "module": "Tron"
        case "mcp": "MCP"
        case "package": "Package"
        case "local": source.scope == "project" ? "Project" : "User"
        case "file": "File"
        default: "Unknown"
        }
    }

    static func sourceDetail(_ source: AgentInstructionsProjection.Source) -> String {
        switch source.kind {
        case "pi": "Built into Pi"
        case "module": "Tron module \(source.name ?? "")"
        case "mcp": "Tron MCP connection"
        case "package": "Package \(source.name ?? "")"
        case "local", "file": source.path.map(displayPath) ?? "Local file"
        default: "Unknown source"
        }
    }

    static func accent(_ source: AgentInstructionsProjection.Source) -> Color {
        switch source.kind {
        case "pi": .tronBlue
        case "module", "mcp": .tronSessionTeal
        case "package": .tronPurple
        case "local", "file": .tronAmber
        default: .tronTextMuted
        }
    }

    /// The Gateway reports Mac paths; shorten the home folder for a phone.
    static func displayPath(_ path: String) -> String {
        path.replacingOccurrences(of: #"^/Users/[^/]+"#, with: "~", options: .regularExpression)
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}

struct AgentInstructionsSheet: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var loading = true
    @State private var loadingRequest: UUID?

    var body: some View {
        AgentInstructionsListSheet(title: "Agent Instructions", accent: .tronSessionTeal) {
            if let projection = AgentInstructionsProjection(context: model.context) {
                AgentInstructionsOverview(projection: projection)
            } else if loading {
                TronLoadingState(label: "Loading instructions…", accent: .tronSessionTeal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TronInfoCard(icon: "doc.text", text: "Instructions are unavailable for this session.", accent: .tronSessionTeal)
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .task(id: PresentationActivityTaskID(
            source: model.sessionContextRevision(for: sessionID),
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
            let request = UUID()
            loadingRequest = request
            loading = true
            await model.loadContext(sessionID: sessionID)
            guard !Task.isCancelled, loadingRequest == request,
                  presentationActivity.allowsPresentationPublication else { return }
            loading = false
        }
    }
}

/// Shared chrome for the overview and each section sheet: the standard
/// medium-first, large-capable sheet with a themed title and icon-only Done.
private struct AgentInstructionsListSheet<Content: View>: View {
    let title: String
    let accent: Color
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        TronSheetTitle(title: title, accent: accent)
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
                .tint(accent)
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronSettingsVisualTheme(accent: accent)
    }
}

/// A document opened from the overview or a section: the full prompt, a long
/// section body, or one included file.
private struct AgentInstructionsReading: Identifiable {
    let id: String
    let title: String
    let text: String
}

/// The nested markdown reader, sized like every other instructions sheet.
private struct AgentInstructionsReader: View {
    let reading: AgentInstructionsReading

    var body: some View {
        TronDocumentSheet(title: reading.title, detents: [.medium, .large]) {
            PreparedAgentInstructions(instructions: reading.text)
                .tronScrollEdgeChrome()
        }
        .tronSettingsVisualTheme(accent: .tronSessionTeal)
    }
}

/// Sections in the order the model reads them. Each glass row opens its own
/// sheet so the structure stays visible before any long body.
struct AgentInstructionsOverview: View {
    let projection: AgentInstructionsProjection
    @State private var selection: AgentInstructionsProjection.Section?
    @State private var reading: AgentInstructionsReading?

    var body: some View {
        ScrollView {
            // A dozen rows at most; eager layout keeps every row addressable
            // while the sheet rests at its medium detent.
            VStack(alignment: .leading, spacing: TronSpacing.lg) {
                TronSettingsDetailText("The model reads these sections in this order for every turn. Open one to see where it comes from.")
                    .padding(.bottom, TronSpacing.xs)
                ForEach(Array(projection.sections.enumerated()), id: \.element.id) { index, section in
                    sectionRow(section, number: index + 1)
                }
                Button {
                    reading = AgentInstructionsReading(id: "full", title: "Full Prompt", text: projection.text)
                } label: {
                    TronSettingsRow(
                        icon: "doc.plaintext",
                        title: "View Full Prompt",
                        subtitle: "\(projection.text.count.formatted()) characters, exactly as the model receives them",
                        accent: .tronSessionTeal
                    )
                }
                .buttonStyle(.plain)
                .tronGlassSurface(accent: .tronSessionTeal, tintOpacity: 0.10, interactive: true)
                .padding(.top, TronSpacing.md)
                .accessibilityIdentifier("agent-instructions-full-prompt")
                TronSettingsCaption("Some model providers add their own text to each request. That text is not part of these instructions.")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronManagedSheet(item: $selection, identity: { "agent-instructions.section.\($0.id)" }) { selection in
            AgentInstructionsSectionSheet(section: selection)
        }
        .tronManagedSheet(item: $reading, identity: { "agent-instructions.reading.\($0.id)" }) { reading in
            AgentInstructionsReader(reading: reading)
        }
    }

    private func sectionRow(_ section: AgentInstructionsProjection.Section, number: Int) -> some View {
        let copy = AgentInstructionsPresentation.copy(for: section)
        let accent = section.source.map(AgentInstructionsPresentation.accent) ?? .tronSessionTeal
        let summary = AgentInstructionsPresentation.summary(for: section)
        return Button {
            selection = section
        } label: {
            TronSettingsRow(
                // The numbered symbol keeps the model's reading order visible.
                icon: number <= 50 ? "\(number).circle" : copy.icon,
                title: copy.title,
                subtitle: summary.isEmpty ? nil : summary,
                subtitleLineLimit: 1,
                accent: accent
            ) {
                if section.perTurn { ResourceTagLabel(title: "Each turn", accent: .tronSessionTeal) }
            }
        }
        .buttonStyle(.plain)
        .tronGlassSurface(accent: accent, tintOpacity: 0.10, interactive: true, respectsSettingsTheme: false)
        // Source accents identify where each section comes from; the teal
        // theme belongs to the sheet chrome.
        .environment(\.tronSettingsVisualTheme, nil)
        .accessibilityIdentifier("agent-instructions-section-\(section.id)")
    }
}

/// One section's purpose, source, and content, presented from its overview row.
private struct AgentInstructionsSectionSheet: View {
    let section: AgentInstructionsProjection.Section
    @State private var reading: AgentInstructionsReading?

    /// Long bodies are laid out only in the document reader.
    private static let inlineLimit = 2_400

    private var copy: AgentInstructionsPresentation.SectionCopy { AgentInstructionsPresentation.copy(for: section) }
    private var accent: Color { section.source.map(AgentInstructionsPresentation.accent) ?? .tronSessionTeal }

    var body: some View {
        AgentInstructionsListSheet(title: copy.title, accent: accent) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TronSpacing.section) {
                    Text(copy.purpose)
                        .font(TronTypography.body)
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tronGlassSurface(accent: accent, tintOpacity: 0.10)
                        .accessibilityIdentifier("agent-instructions-purpose")
                    if section.source != nil || section.perTurn {
                        sourceGroup
                    }
                    if section.entries.isEmpty {
                        bodyGroup
                    } else {
                        entryGroup
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .tronManagedSheet(item: $reading, identity: { "agent-instructions.section.reading.\($0.id)" }) { reading in
                AgentInstructionsReader(reading: reading)
            }
        }
    }

    private var sourceGroup: some View {
        TronSettingsGroup("Source", accent: accent) {
            if let source = section.source {
                TronSettingsRow(
                    icon: "shippingbox",
                    title: AgentInstructionsPresentation.sourceDetail(source),
                    accent: accent
                ) {
                    ResourceTagLabel(title: AgentInstructionsPresentation.sourceTag(source), accent: AgentInstructionsPresentation.accent(source))
                }
            }
            if section.perTurn {
                if section.source != nil { TronSettingsDivider(accent: accent) }
                TronSettingsRow(
                    icon: "arrow.clockwise",
                    title: "Added each turn",
                    subtitle: "Rebuilt for every turn and never saved in the session",
                    accent: accent
                )
            }
        }
    }

    private var bodyGroup: some View {
        let long = section.text.count > Self.inlineLimit
        return TronSettingsGroup("Content", accent: accent, surfaceStyle: .scrollOptimized) {
            Text(verbatim: long ? String(section.text.prefix(600)) + "…" : section.text)
                .font(TronTypography.codeJSON)
                .foregroundStyle(Color.tronTextPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            if long {
                TronSettingsDivider(accent: accent)
                Button {
                    reading = AgentInstructionsReading(id: section.id, title: copy.title, text: section.text)
                } label: {
                    TronSettingsRow(
                        icon: "doc.text.magnifyingglass",
                        title: "Read \(copy.title)",
                        subtitle: "\(section.text.count.formatted()) characters",
                        accent: accent
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("agent-instructions-read-\(section.id)")
            }
        }
    }

    /// Rules can run to dozens of entries, so the group uses the static
    /// scroll surface rather than one very tall glass filter.
    private var entryGroup: some View {
        TronSettingsGroup(
            entryGroupTitle,
            // Only Rules says more than its count: how many came from tools.
            detail: section.id == "rules" ? AgentInstructionsPresentation.summary(for: section) : nil,
            accent: accent,
            surfaceStyle: .scrollOptimized
        ) {
            ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { TronSettingsDivider(accent: accent) }
                if isFileSection {
                    fileRow(entry)
                } else {
                    AgentInstructionsEntryRow(entry: entry, icon: copy.icon)
                        .accessibilityIdentifier("agent-instructions-entry-\(entry.id)")
                }
            }
        }
        // Entries keep the accent of their own source.
        .environment(\.tronSettingsVisualTheme, nil)
    }

    private var isFileSection: Bool { section.id == "project_context" || section.id == "addendum" }

    private var entryGroupTitle: String {
        switch section.id {
        case "tools": "Tools"
        case "rules": "Rules"
        case "skills": "Skills"
        default: isFileSection ? "Files" : "Entries"
        }
    }

    /// Whole files: name the file and open it rather than inlining pages.
    private func fileRow(_ entry: AgentInstructionsProjection.Entry) -> some View {
        let path = entry.path.map(AgentInstructionsPresentation.displayPath)
        return Button {
            reading = AgentInstructionsReading(id: entry.id, title: entry.name ?? "Instructions", text: entry.text)
        } label: {
            TronSettingsRow(
                icon: "doc.text",
                title: entry.name ?? "Instructions",
                subtitle: [path, "\(entry.text.count.formatted()) characters"].compactMap { $0 }.joined(separator: " · "),
                subtitleLineLimit: 2,
                accent: AgentInstructionsPresentation.accent(entry.source)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agent-instructions-entry-\(entry.id)")
    }
}

/// One attributed tool, rule, or skill in the settings row metrics: a named
/// entry leads with its name, an unnamed rule leads with its text.
private struct AgentInstructionsEntryRow: View {
    let entry: AgentInstructionsProjection.Entry
    let icon: String
    @Environment(\.tronSettingsSecondaryTextSizeAdjustment) private var secondaryTextSizeAdjustment

    var body: some View {
        let accent = AgentInstructionsPresentation.accent(entry.source)
        let secondary = TronTypography.sans(size: TronTypography.sizeSecondary + secondaryTextSizeAdjustment)
        HStack(alignment: .top, spacing: TronSpacing.xl) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: TronSettingsLayoutPolicy.iconSize, height: TronSettingsLayoutPolicy.iconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                let tag = ResourceTagLabel(title: AgentInstructionsPresentation.sourceTag(entry.source), accent: accent)
                if let name = entry.name {
                    HStack(spacing: TronSpacing.sm) {
                        Text(name)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(Color.tronTextPrimary)
                        tag
                    }
                    Text(verbatim: entry.text)
                        .font(secondary)
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(verbatim: entry.text)
                        .font(TronTypography.body)
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if entry.name == nil || attribution != nil {
                    HStack(spacing: TronSpacing.sm) {
                        if entry.name == nil { tag }
                        if let attribution {
                            Text(attribution)
                                .font(secondary)
                                .foregroundStyle(Color.tronTextMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
        .padding(.vertical, TronSpacing.xl)
        .frame(maxWidth: .infinity, minHeight: TronSettingsLayoutPolicy.rowMinimumHeight, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }

    /// Contributing tools for a rule; otherwise where a non-Pi entry comes from.
    private var attribution: String? {
        if !entry.tools.isEmpty { return "from \(entry.tools.joined(separator: ", "))" }
        return entry.source.kind == "pi" ? nil : AgentInstructionsPresentation.sourceDetail(entry.source)
    }
}

/// One detached parser for the mounted instruction document, keyed on the exact
/// source so a completed document is reused across activations instead of
/// re-parsing the whole prompt on the main thread. Mirrors the transcript
/// detail reader and keeps the same predecessor-drain and cancellation owner.
struct PreparedAgentInstructions: View {
    let instructions: String
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var preparation = ChatDetailDocumentPreparation()

    var body: some View {
        Group {
            if let document = preparation.document, document.source == instructions {
                ScrollView {
                    TronMarkdownView(document: document, streaming: false)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .onChange(of: preparation.revision, initial: true) { _, _ in
                            preparation.mounted(record: record)
                        }
                }
            } else {
                TronLoadingState(label: "Preparing instructions…", accent: .tronSessionTeal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: PresentationActivityTaskID(
            source: instructions,
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            let activity = presentationActivity
            await preparation.load(source: instructions, isCurrent: {
                presentationActivity == activity && activity.allowsPresentationPublication
            }, record: record)
        }
        .onDisappear { preparation.retire(record: record) }
    }

    private func record(_ message: String) {
        // Reuses the existing lifecycle diagnostic vocabulary; the message
        // identifies this surface.
        model.lifecycleRecordDiagnostic(
            event: "detail.preparation",
            message: "surface=agent-instructions \(message)"
        )
    }
}
