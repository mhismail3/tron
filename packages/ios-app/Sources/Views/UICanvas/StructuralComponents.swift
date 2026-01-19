import SwiftUI

// MARK: - Section

struct CanvasSection: View {
    let component: UICanvasComponent
    let state: UICanvasState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            if let header = component.props.header {
                Text(header)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tronEmerald)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }

            // Content
            VStack(alignment: .leading, spacing: 12) {
                UIComponentView.renderChildren(component.children, state: state)
            }

            // Footer
            if let footer = component.props.footer {
                Text(footer)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Card

struct CanvasCard: View {
    let component: UICanvasComponent
    let state: UICanvasState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UIComponentView.renderChildren(component.children, state: state)
        }
        .padding(component.props.padding ?? 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(cardOverlay)
    }

    @ViewBuilder
    private var cardBackground: some View {
        switch component.props.cardStyle {
        case "outlined":
            Color.clear
        case "elevated":
            Color.tronSurfaceElevated
        case "glass":
            Color.tronSurface.opacity(0.5)
        default:
            Color.tronSurface
        }
    }

    @ViewBuilder
    private var cardOverlay: some View {
        switch component.props.cardStyle {
        case "outlined":
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.tronBorder, lineWidth: 1)
        case "glass":
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.tronBorder.opacity(0.5), lineWidth: 0.5)
        default:
            EmptyView()
        }
    }
}

// MARK: - Divider (Enhanced)

struct CanvasDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.tronBorder)
            .frame(height: 1)
    }
}
