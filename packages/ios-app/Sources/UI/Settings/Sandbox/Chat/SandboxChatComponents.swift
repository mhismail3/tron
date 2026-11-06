import SwiftUI

// The chat prototype's components (docs/design-language.md › Components). Each
// takes values and emits intents; the stage owns state.

/// The user's message: a primary-filled bubble at the trailing edge.
struct SandboxUserMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(SandboxDesign.Typeface.body)
            // The canvas colour reads on the primary fill in both appearances.
            .foregroundStyle(Color.tronBackground)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.tronPrimary, in: RoundedRectangle(cornerRadius: SandboxDesign.Radius.bubble, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 48)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(text)")
    }
}

/// The assistant's message: text on the canvas, no container.
struct SandboxAssistantMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(SandboxDesign.Typeface.body)
            .foregroundStyle(Color.tronTextPrimary)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 24)
            .accessibilityLabel("Tron: \(text)")
    }
}

extension SandboxChatModel.Tool.Family {
    var icon: String {
        switch self {
        case .read: "doc.text"
        case .edit: "pencil"
        case .shell: "terminal"
        case .search: "magnifyingglass"
        case .web: "globe"
        }
    }

    var name: String {
        switch self {
        case .read: "Read"
        case .edit: "Edit"
        case .shell: "Shell"
        case .search: "Search"
        case .web: "Web"
        }
    }
}

/// A run of tool calls. Collapsed, one chip names the run; expanded in place,
/// each call is its own chip with its status. The run's height is layout-owned,
/// so expanding reflows the transcript on the geometry spring.
struct SandboxToolRun: View {
    let id: Int
    let tools: [SandboxChatModel.Tool]
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    HStack(spacing: -5) {
                        ForEach(tools.prefix(3)) { tool in
                            Image(systemName: tool.family.icon)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.tronTextSecondary)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.tronSurfaceElevated))
                                .overlay(Circle().stroke(Color.tronBackground, lineWidth: 1.5))
                        }
                    }
                    Text(summary)
                        .font(SandboxDesign.Typeface.rowSecondary)
                        .foregroundStyle(Color.tronTextSecondary)
                        .lineLimit(1)
                    statusGlyph(aggregate)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.tronTextMuted)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.leading, 6)
                .padding(.trailing, 12)
                .frame(minHeight: SandboxDesign.Size.hit)
                .background(Capsule().fill(Color.tronSurfaceElevated.opacity(0.7)))
                .overlay(Capsule().stroke(Color.tronTextPrimary.opacity(0.06), lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(SandboxPressStyle(scale: 0.97))
            .accessibilityLabel("\(tools.count) tools, \(statusText(aggregate))")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Collapses the tool calls" : "Shows each tool call")
            .accessibilityIdentifier("chat-proto-tools-\(id)")
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tools) { tool in
                        row(tool)
                    }
                }
                .padding(.leading, 14)
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summary: String {
        let families = tools.map(\.family.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return "\(tools.count) \(tools.count == 1 ? "tool" : "tools") · \(families.joined(separator: ", "))"
    }

    private var aggregate: SandboxChatModel.Tool.Status {
        if tools.contains(where: { $0.status == .running }) { return .running }
        if tools.contains(where: { $0.status == .failed }) { return .failed }
        return .done
    }

    private func row(_ tool: SandboxChatModel.Tool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: tool.family.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.tronTextSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.label)
                    .font(SandboxDesign.Typeface.rowSecondary.weight(.semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                Text(tool.detail)
                    .font(SandboxDesign.Typeface.rowSecondary)
                    .foregroundStyle(tool.status == .failed ? Color.tronError : Color.tronTextSecondary)
            }
            Spacer(minLength: 8)
            statusGlyph(tool.status)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityValue(statusText(tool.status))
    }

    @ViewBuilder
    private func statusGlyph(_ status: SandboxChatModel.Tool.Status) -> some View {
        switch status {
        case .running: TronPulseLoadingIndicator(accent: .tronPrimary, size: 12)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.tronEmerald)
        case .failed:
            Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.tronError)
        }
    }

    private func statusText(_ status: SandboxChatModel.Tool.Status) -> String {
        switch status {
        case .running: "running"
        case .done: "done"
        case .failed: "one failed"
        }
    }
}

