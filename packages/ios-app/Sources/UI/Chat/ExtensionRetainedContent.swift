import SwiftUI
import TronMobileCore

struct ExtensionRetainedContent: Equatable {
    enum Style: Equatable {
        case text([String])
        case frame(ExtensionFrame)
        case status(String)
    }

    struct Entry: Equatable, Identifiable {
        let id: String
        let producer: String
        let style: Style
    }

    let entries: [Entry]

    var isEmpty: Bool { entries.isEmpty }

    var producers: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        var unknownCount = 0
        for entry in entries {
            guard entry.producer != Self.unknownProducer else { continue }
            guard seen.insert(entry.producer).inserted else { continue }
            ordered.append(entry.producer)
        }
        unknownCount = entries.filter { $0.producer == Self.unknownProducer }.count
        return unknownCount > 0 ? ordered + [Self.unknownProducer] : ordered
    }

    func entries(forProducer producer: String) -> [Entry] {
        entries.filter { $0.producer == producer }
    }

    static let unknownProducer = "Unknown extension"
}

enum ExtensionRetainedContentPolicy {
    static func presentableWidgetLines(_ widget: ExtensionWidget) -> [String] {
        widget.lines
            .map(NativeExtensionText.clean)
            .filter { !$0.isEmpty }
    }

    static func presentableStatusText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func presentableStatuses(
        _ statuses: [String: String]?
    ) -> [(key: String, text: String)] {
        (statuses ?? [:]).keys.sorted().compactMap { key in
            let text = presentableStatusText(statuses?[key] ?? "")
            return text.isEmpty ? nil : (key, text)
        }
    }

    static func presentableSurfaces(_ surfaces: [ExtensionSurface]) -> [ExtensionSurface] {
        surfaces
            .filter { $0.kind == .widget && $0.lifecycle != .blocking }
            .filter { !$0.frame.lines.isEmpty }
            .sorted { $0.id < $1.id }
    }

    static func content(
        widgets: [ExtensionWidget]?,
        surfaces: [ExtensionSurface]?,
        statuses: [String: String]? = nil,
        statusOwners: [String: ExtensionOwner]? = nil
    ) -> ExtensionRetainedContent {
        var entries: [ExtensionRetainedContent.Entry] = []
        for widget in widgets ?? [] {
            guard widget.owner?.kind != .subagent else { continue }
            let lines = presentableWidgetLines(widget)
            guard !lines.isEmpty else { continue }
            entries.append(.init(
                id: "widget:\(widget.key)",
                producer: widget.owner?.title ?? ExtensionRetainedContent.unknownProducer,
                style: .text(lines)
            ))
        }
        for surface in presentableSurfaces(surfaces ?? []) {
            guard surface.provenance?.kind != .subagent else { continue }
            entries.append(.init(
                id: "surface:\(surface.id)",
                producer: surfaceProvenanceTitle(surface.provenance?.source),
                style: .frame(surface.frame)
            ))
        }
        for status in presentableStatuses(statuses) {
            guard statusOwners?[status.key]?.kind != .subagent else { continue }
            entries.append(.init(
                id: "status:\(status.key)",
                producer: statusOwners?[status.key]?.title ?? ExtensionRetainedContent.unknownProducer,
                style: .status(status.text)
            ))
        }
        return ExtensionRetainedContent(entries: entries)
    }

    static func surfaceProvenanceTitle(_ source: String?) -> String {
        guard let source else { return ExtensionRetainedContent.unknownProducer }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ExtensionRetainedContent.unknownProducer }
        return trimmed.count <= maximumProvenanceTitleLength
            ? trimmed
            : String(trimmed.prefix(maximumProvenanceTitleLength)) + "…"
    }

    static let maximumProvenanceTitleLength = 64
}

enum UnifiedActivityButtonKind: Equatable {
    case activeSubagents
    case extensionContent
    case recentSubagents

    static func select(
        hasActiveSubagents: Bool,
        hasExtensionContent: Bool,
        hasRecentSubagents: Bool
    ) -> Self? {
        if hasActiveSubagents { return .activeSubagents }
        if hasExtensionContent { return .extensionContent }
        if hasRecentSubagents { return .recentSubagents }
        return nil
    }

    var symbolName: String {
        switch self {
        case .activeSubagents, .recentSubagents: "person.2"
        case .extensionContent: "square.on.square.dashed"
        }
    }
}

struct UnifiedActivityButton: View {
    let kind: UnifiedActivityButtonKind
    let contentCount: Int
    let glassNamespace: Namespace.ID
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if kind == .extensionContent {
                    Image(systemName: kind.symbolName)
                        .font(TronTypography.sans(
                            size: ComposerControlMetrics.symbolSize,
                            weight: .semibold
                        ))
                        .foregroundStyle(Color.tronPrimary)
                        .transition(.opacity)
                } else {
                    ProcessActivityOrb(
                        mode: kind == .activeSubagents ? .solving : .thinking
                    )
                    .transition(.opacity)
                }
            }
            .frame(width: ComposerControlMetrics.hitTarget, height: ComposerControlMetrics.hitTarget)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(),
            in: .circle
        )
        .glassEffectID("chat-unified-activity", in: glassNamespace)
        .glassEffectTransition(.matchedGeometry)
        .transition(.opacity)
        .accessibilityLabel(kind == .extensionContent ? "Extension content" : "Subagents")
        .accessibilityValue(kind == .extensionContent ? "\(contentCount) available" : "Shows current and recently finished subagents")
        .accessibilityHint("Shows activity details")
    }
}
