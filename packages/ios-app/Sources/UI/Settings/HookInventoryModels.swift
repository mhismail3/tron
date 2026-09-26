import SwiftUI

struct HookHandlerSummary: Identifiable, Equatable, Sendable {
    let event: String
    let count: Int
    var id: String { event }
}

enum HookProvenance: String, Sendable, Equatable {
    case user = "User"
    case project = "Project"
    case runtime = "Runtime"
    case unknown = "Unknown"

    init(scope: String?) {
        switch scope {
        case "user", "global": self = .user
        case "project": self = .project
        case "temporary": self = .runtime
        default: self = .unknown
        }
    }
}

struct HookExtensionRecord: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let path: String?
    let resolvedPath: String?
    let source: String?
    let scope: String?
    let origin: String?
    let provenance: HookProvenance
    let handlers: [HookHandlerSummary]
    let tools: [String]
    let commands: [String]

    var handlerCount: Int { handlers.reduce(0) { $0 + $1.count } }
    var eventCount: Int { handlers.count }
    var friendlyName: String {
        ProjectResourceTitlePresentation.extensionTitle(name: name, object: [
            "name": .string(name),
            "path": path.map(JSONValue.string) ?? .null,
            "resolvedPath": resolvedPath.map(JSONValue.string) ?? .null,
            "source": source.map(JSONValue.string) ?? .null,
        ])
    }

    init(value: JSONValue) {
        let object = value.objectValue ?? [:]
        name = object["name"]?.stringValue ?? "Unnamed extension"
        path = object["path"]?.stringValue
        resolvedPath = object["resolvedPath"]?.stringValue
        source = object["source"]?.stringValue
        scope = object["scope"]?.stringValue
        origin = object["origin"]?.stringValue
        provenance = HookProvenance(scope: scope)
        let rawHandlers = object["handlers"]?.arrayValue ?? []
        handlers = rawHandlers.compactMap { raw in
            guard let item = raw.objectValue,
                  let event = item["event"]?.stringValue,
                  !event.isEmpty else { return nil }
            let count: Int
            if case .number(let value) = item["count"] ?? .number(0) {
                count = max(0, Int(value))
            } else {
                count = 0
            }
            return HookHandlerSummary(event: event, count: count)
        }.sorted { $0.event < $1.event }
        tools = object["tools"]?.arrayValue?.compactMap(\.stringValue) ?? []
        commands = object["commands"]?.arrayValue?.compactMap(\.stringValue) ?? []
        id = [scope, source, resolvedPath ?? path, name].compactMap { $0 }.joined(separator: "|")
    }
}

struct HookInventoryOmissions: Equatable, Sendable {
    let extensions: Int
    let handlerEvents: Int
    let loadErrors: Int
    let textFields: Int

    var hasOmissions: Bool {
        extensions > 0 || handlerEvents > 0 || loadErrors > 0 || textFields > 0
    }

    private init(extensions: Int, handlerEvents: Int, loadErrors: Int, textFields: Int) {
        self.extensions = extensions
        self.handlerEvents = handlerEvents
        self.loadErrors = loadErrors
        self.textFields = textFields
    }

    var summary: String {
        var values: [String] = []
        if extensions > 0 { values.append("\(extensions) extension\(extensions == 1 ? "" : "s")") }
        if handlerEvents > 0 { values.append("\(handlerEvents) handler event\(handlerEvents == 1 ? "" : "s")") }
        if loadErrors > 0 { values.append("\(loadErrors) load issue\(loadErrors == 1 ? "" : "s")") }
        if textFields > 0 { values.append("\(textFields) long metadata field\(textFields == 1 ? "" : "s")") }
        return values.joined(separator: ", ")
    }

    init?(resources: JSONValue?) {
        guard let object = resources?.objectValue?["hookInventory"]?.objectValue else { return nil }
        func omitted(_ key: String) -> Int {
            guard let container = object[key]?.objectValue,
                  case .number(let value) = container["omitted"] ?? .number(0) else { return 0 }
            return max(0, Int(value))
        }
        func count(_ key: String) -> Int {
            guard let raw = object[key], case .number(let value) = raw else { return 0 }
            return max(0, Int(value))
        }
        let value = HookInventoryOmissions(
            extensions: omitted("extensions"),
            handlerEvents: omitted("handlerEvents"),
            loadErrors: omitted("loadErrors"),
            textFields: count("textFieldsOmitted")
        )
        guard value.hasOmissions else { return nil }
        self = value
    }
}

struct HookLoadIssue: Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let message: String

    init(value: JSONValue, index: Int = 0) {
        let object = value.objectValue ?? [:]
        path = object["path"]?.stringValue ?? "Unknown source"
        message = object["error"]?.stringValue ?? object["message"]?.stringValue ?? "Could not load extension"
        id = "\(path)|\(index)"
    }
}