/// The header's context picker: a two-line capsule whose current choice stays
/// visible while its panel is open.
struct SandboxContextPicker: View {
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .center, spacing: 0) {
                    Text(title)
                        .font(SandboxDesign.Typeface.rowPrimary)
                        .foregroundStyle(Color.tronTextPrimary)
                    Text(detail)
                        .font(SandboxDesign.Typeface.rowSecondary)
                        .foregroundStyle(Color.tronTextSecondary)
                }
                .lineLimit(1)
                .contentTransition(.opacity)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.tronTextMuted)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: SandboxDesign.Size.circle)
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(SandboxPressStyle(scale: 0.97))
        .accessibilityLabel("Context: \(title), \(detail)")
        .accessibilityHint("Choose a context")
        .accessibilityIdentifier("chat-proto-context")
    }
}

/// The composer capsule: the draft grows to five lines, then scrolls.
struct SandboxComposerField: View {
    @Binding var draft: String
    var focus: FocusState<Bool>.Binding

    var body: some View {
        TextField("Message Tron", text: $draft, axis: .vertical)
            .font(SandboxDesign.Typeface.body)
            .foregroundStyle(Color.tronTextPrimary)
            .tint(.tronPrimary)
            .lineLimit(1...5)
            .focused(focus)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(minHeight: SandboxDesign.Size.circle)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityIdentifier("chat-proto-composer")
    }
}

/// One status object in two forms: readable feedback, then overlapping badges
/// at the same trailing anchor. Collapsing changes only its form; the events
/// stay until their detail sheet is read.
struct SandboxFeedbackCluster: View {
    let events: [SandboxChatModel.Event]
    let collapsed: Bool
    let action: () -> Void
    /// The latest event's glyph is one element in both forms: it shrinks into
    /// the leading badge while the text fades and the shell narrows toward its
    /// trailing anchor, and grows back out of it.
    @Namespace private var glyphs

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if !collapsed, let latest = events.first {
                    Image(systemName: latest.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(latest.tint)
                        .frame(width: SandboxDesign.Size.badge, height: SandboxDesign.Size.badge)
                        .background(Circle().fill(latest.tint.opacity(0.12)))
                        .matchedGeometryEffect(id: latest.id, in: glyphs)
                    Text(latest.title)
                        .font(SandboxDesign.Typeface.utility)
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(1)
                        .fixedSize()
                        .contentTransition(.opacity)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 6)).animation(.easeOut(duration: 0.18).delay(0.08)),
                                                removal: .opacity.animation(.easeOut(duration: 0.1))))
                } else {
                    HStack(spacing: -7) {
                        ForEach(events.prefix(3)) { event in
                            Image(systemName: event.icon)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(event.tint)
                                .frame(width: SandboxDesign.Size.badge, height: SandboxDesign.Size.badge)
                                .background(Circle().fill(Color.tronSurface))
                                .overlay(Circle().stroke(event.tint.opacity(0.35), lineWidth: 0.75))
                                .matchedGeometryEffect(id: event.id, in: glyphs)
                        }
                    }
                    if events.count > 3 {
                        Text("+\(events.count - 3)")
                            .font(SandboxDesign.Typeface.utility)
                            .monospacedDigit()
                            .foregroundStyle(Color.tronTextSecondary)
                    }
                }
            }
            .padding(.horizontal, collapsed ? 8 : 14)
            .frame(minHeight: 40)
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(SandboxPressStyle(scale: 0.96))
        .accessibilityLabel("\(events.count) recent \(events.count == 1 ? "update" : "updates")")
        .accessibilityValue(events.first?.title ?? "")
        .accessibilityHint("Shows the updates")
        .accessibilityIdentifier("chat-proto-feedback")
    }
}

/// A grouped row: glyph, two lines and a trailing value; the whole row is the target.
struct SandboxGroupedRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    var trailing: String?
    var selected = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SandboxDesign.Typeface.rowPrimary).foregroundStyle(Color.tronTextPrimary)
                Text(detail).font(SandboxDesign.Typeface.rowSecondary).foregroundStyle(Color.tronTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                Text(trailing).font(SandboxDesign.Typeface.utility).foregroundStyle(Color.tronTextMuted).monospacedDigit()
            }
            if selected {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.tronPrimary)
            }
        }
        .padding(.horizontal, SandboxDesign.Space.inset)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
