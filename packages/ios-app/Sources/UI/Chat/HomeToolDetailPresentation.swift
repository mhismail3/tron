import Foundation
import TronMobileCore

/// The purpose-built detail of one Home tool call (`delegate`, `task`, `settings`,
/// `profile`, `zoom`, `date`, `memory_search`): what was asked, what happened and
/// the content it carried, as header, rows, Markdown texts and line lists that
/// `HomeToolDetailSections` renders with the shared settings components.
///
/// The builders read the call's arguments and its typed result details. A shape
/// they do not recognize returns nil, so the call keeps the generic tool detail,
/// and Technical details always keeps the raw request and result.
struct HomeToolDetailPresentation: Hashable, Sendable {
    enum Tone: Hashable, Sendable { case success, pending, failure, neutral }

    struct Header: Hashable, Sendable {
        let icon: String
        let title: String
        let subtitle: String?
        let pill: String
        let tone: Tone
    }

    struct Row: Hashable, Sendable {
        let icon: String
        let title: String
        let value: String
        var id: String { "\(title):\(value)" }
    }

    /// A line of memory or a search hit: a short preview that opens whole.
    struct Line: Hashable, Sendable, Identifiable {
        let id: String
        let icon: String
        let title: String
        let preview: String
        let full: String
    }

    struct TaskRow: Hashable, Sendable, Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let state: String
        let tone: Tone
    }

    enum Section: Hashable, Sendable {
        case tasks(summary: String, footer: String?, rows: [TaskRow])
        /// An error or refusal, shown first in the error tint.
        case failure(title: String, message: String, issues: [String])
        case rows(title: String?, detail: String?, rows: [Row])
        /// Markdown text, previewed and opened whole from View All when long.
        case text(id: String, title: String, text: String, detail: String? = nil)
        case prompt(id: String, title: String, text: String, detail: String? = nil)
        case lines(id: String, title: String, detail: String?, lines: [Line])
    }

    let header: Header
    let sections: [Section]

    static let toolNames: Set<String> = ["delegate", "task", "settings", "profile", "zoom", "date", "memory_search"]

    static func make(tool: ChatToolPresentation) -> HomeToolDetailPresentation? {
        let name = tool.toolName ?? tool.title
        // Tron's own modules are inline extensions; a package or project tool of the
        // same name keeps the generic detail.
        guard toolNames.contains(name), tool.extensionOrigin.map({ $0.owner?.source == "inline" }) ?? true else { return nil }
        let call = Call(tool: tool)
        // A bounded preview of the arguments is not the request; keep the raw view.
        if call.arguments["truncated"]?.boolValue == true { return nil }
        return switch name {
        case "delegate": delegate(call)
        case "task": task(call)
        case "settings": settings(call)
        case "profile": profile(call)
        case "zoom": zoom(call)
        case "date": date(call)
        case "memory_search": memorySearch(call)
        default: nil
        }
    }
}

// MARK: - Call inputs

extension HomeToolDetailPresentation {
    /// One call's inputs, read once: arguments, typed details and the result text.
    struct Call {
        let arguments: [String: JSONValue]
        let details: [String: JSONValue]?
        let text: String
        let error: Bool
        let running: Bool

        init(tool: ChatToolPresentation) {
            arguments = tool.request?.objectValue ?? [:]
            let details = tool.details ?? tool.response?.objectValue?["details"]
            self.details = details?.objectValue.flatMap { $0.isEmpty ? nil : $0 }
            text = ToolDetailPresentation.readableResult(tool: tool) ?? ""
            error = tool.error
            running = tool.isRunning
        }