enum HookInventoryPresentation {
    static func extensions(from resources: JSONValue?) -> [HookExtensionRecord] {
        guard let values = resources?.objectValue?["extensions"]?.arrayValue else { return [] }
        var seen = Set<String>()
        return values.map { HookExtensionRecord(value: $0) }.filter { seen.insert($0.id).inserted }
    }

    static func hasInventory(_ resources: JSONValue?) -> Bool {
        resources?.objectValue?["hookInventory"]?.objectValue != nil
    }

    static func extensionLabels(for records: [HookExtensionRecord]) -> [String: String] {
        let groups = Dictionary(grouping: records, by: \.friendlyName)
        return Dictionary(uniqueKeysWithValues: records.map { record in
            let label: String
            if groups[record.friendlyName, default: []].count == 1 {
                label = record.friendlyName
            } else {
                let discriminator = [record.provenance.rawValue, record.source, record.resolvedPath ?? record.path]
                    .compactMap { $0 }.joined(separator: " · ")
                label = "\(record.friendlyName) · \(discriminator)"
            }
            return (record.id, label)
        })
    }

    static func eventRecords(from records: [HookExtensionRecord], includeUnregistered: Bool) -> [HookEventRecord] {
        var grouped: [String: [(extension: HookExtensionRecord, count: Int)]] = [:]
        for record in records {
            for handler in record.handlers {
                grouped[handler.event, default: []].append((record, handler.count))
            }
        }
        var descriptors = grouped.keys.map(eventDescriptor)
        if includeUnregistered {
            for descriptor in supportedEvents() where !grouped.keys.contains(descriptor.identifier) {
                descriptors.append(descriptor)
            }
        }
        return descriptors.sorted { left, right in
            let leftIndex = supportedEventNames.firstIndex { $0.0 == left.identifier } ?? supportedEventNames.count
            let rightIndex = supportedEventNames.firstIndex { $0.0 == right.identifier } ?? supportedEventNames.count
            return leftIndex == rightIndex ? left.title < right.title : leftIndex < rightIndex
        }.map { HookEventRecord(descriptor: $0, providers: grouped[$0.identifier] ?? []) }
    }

    static func eventDescriptor(_ name: String) -> HookEventDescriptor {
        if let item = supportedEventNames.first(where: { $0.0 == name }) {
            return HookEventDescriptor(identifier: item.0, title: item.1, purpose: item.2, isSupported: true)
        }
        return HookEventDescriptor(identifier: name, title: "Unknown event · \(name)", purpose: "Reported by the runtime but not in this app's pinned event catalogue.", isSupported: false)
    }

    static func supportedEvents() -> [HookEventDescriptor] {
        supportedEventNames.map { HookEventDescriptor(identifier: $0.0, title: $0.1, purpose: $0.2, isSupported: true) }
    }

    private static let supportedEventNames: [(String, String, String)] = [
        ("session_start", "Session starts", "Runs when the session runtime opens."),
        ("session_info_changed", "Session info changes", "Runs when session metadata changes."),
        ("session_before_switch", "Before session switch", "Runs before the active session changes."),
        ("session_before_fork", "Before session fork", "Runs before a session is forked."),
        ("session_before_compact", "Before compaction", "Runs before session compaction."),
        ("session_compact", "Session compacts", "Runs when session compaction completes."),
        ("session_compact_failed", "Compaction fails", "Runs when session compaction fails."),
        ("session_before_tree", "Before tree change", "Runs before the session tree changes."),
        ("session_tree", "Session tree changes", "Runs when the session tree changes."),
        ("session_shutdown", "Session shuts down", "Runs when the session runtime shuts down."),
        ("before_agent_start", "Before agent starts", "Runs before an agent turn begins."),
        ("agent_start", "Agent starts", "Runs when an agent turn starts."),
        ("agent_end", "Agent ends", "Runs when an agent turn ends."),
        ("agent_settled", "Agent settles", "Runs after an agent turn settles."),
        ("turn_start", "Turn starts", "Runs at the beginning of a turn."),
        ("turn_end", "Turn ends", "Runs at the end of a turn."),
        ("context", "Context", "Runs when context is assembled."),
        ("before_provider_request", "Before provider request", "Runs before a provider request is sent."),
        ("before_provider_headers", "Before provider headers", "Runs before provider headers are finalized."),
        ("after_provider_response", "After provider response", "Runs after a provider response arrives."),
        ("tool_call", "Tool call", "Runs before a tool call executes."),
        ("tool_result", "Tool result", "Runs after a tool result is available."),
        ("tool_execution_start", "Tool execution starts", "Runs when tool execution starts."),
        ("tool_execution_update", "Tool execution updates", "Runs as tool execution reports updates."),
        ("tool_execution_end", "Tool execution ends", "Runs when tool execution ends."),
        ("user_bash", "User shell command", "Runs for a user-issued shell command."),
        ("input", "Input", "Runs when user input is received."),
        ("message_start", "Message starts", "Runs when a message starts."),
        ("message_update", "Message updates", "Runs as a message updates."),
        ("message_end", "Message ends", "Runs when a message ends."),
        ("model_select", "Model selection", "Runs when the active model is selected."),
        ("thinking_level_select", "Thinking level selection", "Runs when the thinking level is selected."),
        ("resources_discover", "Resource discovery", "Runs while resources are discovered."),
        ("project_trust", "Project trust", "Runs when project trust state is evaluated."),
        ("ui_prompt_start", "UI prompt starts", "Runs when an extension UI prompt starts."),
        ("ui_prompt_end", "UI prompt ends", "Runs when an extension UI prompt ends."),
    ]

