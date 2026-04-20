import SwiftUI

/// Fork button display state for event rows
enum ForkButtonState: Equatable {
    /// No button shown
    case hidden
    /// Tappable fork button
    case active
}

/// Derives the fork button state for an event in a turn detail context.
///
/// Extracted as a free function for testability. Used by `HistorySheet`
/// and `EventRow` to determine whether each event row should show a fork button.
func deriveForkButtonState(
    event: SessionEvent,
    sessionId: String,
    isInherited: Bool
) -> ForkButtonState {
    if isInherited { return .hidden }
    if event.sessionId != sessionId { return .hidden }
    return event.isForkable ? .active : .hidden
}

// MARK: - Fork Button

/// Reusable fork button with inline confirmation morph.
///
/// Tapping the "Fork" pill expands it in-place into a confirmation strip
/// with "Fork Session" and "Cancel" capsules, then collapses back on
/// cancel or after the fork completes. Used by both `EventRow` and
/// `HistorySheet.mergedToolRow`.
@available(iOS 26.0, *)
struct ForkButton: View {
    let isForking: Bool
    let isDisabled: Bool
    var tint: Color = .tronAmber
    let onFork: () async -> Void

    @State private var isExpanded = false

    var body: some View {
        if isExpanded && !isForking {
            // Expanded confirmation strip
            HStack(spacing: 6) {
                Button {
                    isExpanded = false
                    Task { await onFork() }
                } label: {
                    Text("Fork Session")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(tint.opacity(0.15))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded = false
                    }
                } label: {
                    Text("Cancel")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.tronTextMuted.opacity(0.1))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
        } else {
            // Collapsed fork pill / spinner
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded = true
                }
            } label: {
                if isForking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(tint)
                } else {
                    Text("Fork")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(tint.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(isForking || isDisabled)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
        }
    }
}

// MARK: - Event Row

/// Row display for session events in the history list view
@available(iOS 26.0, *)
struct EventRow: View {
    let event: SessionEvent
    var isHead: Bool = false
    var isMuted: Bool = false
    var forkButtonState: ForkButtonState = .active
    var isForking: Bool = false
    var isForkDisabled: Bool = false
    var forkTint: Color = .tronAmber
    let onFork: () async -> Void

    @State private var isExpanded = false

    /// Whether this event has expandable content to show
    private var hasExpandableContent: Bool {
        event.expandedContent != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row - tappable to expand
            HStack(spacing: 10) {
                // Icon
                eventIcon
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(isMuted ? iconColor.opacity(0.5) : iconColor)
                    .frame(width: 20)

                // Summary + expand indicator
                Text(event.summary)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(isMuted ? .tronTextMuted : .tronTextPrimary)
                    .lineLimit(1)

                // Expand indicator (if has content) - placed next to event name
                if hasExpandableContent {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                }

                Spacer()

                // HEAD badge
                if isHead {
                    Text("HEAD")
                        .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tronPurple)
                        .clipShape(Capsule())
                }

                // Fork button
                if case .active = forkButtonState {
                    ForkButton(
                        isForking: isForking,
                        isDisabled: isForkDisabled,
                        tint: forkTint,
                        onFork: onFork
                    )
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(isHead ? Color.tronPurple.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                if hasExpandableContent {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
            }

            // Expanded content
            if isExpanded, let content = event.expandedContent {
                Text(content)
                    .font(TronTypography.codeContent)
                    .foregroundStyle(isMuted ? .tronTextMuted : .tronTextSecondary)
                    .lineLimit(12)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.tronSurfaceElevated.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
    }

    private var eventIcon: some View {
        EventIconProvider.icon(for: event)
    }

    private var iconColor: Color {
        EventIconProvider.color(for: event.eventType, payload: event.payload)
    }
}
