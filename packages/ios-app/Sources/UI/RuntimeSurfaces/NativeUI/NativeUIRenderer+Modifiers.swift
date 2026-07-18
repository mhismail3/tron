import SwiftUI

/// Ordered modifier interpreter for the precompiled native catalog. Keeping
/// this separate makes the renderer's component and modifier surfaces easier
/// to audit independently.
extension NativeUIRenderer {
    func color(_ value: NativeUIJSONValue?) -> Color {
        if case .object(let channels) = value,
           let red = channels["red"]?.numberValue,
           let green = channels["green"]?.numberValue,
           let blue = channels["blue"]?.numberValue {
            return Color(
                .sRGB,
                red: red,
                green: green,
                blue: blue,
                opacity: channels["alpha"]?.numberValue ?? 1
            )
        }
        return color(value?.stringValue)
    }

    func color(_ token: String?) -> Color {
        switch token {
        case "accent", "emerald": .tronEmerald
        case "purple": .tronPurple
        case "cyan": .cyan
        case "mint": .mint
        case "red", "destructive": .red
        case "success": .tronEmerald
        case "warning": .orange
        case "secondary": .tronTextSecondary
        case "muted": .tronTextMuted
        case "surface": .tronSurface
        case "surfaceElevated": .tronSurfaceElevated
        case "border": .tronBorder
        default: .tronTextPrimary
        }
    }

    func alignment(_ value: String?) -> Alignment {
        switch value {
        case "topLeading": .topLeading
        case "top": .top
        case "topTrailing": .topTrailing
        case "leading": .leading
        case "trailing": .trailing
        case "bottomLeading": .bottomLeading
        case "bottom": .bottom
        case "bottomTrailing": .bottomTrailing
        default: .center
        }
    }

    func horizontalAlignment(_ value: String?) -> HorizontalAlignment {
        value == "trailing" ? .trailing : value == "center" ? .center : .leading
    }

    func verticalAlignment(_ value: String?) -> VerticalAlignment {
        value == "top" ? .top : value == "bottom" ? .bottom : .center
    }

    func applyModifiers(_ raw: NativeUIJSONValue?, to base: AnyView) -> AnyView {
        guard case .array(let values) = raw else { return base }
        var result = base
        for value in values {
            result = applyModifier(value, to: result)
        }
        return result
    }

