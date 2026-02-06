import SwiftUI

/// Describes the UI configuration for a single tool type.
/// Used by both ToolResultRouter (expanded view) and CommandToolChipData (chip view).
struct ToolDescriptor: @unchecked Sendable {
    /// SF Symbol name for the tool icon
    let icon: String
    /// Icon color
    let iconColor: Color
    /// Human-readable display name
    let displayName: String
    /// Extracts a one-line summary from raw JSON arguments
    let summaryExtractor: @Sendable (String) -> String
    /// Creates a tool-specific result viewer (nil = use GenericResultViewer)
    let viewerFactory: (@MainActor (ToolUseData, Binding<Bool>) -> AnyView)?
}

/// Single source of truth for tool UI configuration.
/// Adding a new tool = one entry here.
enum ToolRegistry {

    /// Look up the descriptor for a given tool name (case-insensitive).
    static func descriptor(for toolName: String) -> ToolDescriptor {
        let key = toolName.lowercased()
        return allDescriptors[key] ?? defaultDescriptor(for: toolName)
    }

    // MARK: - Tool Sets

    /// All tools rendered as command-tool chips (tappable inline chips).
    static let commandToolNames: Set<String> = [
        "read", "write", "edit",
        "bash",
        "search", "glob", "find",
        "browsetheweb", "openurl",
        "webfetch", "websearch",
        "task",
        "remember"
    ]

    /// Special tools with dedicated non-chip UI.
    static let specialToolNames: Set<String> = [
        "askuserquestion",
        "spawnsubagent", "queryagent", "waitforagents",
        "renderappui",
        "todowrite",
        "notifyapp",
        "adapt"
    ]

    /// Check if a tool should be rendered as a command-tool chip.
    static func isCommandTool(_ toolName: String) -> Bool {
        commandToolNames.contains(toolName.lowercased())
    }

    // MARK: - Registry

