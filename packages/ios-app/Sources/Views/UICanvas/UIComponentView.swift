import SwiftUI

/// Main router view that renders the appropriate component based on tag
struct UIComponentView: View {
    let component: UICanvasComponent
    let state: UICanvasState

    var body: some View {
        switch component.tag {
        // Layout
        case .vstack:
            CanvasVStack(component: component, state: state)
        case .hstack:
            CanvasHStack(component: component, state: state)
        case .zstack:
            CanvasZStack(component: component, state: state)
        case .scrollView:
            CanvasScrollView(component: component, state: state)
        case .spacer:
            CanvasSpacer(component: component)
        case .divider:
            Divider()

        // Content
        case .text:
            CanvasText(component: component)
        case .icon:
            CanvasIcon(component: component)
        case .image:
            CanvasImage(component: component)

        // Interactive
        case .button:
            CanvasButton(component: component, state: state)
        case .toggle:
            CanvasToggle(component: component, state: state)
        case .slider:
            CanvasSlider(component: component, state: state)
        case .textField:
            CanvasTextField(component: component, state: state)
        case .picker:
            CanvasPicker(component: component, state: state)

        // Data
        case .list:
            CanvasList(component: component, state: state)
        case .progressView:
            CanvasProgressView(component: component)
        case .badge:
            CanvasBadge(component: component)

        // Structural
        case .section:
            CanvasSection(component: component, state: state)
        case .card:
            CanvasCard(component: component, state: state)
        }
    }
}

// MARK: - Children Helper

extension UIComponentView {
    /// Render children components
    @ViewBuilder
    static func renderChildren(_ children: UICanvasChildren, state: UICanvasState) -> some View {
        switch children {
        case .none:
            EmptyView()
        case .text(let text):
            Text(text)
        case .components(let components):
            ForEach(components) { child in
                UIComponentView(component: child, state: state)
            }
        }
    }
}
