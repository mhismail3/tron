import SwiftUI

// MARK: - VStack

struct CanvasVStack: View {
    let component: UICanvasComponent
    let state: UICanvasState

    var body: some View {
        let spacing = component.props.spacing ?? 8

        VStack(alignment: alignment, spacing: spacing) {
            UIComponentView.renderChildren(component.children, state: state)
        }
    }

    private var alignment: HorizontalAlignment {
        switch component.props.alignment {
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .center
        }
    }
}

// MARK: - HStack

struct CanvasHStack: View {
    let component: UICanvasComponent
    let state: UICanvasState

    var body: some View {
        let spacing = component.props.spacing ?? 8

        HStack(alignment: alignment, spacing: spacing) {
            UIComponentView.renderChildren(component.children, state: state)
        }
    }

    private var alignment: VerticalAlignment {
        switch component.props.alignment {
        case "top": return .top
        case "bottom": return .bottom
        default: return .center
        }
    }
}

// MARK: - ZStack

struct CanvasZStack: View {
    let component: UICanvasComponent
    let state: UICanvasState

    var body: some View {
        ZStack(alignment: alignment) {
            UIComponentView.renderChildren(component.children, state: state)
        }
    }

    private var alignment: Alignment {
        switch component.props.alignment {
        case "top": return .top
        case "bottom": return .bottom
        case "leading": return .leading
        case "trailing": return .trailing
        case "topLeading": return .topLeading
        case "topTrailing": return .topTrailing
        case "bottomLeading": return .bottomLeading
        case "bottomTrailing": return .bottomTrailing
        default: return .center
        }
    }
}

// MARK: - ScrollView

struct CanvasScrollView: View {
    let component: UICanvasComponent
    let state: UICanvasState

    var body: some View {
        ScrollView(axes) {
            if axes == .horizontal {
                HStack(spacing: 8) {
                    UIComponentView.renderChildren(component.children, state: state)
                }
            } else {
                VStack(spacing: 8) {
                    UIComponentView.renderChildren(component.children, state: state)
                }
            }
        }
    }

    private var axes: Axis.Set {
        switch component.props.axis {
        case "horizontal": return .horizontal
        case "both": return [.horizontal, .vertical]
        default: return .vertical
        }
    }
}

// MARK: - Spacer

struct CanvasSpacer: View {
    let component: UICanvasComponent

    var body: some View {
        if let minLength = component.props.minLength {
            Spacer(minLength: minLength)
        } else {
            Spacer()
        }
    }
}