        func string(_ key: String) -> String? {
            arguments[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }

        func detail(_ key: String) -> String? {
            details?[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }

        /// A failed call's failure section: a schema rejection lists its issues, any
        /// other error states the tool's own message.
        var failure: Section? {
            guard error else { return nil }
            return HomeToolDetailPresentation.failure(text)
        }
    }

    static func failure(_ text: String) -> Section {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("Validation failed for tool") {
            let body = trimmed.components(separatedBy: "\n\nReceived arguments:").first ?? trimmed
            var seen = Set<String>()
            let issues = body.split(separator: "\n").compactMap { line -> String? in
                let item = line.trimmingCharacters(in: .whitespaces)
                guard item.hasPrefix("- ") else { return nil }
                let issue = String(item.dropFirst(2))
                return seen.insert(issue).inserted ? issue : nil
            }
            return .failure(title: "Rejected before it ran",
                            message: "The arguments did not match the tool's schema, so nothing happened.", issues: issues)
        }
        return .failure(title: "Error", message: trimmed.isEmpty ? "The tool failed without a message." : trimmed, issues: [])
    }

    static func runningHeader(icon: String, title: String, subtitle: String?) -> Header {
        Header(icon: icon, title: title, subtitle: subtitle, pill: "Running", tone: .pending)
    }

    static func modelName(_ reference: String) -> String {
        let parts = reference.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return reference }
        return ModelRef(provider: parts[0], id: parts[1]).displayName
    }

    static func basename(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? path
    }

    static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural ?? singular + "s")"
    }

    static func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
}

// MARK: - settings

extension HomeToolDetailPresentation {
    static func layerLabel(_ layer: String) -> String {
        switch layer {
        case "chat": "Chat"
        case "profile": "Home profile"
        case "project": "Project"
        case "mac": "Mac"
        case "builtin": "Built-in"
        default: layer.capitalized
        }
    }

    /// A setting value as the Settings rows read it: unset, a model reference, a
    /// boolean, or the value's compact text.
    static func settingValue(_ value: JSONValue?) -> String {
        guard let value, value != .null else { return "Not set" }
        if let text = value.stringValue { return text.isEmpty ? "Empty" : text }
        if let flag = value.boolValue { return flag ? "On" : "Off" }
        if case .number(let number) = value { return number.formatted() }
        if let object = value.objectValue {
            if let provider = object["provider"]?.stringValue, let id = object["id"]?.stringValue {
                return ModelRef(provider: provider, id: id).displayName
            }
            if object["sameAs"]?.stringValue == "home" { return "Same as Home" }
        }
        if let data = try? JSONEncoder.gateway.encode(value), let text = String(data: data, encoding: .utf8) { return text }
        return "Value"
    }

    static func statusLabel(_ status: String) -> String {
        switch status {
        case "applied": "Applied"
        case "pending": "Pending approval"
        case "approved": "Approved"
        case "declined": "Declined"
        case "expired": "Expired"
        case "superseded": "Superseded"
        case "failed": "Failed"
        case "outside": "Changed outside Tron"
        case "committed": "Committed"
        default: status.capitalized
        }
    }

    private static func tone(forStatus status: String) -> Tone {
        switch status {
        case "applied", "approved", "committed": .success
        case "pending": .pending
        case "declined", "expired", "failed": .failure
        default: .neutral
        }
    }

    private static func keyTitle(_ key: String, qualifiers: [String: JSONValue]?) -> String {
        guard let qualifiers, !qualifiers.isEmpty else { return key }
        let suffix = qualifiers.keys.sorted().compactMap { name in qualifiers[name]?.stringValue.map { "\(name) \($0)" } }
        return suffix.isEmpty ? key : "\(key) · \(suffix.joined(separator: ", "))"
    }

    private static func settings(_ call: Call) -> HomeToolDetailPresentation? {
        switch call.string("action") {
        case "resolve": return settingsResolve(call)
        case "change": return settingsChange(call)
        default: return nil
        }
    }

