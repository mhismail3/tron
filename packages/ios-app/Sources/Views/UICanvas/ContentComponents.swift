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
        case "largeTitle": return TronTypography.mono(size: TronTypography.sizeDisplay, weight: .bold)
        case "title": return TronTypography.mono(size: 26, weight: .semibold)
        case "title2": return TronTypography.mono(size: TronTypography.sizeXXL, weight: .semibold)
        case "title3": return TronTypography.mono(size: TronTypography.sizeLargeTitle, weight: .semibold)
        case "headline": return TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold)
        case "subheadline": return TronTypography.mono(size: TronTypography.sizeBody)
        case "caption": return TronTypography.mono(size: TronTypography.sizeBodySM)
        case "footnote": return TronTypography.mono(size: TronTypography.sizeBody2)
        default: return TronTypography.code
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
        canvasParseColor(component.props.color) ?? .tronTextPrimary
    }
}

// MARK: - Icon

struct CanvasIcon: View {
    let component: UICanvasComponent

    var body: some View {
        Image(systemName: component.props.name ?? "questionmark.circle")
            .font(TronTypography.sans(size: component.props.size ?? 24, weight: .medium))
            .foregroundStyle(iconColor)
    }

    private var iconColor: Color {
        canvasParseColor(component.props.color) ?? .tronEmerald
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
                .foregroundStyle(.tronEmerald)
        } else if let base64Data = component.props.data,
                  let data = Data(base64Encoded: base64Data),
                  let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: contentMode)
                .frame(width: frameWidth, height: frameHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Image(systemName: "photo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: frameWidth ?? 100, height: frameHeight ?? 100)
                .foregroundStyle(.tronTextMuted)
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

/// Parse color strings into SwiftUI colors with Tron theme support
func canvasParseColor(_ colorString: String?) -> Color? {
    guard let colorString = colorString else { return nil }

    // Tron semantic colors (preferred)
    switch colorString.lowercased() {
    case "primary": return .tronTextPrimary
    case "secondary": return .tronTextSecondary
    case "accent", "emerald": return .tronEmerald
    case "muted": return .tronTextMuted

    // Semantic action colors
    case "destructive", "error": return .tronError
    case "success": return .tronSuccess
    case "warning": return .tronWarning
    case "info": return .tronInfo

    // Named colors (mapped to Tron palette)
    case "red": return .tronError
    case "green": return .tronSuccess
    case "orange": return .tronWarning
    case "blue": return .tronInfo
    case "purple": return .tronPurple
    case "cyan": return .tronCyan
    case "amber": return .tronAmber
    case "pink": return Color.pink
    case "yellow": return Color.yellow
    case "gray", "grey": return .tronTextMuted
    case "white": return .tronTextPrimary
    case "black": return .tronBackground

    default: break
    }

    // Hex color
    if colorString.hasPrefix("#") {
        return Color(hex: colorString)
    }

    return nil
}
