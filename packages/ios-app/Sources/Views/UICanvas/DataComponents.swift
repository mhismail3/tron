import SwiftUI

// MARK: - List

struct CanvasList: View {
    let component: UICanvasComponent
    let state: UICanvasState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let items = component.props.items {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    listItem(item: item, index: index)
                        .padding(.vertical, 4)

                    if index < items.count - 1 {
                        Divider()
                            .background(Color.tronBorder)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.tronSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.tronBorder, lineWidth: 1)
        )
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
                .font(TronTypography.code)
                .foregroundStyle(.tronTextPrimary)
        default:
            // Fallback: display item value
            HStack {
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
            .font(TronTypography.code)
            .foregroundStyle(.tronTextPrimary)
        }
    }
}

// MARK: - ProgressView

struct CanvasProgressView: View {
    let component: UICanvasComponent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label = component.props.label {
                Text(label)
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
            }

            if let value = component.props.value {
                // Determinate progress
                if component.props.progressStyle == "circular" {
                    ProgressView(value: value, total: 1.0)
                        .progressViewStyle(.circular)
                        .tint(tintColor)
                } else {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // Background track
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.tronSurface)
                                .frame(height: 8)

                            // Progress fill
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(tintColor)
                                .frame(width: geometry.size.width * CGFloat(value), height: 8)
                        }
                    }
                    .frame(height: 8)
                }
            } else {
                // Indeterminate progress
                if component.props.progressStyle == "circular" {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(tintColor)
                } else {
                    ProgressView()
                        .tint(tintColor)
                }
            }
        }
    }

    private var tintColor: Color {
        canvasParseColor(component.props.tint) ?? .tronEmerald
    }
}

// MARK: - Badge

struct CanvasBadge: View {
    let component: UICanvasComponent

    var body: some View {
        Text(component.props.text ?? "")
            .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(badgeColor)
            .foregroundStyle(badgeTextColor)
            .clipShape(Capsule())
    }

    private var badgeColor: Color {
        canvasParseColor(component.props.color) ?? .tronEmerald
    }

    private var badgeTextColor: Color {
        // Use dark text for light badges, white for dark badges
        let colorName = component.props.color?.lowercased() ?? ""
        switch colorName {
        case "warning", "amber", "yellow", "orange":
            return .black
        default:
            return .white
        }
    }
}