    private static func settingsResolve(_ call: Call) -> HomeToolDetailPresentation? {
        let requested = call.arguments["keys"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let subtitle = requested.isEmpty ? "Every setting for this chat" : count(requested.count, "key")
        if call.running { return HomeToolDetailPresentation(header: runningHeader(icon: "slider.horizontal.3", title: "Read settings", subtitle: subtitle), sections: []) }
        if call.error {
            let rows = requested.map { Row(icon: "key", title: $0, value: "Requested") }
            return HomeToolDetailPresentation(header: Header(icon: "slider.horizontal.3", title: "Read settings", subtitle: subtitle, pill: "Error", tone: .failure),
                                              sections: [call.failure].compactMap { $0 } + (rows.isEmpty ? [] : [.rows(title: "Requested", detail: nil, rows: rows)]))
        }
        guard let keys = call.details?["keys"]?.arrayValue else { return nil }
        let limit = 60
        let rows: [Row] = keys.prefix(limit).compactMap { value in
            guard let object = value.objectValue, let key = object["key"]?.stringValue else { return nil }
            let display = object["display"]?.stringValue ?? settingValue(object["value"])
            let layer = object["layer"]?.stringValue.map(layerLabel)
            let unapplied = object["applied"]?.boolValue == false ? "not applied" : nil
            return Row(icon: "key", title: keyTitle(key, qualifiers: object["qualifiers"]?.objectValue),
                       value: [display, layer, unapplied].compactMap { $0 }.joined(separator: " · "))
        }
        let layers = call.details?["layers"]?.arrayValue?.compactMap(\.stringValue).map(layerLabel)
        let detail = [layers.map { "Layers, top wins: \($0.joined(separator: " > "))." },
                      keys.count > limit ? "\(keys.count - limit) more in Technical details." : nil].compactMap { $0 }.joined(separator: " ")
        return HomeToolDetailPresentation(
            header: Header(icon: "slider.horizontal.3", title: "Read settings", subtitle: count(keys.count, "key"), pill: "Read", tone: .neutral),
            sections: [.rows(title: "Values", detail: detail.isEmpty ? nil : detail, rows: rows)])
    }

    private static func settingsChange(_ call: Call) -> HomeToolDetailPresentation? {
        let requests = call.arguments["changes"]?.arrayValue?.compactMap(\.objectValue) ?? []
        guard !requests.isEmpty else { return nil }
        let dryRun = call.arguments["dryRun"]?.boolValue == true
        let title = dryRun ? "Check a settings change" : requests.count == 1 ? "Change a setting" : "Change \(requests.count) settings"
        let outcomes = call.details?["changes"]?.arrayValue?.compactMap(\.objectValue)
        let status = call.details?["status"]?.stringValue
        let tier = call.details?["tier"]?.stringValue
        let header: Header
        if call.running { header = runningHeader(icon: "slider.horizontal.3", title: title, subtitle: nil) }
        else if call.error { header = Header(icon: "slider.horizontal.3", title: title, subtitle: nil, pill: "Error", tone: .failure) }
        else if let status {
            let pill = dryRun ? "Dry run · \(tier?.capitalized ?? "")" : statusLabel(status)
            header = Header(icon: "slider.horizontal.3", title: title, subtitle: tier.map { "\($0.capitalized) tier" },
                            pill: pill, tone: dryRun ? .neutral : tone(forStatus: status))
        } else { return nil }

        var sections: [Section] = []
        if let failure = call.failure { sections.append(failure) }
        for (index, request) in requests.enumerated() {
            guard let key = request["key"]?.stringValue else { continue }
            let outcome = outcomes.flatMap { index < $0.count ? $0[index] : nil }
            let layer = (outcome?["layer"]?.stringValue ?? request["layer"]?.stringValue).map(layerLabel) ?? "Unknown layer"
            let unset = request["op"]?.stringValue == "unset"
            var rows = [Row(icon: "square.3.layers.3d", title: "Layer", value: layer)]
            if outcome?["redacted"]?.boolValue == true {
                rows.append(Row(icon: "eye.slash", title: "Value", value: "Hidden for this key"))
            } else {
                let before = outcome?["before"] ?? request["expected"]
                let after = outcome?["after"] ?? (unset ? nil : request["value"])
                let from = before.map(settingValue)
                let to = unset && outcome?["after"] == nil ? "Unset" : settingValue(after)
                rows.append(Row(icon: "arrow.right", title: unset ? "Unset" : "Set", value: from.map { "\($0) → \(to)" } ?? to))
            }
            if let changeTier = outcome?["tier"]?.stringValue { rows.append(Row(icon: "shield.lefthalf.filled", title: "Tier", value: changeTier.capitalized)) }
            if let changeStatus = outcome?["status"]?.stringValue, !dryRun { rows.append(Row(icon: "checkmark.circle", title: "Status", value: statusLabel(changeStatus))) }
            if let confirm = outcome?["confirm"]?.stringValue { rows.append(Row(icon: "exclamationmark.bubble", title: "Approval asks", value: confirm)) }
            if let message = outcome?["error"]?.objectValue?["message"]?.stringValue { rows.append(Row(icon: "exclamationmark.triangle", title: "Error", value: message)) }
            sections.append(.rows(title: keyTitle(key, qualifiers: request["qualifiers"]?.objectValue), detail: nil, rows: rows))
        }
        if let approval = call.details?["approval"]?.objectValue {
            var rows: [Row] = []
            if let request = approval["requestId"]?.stringValue { rows.append(Row(icon: "number", title: "Request", value: request)) }
            if let expires = approval["expiresAt"]?.stringValue { rows.append(Row(icon: "hourglass", title: "Expires", value: HomeSheetTime.absolute(expires))) }
            sections.append(.rows(title: "Approval", detail: "Nothing changes until you approve it in Manage Home.", rows: rows))
        }
        if let reason = call.string("reason") { sections.append(.text(id: "reason", title: "Reason", text: reason)) }
        return HomeToolDetailPresentation(header: header, sections: sections)
    }
}

// MARK: - profile

extension HomeToolDetailPresentation {
    private static func profile(_ call: Call) -> HomeToolDetailPresentation? {
        guard let action = call.string("action") else { return nil }
        let title = switch action {
        case "learn": "Learn a profile item"
        case "refine": "Refine a profile item"
        case "supersede": "Supersede a profile item"
        case "retire": "Retire a profile item"
        default: "Profile"
        }
        let kind = call.detail("kind") ?? call.string("kind")
        let kindTitle = kind.map(HomeProfilePresentation.kindTitle(wire:))
        let icon = kind.flatMap { HomeProfileListDTO.Item.Kind(rawValue: $0) }.map(HomeProfilePresentation.kindIcon) ?? "person.text.rectangle"
        let status = call.detail("status")
        let header: Header
        if call.running { header = runningHeader(icon: icon, title: title, subtitle: kindTitle) }
        else if call.error { header = Header(icon: icon, title: title, subtitle: kindTitle, pill: "Error", tone: .failure) }
        else {
            switch status {
            case "saved": header = Header(icon: icon, title: title, subtitle: kindTitle, pill: action == "retire" ? "Retired" : "Saved · Inferred", tone: .success)
            case "refused": header = Header(icon: icon, title: title, subtitle: kindTitle, pill: "Refused", tone: .failure)
            case "unavailable": header = Header(icon: icon, title: title, subtitle: kindTitle, pill: "Unavailable", tone: .failure)
            default: return nil
            }
        }
        var sections: [Section] = []
        if let failure = call.failure { sections.append(failure) }
        if status == "refused" { sections.append(.failure(title: "Refused", message: call.detail("reason") ?? call.text, issues: [])) }
        if status == "unavailable" { sections.append(.failure(title: "Unavailable", message: call.text, issues: [])) }
        var rows: [Row] = []
        if let kindTitle { rows.append(Row(icon: "tag", title: "Kind", value: kindTitle)) }
        if let id = call.detail("id") ?? call.string("id") { rows.append(Row(icon: "number", title: action == "supersede" ? "New note" : "Note ID", value: id)) }
        if let superseded = call.detail("supersededId") ?? (action == "supersede" ? call.string("id") : nil) {
            rows.append(Row(icon: "arrow.triangle.2.circlepath", title: "Supersedes note", value: superseded))
        }
        if status == "saved", action != "retire" {
            rows.append(Row(icon: "sparkle", title: "State", value: "Inferred until you confirm it; applies from Home's next activation"))
        }
        if !rows.isEmpty { sections.append(.rows(title: nil, detail: nil, rows: rows)) }
        if let text = call.string("text") { sections.append(.text(id: "text", title: action == "learn" ? "Text" : "New text", text: text)) }
        if let previous = call.detail("previousText") {
            sections.append(.text(id: "previous", title: action == "retire" ? "Retired text" : "Replaced text", text: previous))
        }
        if let reason = call.string("reason") { sections.append(.text(id: "reason", title: "Reason", text: reason)) }
        return HomeToolDetailPresentation(header: header, sections: sections)
    }
}

// MARK: - memory tools

extension HomeToolDetailPresentation {
    /// One view line `id+n|text`, its kind prefix read for a message line.
    struct MemoryLine {
        let start: Int
        let span: Int
        let text: String

