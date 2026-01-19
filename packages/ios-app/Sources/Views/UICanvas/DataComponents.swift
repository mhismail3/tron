import SwiftUI

// MARK: - List

struct CanvasList: View {
    let component: UICanvasComponent
    let state: UICanvasState

    var body: some View {
        if let items = component.props.items {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                listItem(item: item, index: index)
            }
        }
    }

    @ViewBuilder
    private func listItem(item: AnyCodable, index: Int) -> some View {
        // If there's a template child, render it
        // Otherwise, try to display the item as text
        switch component.children {
        case .components(let templates) where !templates.isEmpty:
            // Use first child as template
            UIComponentView(component: templates[0], state: state)
        case .text(let template):
            Text(template)
        default:
            // Fallback: display item value
            if let stringValue = item.stringValue {
                Text(stringValue)
            } else if let intValue = item.intValue {
                Text("\(intValue)")
            } else if let doubleValue = item.doubleValue {
                Text(String(format: "%.2f", doubleValue))
            } else {
                Text("Item \(index + 1)")
            }
        }
    }
}

// MARK: - ProgressView

struct CanvasProgressView: View {
    let component: UICanvasComponent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label = component.props.label {
                Text(label)
                    .font(.subheadline)
            }

            if let value = component.props.value {
                // Determinate progress
                if component.props.progressStyle == "circular" {
                    ProgressView(value: value, total: 1.0)
                        .progressViewStyle(.circular)
                        .tint(tintColor)
                } else {
                    ProgressView(value: value, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(tintColor)
                }
            } else {
                // Indeterminate progress
                if component.props.progressStyle == "circular" {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(tintColor)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(tintColor)
                }
            }
        }
    }

    private var tintColor: Color? {
        parseColor(component.props.tint)
    }
}

// MARK: - Badge

struct CanvasBadge: View {
    let component: UICanvasComponent

    var body: some View {
        Text(component.props.text ?? "")
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badgeColor)
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    private var badgeColor: Color {
        parseColor(component.props.color) ?? .accentColor
    }
}
