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

    /// One-line header summary so a collapsed section still says what it holds.
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
        case "package": "Package \(source.name ?? "")"
        case "local", "file": source.path.map(displayPath) ?? "Local file"
        default: "Unknown source"
        }
    }

    static func accent(_ source: AgentInstructionsProjection.Source) -> Color {
        switch source.kind {
        case "pi": .tronBlue
        case "module": .tronSessionTeal
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
        TronDocumentSheet(title: "Agent Instructions") {
            Group {
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
            .tronScrollEdgeChrome()
        }
        .tronSettingsVisualTheme(accent: .tronSessionTeal)
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

/// A document opened from the overview: the full prompt or one included file.
private struct AgentInstructionsReading: Identifiable {
    let id: String
    let title: String
    let text: String
}

/// Sections in the order the model reads them, collapsed by default so the
/// structure is visible before any long body.
struct AgentInstructionsOverview: View {
    let projection: AgentInstructionsProjection
    @State private var expandedSections: Set<String> = []
    @State private var expandedEntries: Set<String> = []
    @State private var reading: AgentInstructionsReading?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("The model reads these sections in this order for every turn. Open one to see where it comes from.")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(projection.sections.enumerated()), id: \.element.id) { index, section in
                    sectionCard(section, number: index + 1)
                }
                Button {
                    reading = AgentInstructionsReading(id: "full", title: "Full Prompt", text: projection.text)
                } label: {
                    TronSettingsRow(
                        icon: "doc.plaintext",
                        title: "View Full Prompt",
                        subtitle: "\(projection.text.count.formatted()) characters, exactly as the model receives them",
                        accent: .tronSessionTeal
                    ) {
                        Image(systemName: "chevron.right")
                            .font(TronTypography.sans(size: 12, weight: .semibold))
                            .foregroundStyle(Color.tronTextMuted)
                    }
                    .tronScrollSurface(accent: .tronSessionTeal)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("agent-instructions-full-prompt")
                Text("Some model providers add their own text to each request. That text is not part of these instructions.")
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .tronManagedSheet(item: $reading, identity: { "agent-instructions.reading.\($0.id)" }) { reading in
            TronDocumentSheet(title: reading.title) {
                PreparedAgentInstructions(instructions: reading.text)
                    .tronScrollEdgeChrome()
            }
            .tronSettingsVisualTheme(accent: .tronSessionTeal)
        }
    }

    private func sectionCard(_ section: AgentInstructionsProjection.Section, number: Int) -> some View {
        let copy = AgentInstructionsPresentation.copy(for: section)
        let expanded = expandedSections.contains(section.id)
        let accent = section.source.map(AgentInstructionsPresentation.accent) ?? .tronSessionTeal
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(TronDisclosureLayout.contentAnimation) {
                    if expanded { expandedSections.remove(section.id) } else { expandedSections.insert(section.id) }
                }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    Text("\(number)")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                        .foregroundStyle(accent)
                        .frame(width: 24, height: 24)
                        .background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(copy.title)
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                                .foregroundStyle(Color.tronTextPrimary)
                            if section.perTurn { ResourceTagLabel(title: "Each turn", accent: .tronSessionTeal) }
                        }
                        let summary = AgentInstructionsPresentation.summary(for: section)
                        if !summary.isEmpty {
                            Text(summary)
                                .font(TronTypography.secondaryDescription)
                                .foregroundStyle(Color.tronTextMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 8)
                    TronDisclosureChevron(isExpanded: expanded, animation: TronDisclosureLayout.contentAnimation)
                        .foregroundStyle(Color.tronTextMuted)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("agent-instructions-section-\(section.id)")
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(copy.purpose)
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let source = section.source {
                        sourceLine(source)
                    }
                    if section.entries.isEmpty {
                        sectionBody(section, title: copy.title)
                    } else {
                        entryList(section)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The surface's content shape stays behind the card: applied to the card
        // itself it would give the header button the whole expanded card as its
        // hit and accessibility area, so tapping body text would collapse it.
        .background { Color.clear.tronScrollSurface(accent: accent, tintOpacity: 0.08) }
    }

    private func sourceLine(_ source: AgentInstructionsProjection.Source) -> some View {
        HStack(spacing: 6) {
            Text("Source")
                .font(TronTypography.caption)
                .foregroundStyle(Color.tronTextMuted)
            ResourceTagLabel(title: AgentInstructionsPresentation.sourceTag(source), accent: AgentInstructionsPresentation.accent(source))
            Text(AgentInstructionsPresentation.sourceDetail(source))
                .font(TronTypography.secondaryCodeDescription)
                .foregroundStyle(Color.tronTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Short bodies read inline; long ones open in the document reader.
    @ViewBuilder
    private func sectionBody(_ section: AgentInstructionsProjection.Section, title: String) -> some View {
        let inlineLimit = 2_400
        Text(verbatim: section.text.count > inlineLimit ? String(section.text.prefix(600)) + "…" : section.text)
            .font(TronTypography.secondaryCodeDescription)
            .foregroundStyle(Color.tronTextPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.tronTextMuted.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        if section.text.count > inlineLimit {
            readButton("Read \(title)", id: section.id, title: title, text: section.text)
        }
    }

    private func entryList(_ section: AgentInstructionsProjection.Section) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().opacity(0.5) }
                entryRow(entry, in: section)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: AgentInstructionsProjection.Entry, in section: AgentInstructionsProjection.Section) -> some View {
        let sourceAccent = AgentInstructionsPresentation.accent(entry.source)
        if section.id == "project_context" || section.id == "addendum" {
            // Whole files: name the file and open it rather than inlining pages.
            Button {
                reading = AgentInstructionsReading(id: entry.id, title: entry.name ?? "Instructions", text: entry.text)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name ?? "Instructions")
                            .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                            .foregroundStyle(Color.tronTextPrimary)
                        Text(entry.path.map(AgentInstructionsPresentation.displayPath) ?? "")
                            .font(TronTypography.secondaryCodeDescription)
                            .foregroundStyle(Color.tronTextMuted)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text("\(entry.text.count.formatted()) characters")
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronTextMuted)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(TronTypography.sans(size: 12, weight: .semibold))
                        .foregroundStyle(Color.tronTextMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("agent-instructions-entry-\(entry.id)")
        } else {
            let expanded = expandedEntries.contains(entry.id)
            Button {
                if expanded { expandedEntries.remove(entry.id) } else { expandedEntries.insert(entry.id) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let name = entry.name {
                            Text(name)
                                .font(TronTypography.code(size: TronTypography.sizeBodySM, weight: .semibold))
                                .foregroundStyle(Color.tronTextPrimary)
                        }
                        ResourceTagLabel(title: AgentInstructionsPresentation.sourceTag(entry.source), accent: sourceAccent)
                        if !entry.tools.isEmpty {
                            Text("from \(entry.tools.joined(separator: ", "))")
                                .font(TronTypography.caption)
                                .foregroundStyle(Color.tronTextMuted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(verbatim: entry.text)
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(expanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                    if expanded, entry.source.kind != "pi" {
                        Text(AgentInstructionsPresentation.sourceDetail(entry.source))
                            .font(TronTypography.secondaryCodeDescription)
                            .foregroundStyle(Color.tronTextMuted)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("agent-instructions-entry-\(entry.id)")
        }
    }

    private func readButton(_ label: String, id: String, title: String, text: String) -> some View {
        Button {
            reading = AgentInstructionsReading(id: id, title: title, text: text)
        } label: {
            Label(label, systemImage: "doc.text.magnifyingglass")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronSessionTeal)
        }
        .buttonStyle(.plain)
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
