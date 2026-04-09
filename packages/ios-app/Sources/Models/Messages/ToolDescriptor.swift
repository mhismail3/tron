import SwiftUI

/// Describes the UI configuration for a single tool type.
/// Used by both ToolResultRouter (expanded view) and CommandToolChipData (chip view).
struct ToolDescriptor: @unchecked Sendable {
    /// SF Symbol name for the tool icon
    let icon: String
    /// Icon color
    let iconColor: Color
    /// Icon color as a string name for serialization (e.g., "tronSlate")
    let iconColorName: String
    /// Human-readable display name (imperative: "Edit")
    let displayName: String
    /// Past-tense display name for completed state ("Edited"). Nil = use displayName always.
    let completedDisplayName: String?
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
        "webfetch", "websearch",
        "computeruse",
        "display",
        "managejob", "wait",
        "mcpsearch", "mcpcall"
    ]

    /// Special tools with dedicated non-chip UI.
    static let specialToolNames: Set<String> = [
        "askuserquestion",
        "getconfirmation",
        "spawnsubagent",
        "notifyapp"
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
            iconColorName: "tronSlate",
            displayName: "Read",
            completedDisplayName: "Read",
            summaryExtractor: { args in
                ToolArgumentParser.shortenPath(ToolArgumentParser.filePath(from: args))
            },
            viewerFactory: { tool, _ in
                AnyView(ReadResultViewer(
                    filePath: ToolArgumentParser.filePath(from: tool.arguments),
                    content: tool.result ?? ""
                ))
            }
        ),
        "write": ToolDescriptor(
            icon: "doc.badge.plus",
            iconColor: .tronPink,
            iconColorName: "tronPink",
            displayName: "Write",
            completedDisplayName: "Wrote",
            summaryExtractor: { args in
                ToolArgumentParser.shortenPath(ToolArgumentParser.filePath(from: args))
            },
            viewerFactory: { tool, _ in
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
            iconColorName: "orange",
            displayName: "Edit",
            completedDisplayName: "Edited",
            summaryExtractor: { args in
                ToolArgumentParser.shortenPath(ToolArgumentParser.filePath(from: args))
            },
            viewerFactory: { tool, _ in
                AnyView(EditResultViewer(
                    filePath: ToolArgumentParser.filePath(from: tool.arguments),
                    result: tool.result ?? ""
                ))
            }
        ),
        "bash": ToolDescriptor(
            icon: "terminal",
            iconColor: .tronEmerald,
            iconColorName: "tronEmerald",
            displayName: "Bash",
            completedDisplayName: "Ran",
            summaryExtractor: { args in
                BashSummaryHelper.summary(from: args)
            },
            viewerFactory: { tool, _ in
                AnyView(BashResultViewer(
                    command: ToolArgumentParser.command(from: tool.arguments),
                    output: tool.result ?? ""
                ))
            }
        ),
        "search": ToolDescriptor(
            icon: "magnifyingglass",
            iconColor: .purple,
            iconColorName: "purple",
            displayName: "File Search",
            completedDisplayName: "Searched",
            summaryExtractor: { args in
                let pattern = ToolArgumentParser.pattern(from: args)
                let path = ToolArgumentParser.path(from: args)
                if !path.isEmpty && path != "." {
                    return "\"\(pattern)\" in \(ToolArgumentParser.shortenPath(path))"
                }
                return "\"\(pattern)\""
            },
            viewerFactory: { tool, _ in
                AnyView(SearchToolViewer(
                    pattern: ToolArgumentParser.pattern(from: tool.arguments),
                    result: tool.result ?? ""
                ))
            }
        ),
        "find": ToolDescriptor(
            icon: "doc.text.magnifyingglass",
            iconColor: .cyan,
            iconColorName: "cyan",
            displayName: "Find",
            completedDisplayName: "Found",
            summaryExtractor: { args in ToolArgumentParser.pattern(from: args) },
            viewerFactory: { tool, _ in
                AnyView(FindResultViewer(
                    pattern: ToolArgumentParser.pattern(from: tool.arguments),
                    result: tool.result ?? ""
                ))
            }
        ),
        "glob": ToolDescriptor(
            icon: "doc.text.magnifyingglass",
            iconColor: .cyan,
            iconColorName: "cyan",
            displayName: "Glob",
            completedDisplayName: "Found",
            summaryExtractor: { args in ToolArgumentParser.pattern(from: args) },
            viewerFactory: { tool, _ in
                AnyView(FindResultViewer(
                    pattern: ToolArgumentParser.pattern(from: tool.arguments),
                    result: tool.result ?? ""
                ))
            }
        ),
        "webfetch": ToolDescriptor(
            icon: "arrow.down.doc",
            iconColor: .tronInfo,
            iconColorName: "tronInfo",
            displayName: "Web Fetch",
            completedDisplayName: "Fetched",
            summaryExtractor: { args in
                let url = ToolArgumentParser.url(from: args)
                let method = ToolArgumentParser.string("method", from: args)?.uppercased()
                let prompt = ToolArgumentParser.string("prompt", from: args) ?? ""
                let rawResponse = ToolArgumentParser.boolean("rawResponse", from: args) ?? false
                let domain = !url.isEmpty ? ToolArgumentParser.extractDomain(from: url) : ""

                // Raw mode: show method + domain
                if rawResponse || (method != nil && method != "GET") || prompt.isEmpty {
                    if let method, method != "GET", !domain.isEmpty {
                        return "\(method) \(domain)"
                    }
                    if !domain.isEmpty { return domain }
                }

                // Summarization mode: show domain: prompt
                if !domain.isEmpty {
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
                    details: tool.details,
                    arguments: tool.arguments,
                    isExpanded: isExpanded
                ))
            }
        ),
        "websearch": ToolDescriptor(
            icon: "magnifyingglass.circle",
            iconColor: .tronInfo,
            iconColorName: "tronInfo",
            displayName: "Web Search",
            completedDisplayName: "Searched",
            summaryExtractor: { args in
                let query = ToolArgumentParser.query(from: args)
                guard !query.isEmpty else { return "" }
                return "\"\(ToolArgumentParser.truncate(query, maxLength: 37))\""
            },
            viewerFactory: { tool, isExpanded in
                AnyView(WebSearchResultViewer(
                    details: tool.details,
                    arguments: tool.arguments,
                    isExpanded: isExpanded
                ))
            }
        ),
        "computeruse": ToolDescriptor(
            icon: "desktopcomputer",
            iconColor: .purple,
            iconColorName: "purple",
            displayName: "Computer Use",
            completedDisplayName: "Used",
            summaryExtractor: { args in
                ComputerUseSummaryHelper.summary(from: args)
            },
            viewerFactory: { tool, _ in
                AnyView(ComputerUseResultViewer(
                    result: tool.result ?? ""
                ))
            }
        ),
        "display": ToolDescriptor(
            icon: "rectangle.on.rectangle",
            iconColor: .tronIndigo,
            iconColorName: "tronIndigo",
            displayName: "Display",
            completedDisplayName: "Displayed",
            summaryExtractor: { args in
                let type_ = ToolArgumentParser.string("type", from: args) ?? ""
                let title = ToolArgumentParser.string("title", from: args) ?? ""
                if !title.isEmpty { return "\(type_): \(ToolArgumentParser.truncate(title, maxLength: 30))" }
                return type_
            },
            viewerFactory: nil
        ),
        "mcpsearch": ToolDescriptor(
            icon: "magnifyingglass.circle",
            iconColor: .tronInfo,
            iconColorName: "tronInfo",
            displayName: "MCP Search",
            completedDisplayName: "Searched MCP",
            summaryExtractor: { args in
                let query = ToolArgumentParser.string("query", from: args) ?? ""
                let server = ToolArgumentParser.string("server", from: args)
                if let server, !server.isEmpty {
                    return "\"\(ToolArgumentParser.truncate(query, maxLength: 25))\" on \(server)"
                }
                return query.isEmpty ? "" : "\"\(ToolArgumentParser.truncate(query, maxLength: 37))\""
            },
            viewerFactory: nil
        ),
        "mcpcall": ToolDescriptor(
            icon: "server.rack",
            iconColor: .tronEmerald,
            iconColorName: "tronEmerald",
            displayName: "MCP Call",
            completedDisplayName: "Called MCP",
            summaryExtractor: { args in
                let server = ToolArgumentParser.string("server", from: args) ?? ""
                let tool = ToolArgumentParser.string("tool", from: args) ?? ""
                if !server.isEmpty && !tool.isEmpty {
                    return "\(server).\(tool)"
                }
                return server.isEmpty ? tool : server
            },
            viewerFactory: nil
        ),
        "askuserquestion": ToolDescriptor(
            icon: "questionmark.circle.fill",
            iconColor: .tronAmber,
            iconColorName: "tronAmber",
            displayName: "Ask User",
            completedDisplayName: "Asked",
            summaryExtractor: { _ in "" },
            viewerFactory: nil
        ),
        "getconfirmation": ToolDescriptor(
            icon: "checkmark.shield",
            iconColor: .orange,
            iconColorName: "orange",
            displayName: "Confirm",
            completedDisplayName: "Confirmed",
            summaryExtractor: { args in
                ToolArgumentParser.string("action", from: args) ?? ""
            },
            viewerFactory: nil
        ),
        "managejob": ToolDescriptor(
            icon: "gearshape.2",
            iconColor: .tronSlate,
            iconColorName: "tronSlate",
            displayName: "Jobs",
            completedDisplayName: "Managed",
            summaryExtractor: { args in
                ToolArgumentParser.string("action", from: args) ?? ""
            },
            viewerFactory: nil
        ),
        "wait": ToolDescriptor(
            icon: "clock.arrow.circlepath",
            iconColor: .tronTeal,
            iconColorName: "tronTeal",
            displayName: "Wait",
            completedDisplayName: "Waited",
            summaryExtractor: { args in
                let ids = ToolArgumentParser.stringArray("ids", from: args) ?? []
                return ids.isEmpty ? "" : "\(ids.count) job\(ids.count == 1 ? "" : "s")"
            },
            viewerFactory: nil
        ),
        // Aliases for tool names that differ between streaming events and registry
        "grep": ToolDescriptor(
            icon: "magnifyingglass",
            iconColor: .purple,
            iconColorName: "purple",
            displayName: "Grep",
            completedDisplayName: "Searched",
            summaryExtractor: { args in
                let pattern = ToolArgumentParser.pattern(from: args)
                guard !pattern.isEmpty else { return "" }
                return "\"\(ToolArgumentParser.truncate(pattern, maxLength: 30))\""
            },
            viewerFactory: nil
        ),
        // Special tools — not command chips, but need metadata for dashboard cards
        "notifyapp": ToolDescriptor(
            icon: "bell.badge.fill",
            iconColor: .tronSuccess,
            iconColorName: "tronSuccess",
            displayName: "Notification sent",
            completedDisplayName: "Notification sent",
            summaryExtractor: { _ in "" },
            viewerFactory: nil
        ),
        "spawnsubagent": ToolDescriptor(
            icon: "checkmark.circle.fill",
            iconColor: .tronSuccess,
            iconColorName: "tronSuccess",
            displayName: "Subagent",
            completedDisplayName: "Subagent",
            summaryExtractor: { args in ToolArgumentParser.string("task", from: args) ?? "" },
            viewerFactory: nil
        ),
    ]

    private static func defaultDescriptor(for toolName: String) -> ToolDescriptor {
        ToolDescriptor(
            icon: "gearshape",
            iconColor: .tronTextMuted,
            iconColorName: "tronTextMuted",
            displayName: toolName.capitalized,
            completedDisplayName: nil,
            summaryExtractor: { _ in "" },
            viewerFactory: nil
        )
    }
}