        /// `user`, `talk`, `echo` or `event` for a message line.
        var kind: HomeMemoryItemDTO.Kind? {
            guard span <= 1 else { return nil }
            return ["user", "talk", "echo", "event"].first { text.hasPrefix("\($0): ") }.flatMap(HomeMemoryItemDTO.Kind.init)
        }

        /// The line's text without its view tag: `user:`/`talk:`/`echo:`/`event:` for a
        /// message, `summary:` for a merged range.
        var body: String {
            if let kind { return String(text.dropFirst(kind.rawValue.count + 2)) }
            return text.hasPrefix("summary: ") ? String(text.dropFirst("summary: ".count)) : text
        }

        var line: Line {
            let attribution: HomeMemoryItemDTO.Attribution? = kind.map {
                switch $0 { case .user: .user; case .talk: .assistant; case .echo: .tool; case .event: .event }
            }
            let title = span <= 1
                ? ["Message \(start)", attribution.map(HomeSheet.attributionLabel)].compactMap { $0 }.joined(separator: " · ")
                : "Messages \(start)–\(start + span - 1)"
            return Line(id: "\(start)+\(span)", icon: attribution.map(HomeSheet.attributionIcon) ?? "text.append", title: title,
                        preview: body, full: body)
        }

        static func parse(_ text: String) -> MemoryLine? {
            guard let bar = text.firstIndex(of: "|") else { return nil }
            let address = text[..<bar].split(separator: "+")
            guard address.count == 2, let start = Int(address[0]), let span = Int(address[1]) else { return nil }
            return MemoryLine(start: start, span: span, text: String(text[text.index(after: bar)...]))
        }
    }