    static func issues(from resources: JSONValue?) -> [HookLoadIssue] {
        guard let values = resources?.objectValue?["extensionLoadErrors"]?.arrayValue else { return [] }
        return values.enumerated().map { HookLoadIssue(value: $0.element, index: $0.offset) }
    }
}

struct HookEventDescriptor: Identifiable, Equatable, Sendable {
    let identifier: String
    let title: String
    let purpose: String
    let isSupported: Bool
    var id: String { identifier }
}

struct HookEventRecord: Identifiable, Sendable {
    let descriptor: HookEventDescriptor
    let providers: [(extension: HookExtensionRecord, count: Int)]
    var id: String { descriptor.identifier }
    var handlerCount: Int { providers.reduce(0) { $0 + $1.count } }
}

struct HookExtensionDetailView: View {
    let record: HookExtensionRecord
    let title: String?
    let accent: Color
    @Environment(\.dismiss) private var dismiss
    @State private var showsInfo = false

    init(record: HookExtensionRecord, title: String? = nil, accent: Color) {
        self.record = record
        self.title = title
        self.accent = accent
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: TronSpacing.section) {
                    Text(record.handlers.isEmpty
                         ? "This extension is registered in the selected runtime but exposes no event handlers."
                         : "These handlers are registered in the selected runtime. Registration does not indicate recent execution or health.")
                        .font(TronTypography.body)
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tronGlassSurface(accent: accent, tintOpacity: 0.10)
                    TronSettingsGroup("Registered Handlers", detail: "\(record.handlerCount) handler\(record.handlerCount == 1 ? "" : "s") · \(record.eventCount) event\(record.eventCount == 1 ? "" : "s")", accent: accent, surfaceStyle: .scrollOptimized) {
                        if record.handlers.isEmpty {
                            TronSettingsRow(icon: "line.3.horizontal.decrease.circle", title: "No event handlers", subtitle: "No registrations were reported by the runtime.", accent: accent)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(record.handlers.enumerated()), id: \.element.id) { index, handler in
                                    if index > 0 { TronSettingsDivider(accent: accent) }
                                    TronSettingsRow(icon: "bolt.horizontal.circle", title: handler.event, subtitle: "\(handler.count) registered handler\(handler.count == 1 ? "" : "s")", accent: accent)
                                }
                            }
                        }
                    }
                    if !record.tools.isEmpty || !record.commands.isEmpty {
                        TronSettingsGroup("Other Registrations", accent: .tronSlate, surfaceStyle: .scrollOptimized) {
                            if !record.tools.isEmpty { TronSettingsRow(icon: "wrench.and.screwdriver", title: "Tools", subtitle: record.tools.joined(separator: ", "), accent: .tronSlate) }
                            if !record.commands.isEmpty { TronSettingsRow(icon: "command", title: "Commands", subtitle: record.commands.map { "/\($0)" }.joined(separator: ", "), accent: .tronSlate) }
                        }
                    }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .defaultScrollAnchor(.top)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsInfo = true } label: { Image(systemName: "info.circle").font(TronTypography.buttonSM).foregroundStyle(accent) }
                        .accessibilityLabel("Hook technical information")
                }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: title ?? record.friendlyName, accent: accent) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Image(systemName: "checkmark").font(TronTypography.buttonSM).foregroundStyle(accent) }
                        .accessibilityLabel("Done")
                }
            }
            .tint(accent)
        }
        .tronManagedSheet(isPresented: $showsInfo, identity: "hooks.info.\(record.id)") {
            TronTechnicalJSONRow(value: .object([
                "name": .string(record.name),
                "displayName": .string(title ?? record.friendlyName),
                "path": record.path.map(JSONValue.string) ?? .null,
                "resolvedPath": record.resolvedPath.map(JSONValue.string) ?? .null,
                "source": record.source.map(JSONValue.string) ?? .null,
                "scope": record.scope.map(JSONValue.string) ?? .null,
                "origin": record.origin.map(JSONValue.string) ?? .null,
                "provenance": .string(record.provenance.rawValue),
                "handlers": .array(record.handlers.map { .object(["event": .string($0.event), "count": .number(Double($0.count))]) }),
            ]), title: "Hook Technical Details", subtitle: "Runtime registration metadata", sheetTitle: "Hook Details", accent: accent)
                .padding(18)
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronSettingsVisualTheme(accent: accent)
    }
}
