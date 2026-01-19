import SwiftUI

// MARK: - Text

struct CanvasText: View {
    let component: UICanvasComponent

    var body: some View {
        Text(textContent)
            .font(font)
            .fontWeight(fontWeight)
            .foregroundStyle(textColor)
            .lineLimit(component.props.lineLimit)
    }

    private var textContent: String {
        switch component.children {
        case .text(let text): return text
        default: return ""
        }
    }

    private var font: Font {
        switch component.props.style {
        case "largeTitle": return .largeTitle
        case "title": return .title
        case "title2": return .title2
        case "title3": return .title3
        case "headline": return .headline
        case "subheadline": return .subheadline
        case "caption": return .caption
        case "footnote": return .footnote
        default: return .body
        }
    }

    private var fontWeight: Font.Weight? {
        switch component.props.weight {
        case "regular": return .regular
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        default: return nil
        }
    }

    private var textColor: Color {
        parseColor(component.props.color) ?? .primary
    }
}

// MARK: - Icon

struct CanvasIcon: View {
    let component: UICanvasComponent

    var body: some View {
        Image(systemName: component.props.name ?? "questionmark.circle")
            .font(.system(size: component.props.size ?? 24))
            .foregroundStyle(iconColor)
    }

    private var iconColor: Color {
        parseColor(component.props.color) ?? .primary
    }
}

// MARK: - Image

struct CanvasImage: View {
    let component: UICanvasComponent

    var body: some View {
        if let systemName = component.props.systemName {
            Image(systemName: systemName)
                .resizable()
                .aspectRatio(contentMode: contentMode)
                .frame(width: frameWidth, height: frameHeight)
        } else if let base64Data = component.props.data,
                  let data = Data(base64Encoded: base64Data),
                  let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: contentMode)
                .frame(width: frameWidth, height: frameHeight)
        } else {
            Image(systemName: "photo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: frameWidth ?? 100, height: frameHeight ?? 100)
                .foregroundStyle(.secondary)
        }
    }

    private var frameWidth: CGFloat? {
        component.props.width.map { CGFloat($0) }
    }

    private var frameHeight: CGFloat? {
        component.props.height.map { CGFloat($0) }
    }

    private var contentMode: ContentMode {
        component.props.contentMode == "fill" ? .fill : .fit
    }
}

// MARK: - Color Parsing

func parseColor(_ colorString: String?) -> Color? {
    guard let colorString = colorString else { return nil }

    // Semantic colors
    switch colorString.lowercased() {
    case "primary": return .primary
    case "secondary": return .secondary
    case "accent": return .accentColor
    case "destructive", "red": return .red
    case "success", "green": return .green
    case "warning", "orange": return .orange
    case "blue": return .blue
    case "purple": return .purple
    case "pink": return .pink
    case "yellow": return .yellow
    case "gray", "grey": return .gray
    case "white": return .white
    case "black": return .black
    default: break
    }

    // Hex color
    if colorString.hasPrefix("#") {
        return Color(hex: colorString)
    }

    return nil
}
