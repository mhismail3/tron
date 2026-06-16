import SwiftUI
import PhotosUI

// MARK: - Glass Action Button (Send/Abort)

struct GlassActionButton: View {
    /// Show stop icon (red) when true, send arrow when false.
    let showStop: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onAbort: () -> Void
    let namespace: Namespace.ID
    let buttonSize: CGFloat

    var body: some View {
        Button {
            if showStop {
                onAbort()
            } else {
                onSend()
            }
        } label: {
            Group {
                if showStop {
                    Image(systemName: "stop.fill")
                        .font(TronTypography.button)
                        .foregroundStyle(.red)
                } else {
                    Image(systemName: "arrow.up")
                        .font(TronTypography.button)
                        .foregroundStyle(canSend ? .white : .tronTextDisabled)
                }
            }
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Circle())
        }
        .matchedGeometryEffect(id: "actionButtonMorph", in: namespace)
        .glassEffect(
            .regular.tint(canSend && !showStop ? Color.tronEmerald.opacity(0.65) : Color.tronPhthaloGreen.opacity(0.25)).interactive(),
            in: .circle
        )
        .disabled(!showStop && !canSend)
        .animation(.easeInOut(duration: 0.2), value: showStop)
        .animation(.easeInOut(duration: 0.2), value: canSend)
        .accessibilityLabel(showStop ? "Stop agent" : "Send message")
    }
}

// MARK: - Action Button Dock (Morph Origin)

struct ActionButtonDock: View {
    let namespace: Namespace.ID
    let buttonSize: CGFloat

    var body: some View {
        Circle()
            .fill(Color.clear)
            .frame(width: buttonSize, height: buttonSize)
            .matchedGeometryEffect(id: "actionButtonMorph", in: namespace)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Glass Circle Button Style (iOS 26.1 Menu fix)

/// Custom ButtonStyle that applies glassEffect internally - fixes Menu morphing animation glitch
/// See: https://juniperphoton.substack.com/p/adopting-liquid-glass-experiences
struct GlassCircleButtonStyle: ButtonStyle {
    let size: CGFloat
    let tint: Color
    let isDisabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        // Use explicit Circle as base to ensure correct bounds during Menu transitions
        Circle()
            .fill(.clear)
            .frame(width: size, height: size)
            .overlay {
                configuration.label
            }
            .glassEffect(.regular.tint(tint).interactive(), in: .circle)
            .opacity(isDisabled ? 0.5 : 1.0)
    }
}

// MARK: - Glass Attachment Button

struct GlassAttachmentButton: View {
    let isDisabled: Bool
    let buttonSize: CGFloat
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "plus")
                .font(TronTypography.buttonSM)
                .foregroundStyle(isDisabled ? Color.tronEmerald.opacity(0.3) : Color.tronEmerald)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Circle())
        }
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(), in: .circle)
        .opacity(isDisabled ? 0.5 : 1.0)
        .disabled(isDisabled)
        .accessibilityLabel("Add attachment")
        .accessibilityHint(isDisabled ? "Attachments are unavailable while the agent is active." : "")
    }
}

// MARK: - Attachment Button Dock (Morph Origin)

struct AttachmentButtonDock: View {
    let buttonSize: CGFloat

    var body: some View {
        Circle()
            .fill(Color.clear)
            .frame(width: buttonSize, height: buttonSize)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