    private static func memoryFailure(_ call: Call) -> (pill: String, section: Section)? {
        if call.error { return ("Error", failure(call.text)) }
        switch call.detail("status") {
        case "invalid-arguments": return ("Not found", .failure(title: "Not found", message: call.text, issues: []))
        case "unavailable": return ("Unavailable", .failure(title: "Memory unavailable", message: call.text, issues: []))
        default: return nil
        }
    }

    private static func zoom(_ call: Call) -> HomeToolDetailPresentation? {
        guard case .number(let idValue)? = call.arguments["id"], case .number(let nValue)? = call.arguments["n"] else { return nil }
        let id = Int(idValue), n = Int(nValue)
        let title = "Line \(id)+\(n)"
        // Only an address the view can hold (n a power of two) names what it opens into.
        let valid = n >= 1 && n & (n - 1) == 0
        let subtitle: String? = !valid ? nil : n == 1 ? "The message whole" : "Opened into two lines of \(n / 2)"
        if call.running { return HomeToolDetailPresentation(header: runningHeader(icon: "plus.magnifyingglass", title: title, subtitle: subtitle), sections: []) }
        if let failed = memoryFailure(call) {
            return HomeToolDetailPresentation(header: Header(icon: "plus.magnifyingglass", title: title, subtitle: subtitle, pill: failed.pill, tone: .failure),
                                              sections: [failed.section])
        }
        guard call.detail("status") == "ok" else { return nil }
        let lines: [MemoryLine]
        if n <= 1 {
            guard let line = MemoryLine.parse(call.text) else { return nil }
            lines = [line]
        } else {
            // The second line starts at a known address; summary text may hold newlines.
            let half = n / 2
            let parts = call.text.components(separatedBy: "\n\(id + half)+\(half)|")
            guard parts.count == 2, let first = MemoryLine.parse(parts[0]) else { return nil }
            lines = [first, MemoryLine(start: id + half, span: half, text: parts[1])]
        }
        return HomeToolDetailPresentation(
            header: Header(icon: "plus.magnifyingglass", title: title, subtitle: subtitle, pill: "Opened", tone: .success),
            sections: [.lines(id: "zoom", title: n <= 1 ? "Message" : "Lines", detail: n <= 1 ? nil : "The two halves this line summarizes.",
                              lines: lines.map(\.line))])
    }

