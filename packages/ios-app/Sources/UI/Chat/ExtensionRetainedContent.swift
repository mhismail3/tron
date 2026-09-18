import SwiftUI

/// Authoritative, disposable projection of extension-provided retained content.
///
/// Retained widgets are deliberately not ambient transcript or composer chrome:
/// a discrete extension *event* belongs in a notification pill, while retained
/// *state* is only visible through the general widgets sheet. Nothing here owns
/// extension execution or presentation authority; it is derived from the
/// current authoritative session snapshot on every render.
struct ExtensionRetainedContent: Equatable {
    enum Style: Equatable {
        /// String widget lines, already sanitized for display.
        case text([String])
        /// A bounded, read-only captured component frame.
        case frame(ExtensionFrame)
        /// One retained keyed status line.
        case status(String)
    }

    struct Entry: Equatable, Identifiable {
        let id: String
        let producer: String
        let style: Style
    }

    let entries: [Entry]

    var isEmpty: Bool { entries.isEmpty }

    /// Deterministic producer order: first appearance wins, and unknown
    /// producers sort last so a stable list never reshuffles on update.
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

enum ExtensionOwnerIdentity {
    static let piSubagentsPackage = "npm:pi-subagents"

    /// Gateway owner-attribution emits npm sources with an optional version.
    /// Normalize only that owned package identity; unknown sources remain
    /// presentable instead of being guessed away by title or content matching.
    static func isPiSubagents(_ source: String?) -> Bool {
        guard let source else { return false }
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == piSubagentsPackage
            || normalized.hasPrefix(piSubagentsPackage + "@")
    }
}

enum ExtensionRetainedContentPolicy {
    /// A string widget is presentable only if it has visible, sanitized content.
    /// Empty or detail-hint-only widgets must not create an empty sheet.
    static func presentableWidgetLines(_ widget: ExtensionWidget) -> [String] {
        widget.lines
            .map(NativeExtensionText.clean)
            .filter { !$0.isEmpty }
    }

    /// Status text is one display line. The Gateway already removed terminal
    /// presentation, so only whitespace is normalized: the widget detail-hint
    /// filter is deliberately not applied here, because it removes a widget-line
    /// artifact rather than a status.
    static func presentableStatusText(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Retained statuses in deterministic key order. Wire dictionaries have no
    /// order, so sorting by key is what keeps the list stable across updates.
    static func presentableStatuses(
        _ statuses: [String: String]?
    ) -> [(key: String, text: String)] {
        (statuses ?? [:]).keys.sorted().compactMap { key in
            let text = presentableStatusText(statuses?[key] ?? "")
            return text.isEmpty ? nil : (key, text)
        }
    }

    /// Only retained, non-blocking widget surfaces are presentable here.
    /// Header/footer/custom/overlay/editor/renderer surfaces have no native
    /// consumer and must never be advertised as shown.
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
            guard !ExtensionOwnerIdentity.isPiSubagents(widget.owner?.source) else { continue }
            let lines = presentableWidgetLines(widget)
            guard !lines.isEmpty else { continue }
            // The authoritative widget array order is stable across updates
            // because the store replaces entries in place by key.
            entries.append(.init(
                id: "widget:\(widget.key)",
                producer: widget.owner?.title ?? ExtensionRetainedContent.unknownProducer,
                style: .text(lines)
            ))
        }
        for surface in presentableSurfaces(surfaces ?? []) {
            guard !ExtensionOwnerIdentity.isPiSubagents(surface.provenance?.source) else { continue }
            entries.append(.init(
                id: "surface:\(surface.id)",
                producer: surfaceProvenanceTitle(surface.provenance?.source),
                style: .frame(surface.frame)
            ))
        }
        // A status outlives its owner's widget (a paused goal clears its widget
        // and keeps only its status), so it is retained content in its own right.
        // The key stays out of the visible card: the section header already names
        // the producer, and the key is an extension-internal slot name.
        for status in presentableStatuses(statuses) {
            guard !ExtensionOwnerIdentity.isPiSubagents(statusOwners?[status.key]?.source) else { continue }
            entries.append(.init(
                id: "status:\(status.key)",
                producer: statusOwners?[status.key]?.title ?? ExtensionRetainedContent.unknownProducer,
                style: .status(status.text)
            ))
        }
        return ExtensionRetainedContent(entries: entries)
    }

    /// Surface provenance carries a resolver source string, never a display
    /// name. Show that exact identity (bounded) instead of guessing a friendlier
    /// label: two packages can share a last path component.
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
            // The glass button keeps its identity; only its glyph crossfades.
            // A symbol content transition cannot animate replacement by Canvas.
            ZStack {
                if kind == .extensionContent {
                    Image(systemName: kind.symbolName)
                        .font(TronTypography.sans(
                            size: ComposerControlMetrics.symbolSize,
                            weight: .semibold
                        ))
                        .foregroundStyle(Color.tronEmerald)
                        .transition(.opacity)
                } else {
                    ProcessActivityOrb(
                        mode: kind == .activeSubagents ? .solving : .thinking,
                        isVisible: true,
                        accent: .tronSubagent
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
        // Liquid Glass owns the composer morph, without a competing scale.
        .transition(.opacity)
        .accessibilityLabel(kind == .extensionContent ? "Extension content" : "Subagents")
        .accessibilityValue(kind == .extensionContent ? "\(contentCount) available" : "Shows current and recently finished subagents")
        .accessibilityHint("Shows activity details")
    }
}
