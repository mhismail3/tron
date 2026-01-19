import SwiftUI

// MARK: - Section

struct CanvasSection: View {
    let component: UICanvasComponent
    let state: UICanvasState

    var body: some View {
        Section {
            UIComponentView.renderChildren(component.children, state: state)
        } header: {
            if let header = component.props.header {
                Text(header)
            }
        } footer: {
            if let footer = component.props.footer {
                Text(footer)
            }
        }
    }
}

// MARK: - Card

struct CanvasCard: View {
    let component: UICanvasComponent
    let state: UICanvasState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            UIComponentView.renderChildren(component.children, state: state)
        }
        .padding(component.props.padding ?? 16)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(cardOverlay)
    }

    @ViewBuilder
    private var cardBackground: some View {
        if component.props.cardStyle == "outlined" {
            Color.clear
        } else {
            Color(.secondarySystemBackground)
        }
    }

    @ViewBuilder
    private var cardOverlay: some View {
        if component.props.cardStyle == "outlined" {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator), lineWidth: 1)
        }
    }
}
