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

/// One presentation input for the general extension-content sheet. The
/// presenting route owns where retained content comes from, so the sheet itself
/// holds no read path.
struct ExtensionWidgetsRoute: Equatable {
    var content: ExtensionRetainedContent
    var omittedContentCount: Int = 0

    static let empty = ExtensionWidgetsRoute(content: ExtensionRetainedContent(entries: []))
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

/// Mirrors the process-projection control: one compact, permanently mounted
/// composer owner that appears only while retained extension content exists.
struct ExtensionWidgetsButton: View {
    let content: ExtensionRetainedContent
    let glassNamespace: Namespace.ID
    let reduceMotion: Bool
    let onTap: () -> Void

    var body: some View {
        Group {
            if !content.isEmpty {
                Button(action: onTap) {
                    Image(systemName: "square.on.square.dashed")
                        .font(TronTypography.sans(
                            size: ComposerControlMetrics.symbolSize,
                            weight: .semibold
                        ))
                        .foregroundStyle(Color.tronIndigo)
                        .frame(
                            width: ComposerControlMetrics.hitTarget,
                            height: ComposerControlMetrics.hitTarget
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                // The composer control family shares one glass tint; the symbol
                // carries the extension accent, as the process orb does.
                .glassEffect(
                    .regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(),
                    in: .circle
                )
                .glassEffectID("chat-extension-widgets", in: glassNamespace)
                .glassEffectTransition(.matchedGeometry)
                .transition(.opacity)
                .accessibilityLabel("Extension widgets")
                .accessibilityValue("\(content.entries.count) available")
                .accessibilityHint("Shows content provided by extensions")
            }
        }
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.12)
                : .spring(response: 0.32, dampingFraction: 0.82),
            value: content.isEmpty
        )
    }
}