    private func applyModifier(_ value: NativeUIJSONValue, to current: AnyView) -> AnyView {
        guard case .object(let modifier) = value,
              let name = modifier["name"]?.stringValue
        else { return current }
        switch name {
        case "frame":
            let maxWidth: CGFloat? = modifier["maxWidth"]?.stringValue == "infinity"
                ? .infinity : cgFloat(modifier["maxWidth"])
            let maxHeight: CGFloat? = modifier["maxHeight"]?.stringValue == "infinity"
                ? .infinity : cgFloat(modifier["maxHeight"])
            return AnyView(current.frame(
                minWidth: cgFloat(modifier["minWidth"]),
                maxWidth: maxWidth,
                minHeight: cgFloat(modifier["minHeight"]),
                maxHeight: maxHeight,
                alignment: alignment(modifier["alignment"]?.stringValue)
            ))
        case "padding":
            return AnyView(current.padding(edges(modifier["edges"]), cgFloat(modifier["value"])))
        case "offset":
            return AnyView(current.offset(
                x: modifier["x"]?.numberValue ?? 0,
                y: modifier["y"]?.numberValue ?? 0
            ))
        case "fixedSize":
            return AnyView(current.fixedSize(
                horizontal: modifier["horizontal"]?.boolValue ?? false,
                vertical: modifier["vertical"]?.boolValue ?? false
            ))
        case "aspectRatio":
            return AnyView(current.aspectRatio(
                cgFloat(modifier["value"]),
                contentMode: modifier["contentMode"]?.stringValue == "fill" ? .fill : .fit
            ))
        case "font":
            return AnyView(current.font(TronTypography.sans(
                size: modifier["size"]?.numberValue ?? TronTypography.sizeBody
            )))
        case "fontWeight": return AnyView(current.fontWeight(fontWeight(modifier["value"]?.stringValue)))
        case "fontDesign": return AnyView(current.fontDesign(fontDesign(modifier["value"]?.stringValue)))
        case "foregroundStyle": return AnyView(current.foregroundStyle(color(modifier["value"])))
        case "tint": return AnyView(current.tint(color(modifier["value"])))
        case "opacity": return AnyView(current.opacity(modifier["value"]?.numberValue ?? 1))
        case "background": return AnyView(current.background(color(modifier["value"])))
        case "glassEffect":
            return AnyView(current.glassEffect(
                .regular.tint(color(modifier["tint"]).opacity(0.16)),
                in: RoundedRectangle(cornerRadius: 12)
            ))
        case "clipShape": return AnyView(current.clipShape(RoundedRectangle(cornerRadius: 12)))
        case "cornerRadius":
            return AnyView(current.clipShape(RoundedRectangle(
                cornerRadius: modifier["value"]?.numberValue ?? 0,
                style: .continuous
            )))
        case "shadow":
            return AnyView(current.shadow(
                color: color(modifier["color"]),
                radius: modifier["radius"]?.numberValue ?? 0,
                x: modifier["x"]?.numberValue ?? 0,
                y: modifier["y"]?.numberValue ?? 0
            ))
        case "overlay":
            return AnyView(current.overlay(RoundedRectangle(cornerRadius: 12).stroke(
                color(modifier["color"]),
                lineWidth: modifier["width"]?.numberValue ?? 1
            )))
        case "stroke":
            return AnyView(current.overlay(Rectangle().stroke(
                color(modifier["color"]),
                lineWidth: modifier["width"]?.numberValue ?? 1
            )))
        case "lineLimit": return AnyView(current.lineLimit(Int(modifier["value"]?.numberValue ?? 1)))
        case "multilineTextAlignment":
            return AnyView(current.multilineTextAlignment(textAlignment(modifier["value"]?.stringValue)))
        case "lineSpacing": return AnyView(current.lineSpacing(modifier["value"]?.numberValue ?? 0))
        case "textSelection":
            return modifier["enabled"]?.boolValue == false
                ? AnyView(current.textSelection(.disabled))
                : AnyView(current.textSelection(.enabled))
        case "monospacedDigit": return AnyView(current.monospacedDigit())
        case "disabled": return AnyView(current.disabled(modifier["value"]?.boolValue ?? false))
        case "hidden": return modifier["enabled"]?.boolValue == true ? AnyView(current.hidden()) : current
        case "contentShape": return AnyView(current.contentShape(Rectangle()))
        case "buttonStyle": return AnyView(current.buttonStyle(.plain))
        case "accessibility":
            var result = current
            if let label = modifier["label"]?.stringValue {
                result = AnyView(result.accessibilityLabel(label))
            }
            if let hint = modifier["hint"]?.stringValue {
                result = AnyView(result.accessibilityHint(hint))
            }
            if let identifier = modifier["identifier"]?.stringValue {
                result = AnyView(result.accessibilityIdentifier(identifier))
            }
            return result
        case "transition":
            return AnyView(current.transition(.opacity.combined(with: .scale(scale: 0.98))))
        case "animation":
            return AnyView(current.animation(
                reduceMotion ? nil : .easeInOut(duration: modifier["duration"]?.numberValue ?? 0.2),
                value: controller.tree
            ))
        case "sizeClass":
            let key = horizontalSizeClass == .regular ? "regular" : "compact"
            return applySizeClassOverride(modifier[key]?.objectValue, to: current)
        default: return current
        }
    }

    private func applySizeClassOverride(
        _ override: [String: NativeUIJSONValue]?,
        to current: AnyView
    ) -> AnyView {
        guard let override else { return current }
        var result = current
        if let padding = cgFloat(override["padding"]) {
            result = AnyView(result.padding(padding))
        }
        if let maxWidth = cgFloat(override["maxWidth"]) {
            result = AnyView(result.frame(maxWidth: maxWidth))
        }
        if override["hidden"]?.boolValue == true {
            result = AnyView(result.hidden())
        }
        return result
    }

    private func edges(_ value: NativeUIJSONValue?) -> Edge.Set {
        guard let raw = value?.stringValue else { return .all }
        switch raw {
        case "horizontal": return .horizontal
        case "vertical": return .vertical
        case "top": return .top
        case "bottom": return .bottom
        case "leading": return .leading
        case "trailing": return .trailing
        default: return .all
        }
    }

    private func cgFloat(_ value: NativeUIJSONValue?) -> CGFloat? {
        value.flatMap(\.numberValue).map { CGFloat($0) }
    }

    private func fontWeight(_ value: String?) -> Font.Weight {
        switch value {
        case "bold": .bold
        case "semibold": .semibold
        case "medium": .medium
        case "light": .light
        default: .regular
        }
    }

    private func fontDesign(_ value: String?) -> Font.Design {
        switch value {
        case "monospaced": .monospaced
        case "serif": .serif
        case "rounded": .rounded
        default: .default
        }
    }

    private func textAlignment(_ value: String?) -> TextAlignment {
        value == "center" ? .center : value == "trailing" ? .trailing : .leading
    }
}