    private static let allDescriptors: [String: ToolDescriptor] = [
        "read": ToolDescriptor(
            icon: "doc.text",
            iconColor: .tronSlate,
            displayName: "Read",
            summaryExtractor: { args in
                ToolArgumentParser.shortenPath(ToolArgumentParser.filePath(from: args))
            },
            viewerFactory: { tool, isExpanded in
                AnyView(ReadResultViewer(
                    filePath: ToolArgumentParser.filePath(from: tool.arguments),
                    content: tool.result ?? "",
                    isExpanded: isExpanded
                ))
            }
        ),
        "write": ToolDescriptor(
            icon: "doc.badge.plus",
            iconColor: .tronPink,
            displayName: "Write",
            summaryExtractor: { args in
                ToolArgumentParser.shortenPath(ToolArgumentParser.filePath(from: args))
            },
            viewerFactory: { tool, isExpanded in
                AnyView(WriteResultViewer(
                    filePath: ToolArgumentParser.filePath(from: tool.arguments),
                    content: ToolArgumentParser.content(from: tool.arguments),
                    result: tool.result ?? ""
                ))
            }
        ),
        "edit": ToolDescriptor(
            icon: "pencil.line",
            iconColor: .orange,
            displayName: "Edit",
            summaryExtractor: { args in
                ToolArgumentParser.shortenPath(ToolArgumentParser.filePath(from: args))
            },
            viewerFactory: { tool, isExpanded in
                AnyView(EditResultViewer(
                    filePath: ToolArgumentParser.filePath(from: tool.arguments),
                    result: tool.result ?? "",
                    isExpanded: isExpanded
                ))
            }
        ),
        "bash": ToolDescriptor(
            icon: "terminal",
            iconColor: .tronEmerald,
            displayName: "Bash",
            summaryExtractor: { args in
                ToolArgumentParser.truncate(ToolArgumentParser.command(from: args))
            },
            viewerFactory: { tool, isExpanded in
                AnyView(BashResultViewer(
                    command: ToolArgumentParser.command(from: tool.arguments),
                    output: tool.result ?? "",
                    isExpanded: isExpanded
                ))
            }
        ),
        "search": ToolDescriptor(
            icon: "magnifyingglass",
            iconColor: .purple,
            displayName: "Search",
            summaryExtractor: { args in
                let pattern = ToolArgumentParser.pattern(from: args)
                let path = ToolArgumentParser.path(from: args)
                if !path.isEmpty && path != "." {
                    return "\"\(pattern)\" in \(ToolArgumentParser.shortenPath(path))"
                }
                return "\"\(pattern)\""
            },
            viewerFactory: { tool, isExpanded in
                AnyView(SearchToolViewer(
                    pattern: ToolArgumentParser.pattern(from: tool.arguments),
                    result: tool.result ?? "",
                    isExpanded: isExpanded
                ))
            }
        ),
        "find": ToolDescriptor(
            icon: "doc.text.magnifyingglass",
            iconColor: .cyan,
            displayName: "Find",
            summaryExtractor: { args in ToolArgumentParser.pattern(from: args) },
            viewerFactory: { tool, isExpanded in
                AnyView(FindResultViewer(
                    pattern: ToolArgumentParser.pattern(from: tool.arguments),
                    result: tool.result ?? "",
                    isExpanded: isExpanded
                ))
            }
        ),
        "glob": ToolDescriptor(
            icon: "doc.text.magnifyingglass",
            iconColor: .cyan,
            displayName: "Glob",
            summaryExtractor: { args in ToolArgumentParser.pattern(from: args) },
            viewerFactory: { tool, isExpanded in
                AnyView(FindResultViewer(
                    pattern: ToolArgumentParser.pattern(from: tool.arguments),
                    result: tool.result ?? "",
                    isExpanded: isExpanded
                ))
            }
        ),
        "browsetheweb": ToolDescriptor(
            icon: "globe",
            iconColor: .blue,
            displayName: "Browse Web",
            summaryExtractor: { args in
                let action = ToolArgumentParser.action(from: args)
                guard !action.isEmpty else { return "" }
                if action == "navigate" {
                    let url = ToolArgumentParser.url(from: args)
                    if !url.isEmpty { return "\(action): \(url)" }
                }
                if ["click", "fill", "type", "select"].contains(action) {
                    let selector = ToolArgumentParser.string("selector", from: args) ?? ""
                    if !selector.isEmpty { return "\(action): \(selector)" }
                }
                return action
            },
            viewerFactory: { tool, isExpanded in
                let action = ToolArgumentParser.action(from: tool.arguments)
                let selector = ToolArgumentParser.string("selector", from: tool.arguments) ?? ""
                let url = ToolArgumentParser.url(from: tool.arguments)
                let detail = !action.isEmpty ? (action == "navigate" && !url.isEmpty ? "\(action): \(url)" : (!selector.isEmpty ? "\(action): \(selector)" : action)) : ""
                return AnyView(BrowserToolViewer(
                    action: detail,
                    result: tool.result ?? "",
                    isExpanded: isExpanded
                ))
            }
        ),
        "openurl": ToolDescriptor(
            icon: "safari",
            iconColor: .blue,
            displayName: "Open URL",
            summaryExtractor: { args in
                let url = ToolArgumentParser.url(from: args)
                return url.count > 50 ? String(url.prefix(50)) + "..." : url
            },
            viewerFactory: { tool, isExpanded in
                let url = ToolArgumentParser.url(from: tool.arguments)
                let display = url.count > 50 ? String(url.prefix(50)) + "..." : url
                return AnyView(OpenURLResultViewer(
                    url: display,
                    result: tool.result ?? "",
                    isExpanded: isExpanded
                ))
            }
        ),
        "webfetch": ToolDescriptor(
            icon: "arrow.down.doc",
            iconColor: .tronInfo,
            displayName: "Fetch",
            summaryExtractor: { args in
                let url = ToolArgumentParser.url(from: args)
                let prompt = ToolArgumentParser.string("prompt", from: args) ?? ""
                if !url.isEmpty {
                    let domain = ToolArgumentParser.extractDomain(from: url)
                    if !prompt.isEmpty {
                        let shortPrompt = ToolArgumentParser.truncate(prompt, maxLength: 27)
                        return "\(domain): \(shortPrompt)"
                    }
                    return domain
                }
                return prompt.isEmpty ? "" : ToolArgumentParser.truncate(prompt)
            },
            viewerFactory: { tool, isExpanded in
                AnyView(WebFetchResultViewer(
                    result: tool.result ?? "",
                    arguments: tool.arguments,
                    isExpanded: isExpanded
                ))
            }
        ),
        "websearch": ToolDescriptor(
            icon: "magnifyingglass.circle",
            iconColor: .tronInfo,
            displayName: "Search",
            summaryExtractor: { args in
                let query = ToolArgumentParser.query(from: args)
                guard !query.isEmpty else { return "" }
                return "\"\(ToolArgumentParser.truncate(query, maxLength: 37))\""
            },
            viewerFactory: { tool, isExpanded in
                AnyView(WebSearchResultViewer(
                    result: tool.result ?? "",
                    arguments: tool.arguments,
                    isExpanded: isExpanded
                ))
            }
        ),
        "askuserquestion": ToolDescriptor(
            icon: "questionmark.circle.fill",
            iconColor: .tronAmber,
            displayName: "Ask User",
            summaryExtractor: { _ in "" },
            viewerFactory: nil
        ),
        "task": ToolDescriptor(
            icon: "arrow.triangle.branch",
            iconColor: .tronAmber,
            displayName: "Task",
            summaryExtractor: { args in
                let desc = ToolArgumentParser.string("description", from: args) ?? ToolArgumentParser.string("prompt", from: args) ?? ""
                return ToolArgumentParser.truncate(desc)
            },
            viewerFactory: nil
        ),
        "remember": ToolDescriptor(
            icon: "brain.fill",
            iconColor: .purple,
            displayName: "Remember",
            summaryExtractor: { args in
                let action = ToolArgumentParser.string("action", from: args) ?? ""
                return action.isEmpty ? "" : action
            },
            viewerFactory: nil
        )
    ]

    private static func defaultDescriptor(for toolName: String) -> ToolDescriptor {
        ToolDescriptor(
            icon: "gearshape",
            iconColor: .tronTextMuted,
            displayName: toolName.capitalized,
            summaryExtractor: { _ in "" },
            viewerFactory: nil
        )
    }
}