    private static func date(_ call: Call) -> HomeToolDetailPresentation? {
        guard let id = call.arguments["id"]?.intValue else { return nil }
        let title = "Message \(id)"
        if call.running { return HomeToolDetailPresentation(header: runningHeader(icon: "calendar", title: title, subtitle: nil), sections: []) }
        if let failed = memoryFailure(call) {
            return HomeToolDetailPresentation(header: Header(icon: "calendar", title: title, subtitle: nil, pill: failed.pill, tone: .failure),
                                              sections: [failed.section])
        }
        guard call.detail("status") == "ok" else { return nil }
        // The typed instant when the Gateway sends it; the recorded local text otherwise.
        let instant = call.details?["date"]?.objectValue?["at"]?.stringValue.flatMap(HomeChapterPresentation.parse)
            ?? MemoryLine.parse(call.text).flatMap { Self.localTimestamp($0.text) }
        guard let instant else { return nil }
        let rows = [
            Row(icon: "calendar", title: "Date", value: instant.formatted(.dateTime.weekday(.wide).day().month(.wide).year())),
            Row(icon: "clock", title: "Time", value: instant.formatted(.dateTime.hour().minute().second().timeZone())),
            Row(icon: "clock.arrow.circlepath", title: "Relative", value: RelativeDateTimeFormatter().localizedString(for: instant, relativeTo: .now)),
        ]
        return HomeToolDetailPresentation(
            header: Header(icon: "calendar", title: title, subtitle: instant.formatted(date: .abbreviated, time: .shortened), pill: "Found", tone: .success),
            sections: [.rows(title: nil, detail: nil, rows: rows)])
    }

    /// `2026-10-13 22:30:58 +02:00`, the memory's recorded local text.
    static func localTimestamp(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss xxx"
        return formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func memorySearch(_ call: Call) -> HomeToolDetailPresentation? {
        guard let query = call.arguments["query"]?.stringValue else { return nil }
        let title = "“\(query)”"
        let from = call.arguments["from"]?.intValue, to = call.arguments["to"]?.intValue
        let requested = (from != nil || to != nil) ? "Messages \(from ?? 0)–\(to.map { "\($0 - 1)" } ?? "end")" : "All messages"
        if call.running { return HomeToolDetailPresentation(header: runningHeader(icon: "magnifyingglass", title: title, subtitle: requested), sections: []) }
        if let failed = memoryFailure(call) {
            return HomeToolDetailPresentation(header: Header(icon: "magnifyingglass", title: title, subtitle: requested, pill: failed.pill, tone: .failure),
                                              sections: [failed.section])
        }
        guard call.detail("status") == "ok", let search = call.details?["search"]?.objectValue,
              let start = search["from"]?.intValue, let end = search["to"]?.intValue,
              let matches = search["matches"]?.intValue, let shown = search["shown"]?.intValue else { return nil }
        let omitted = search["omitted"]?.intValue ?? 0, capped = search["capped"]?.intValue ?? 0
        let hits = call.text.split(separator: "\n").dropFirst().compactMap { MemoryLine.parse(String($0))?.line }
        var rows = [
            Row(icon: "text.magnifyingglass", title: "Range", value: end > start ? "Messages \(start)–\(end - 1)" : "No messages"),
            Row(icon: "number", title: "Matches", value: matches > shown ? "\(matches.formatted()) · first \(shown.formatted()) shown" : matches.formatted()),
        ]
        if omitted > 0 || capped > 0 {
            rows.append(Row(icon: "eye.slash", title: "Not fully searchable",
                            value: "\(count(omitted, "message")) omitted · \(count(capped, "message")) capped"))
        }
        var sections: [Section] = [.rows(title: nil, detail: nil, rows: rows)]
        if !hits.isEmpty { sections.append(.lines(id: "hits", title: "Results", detail: "Oldest first.", lines: hits)) }
        return HomeToolDetailPresentation(
            header: Header(icon: "magnifyingglass", title: title, subtitle: requested,
                           pill: matches == 0 ? "No matches" : count(matches, "match", "matches"), tone: matches == 0 ? .neutral : .success),
            sections: sections)
    }
}
