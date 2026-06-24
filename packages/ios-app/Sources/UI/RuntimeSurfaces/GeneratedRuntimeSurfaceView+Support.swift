import SwiftUI

enum GeneratedUIRendererStatus: Equatable {
    case renderable
    case closedError(String)
    case stale(String)
    case expired
    case damaged(String)
}

struct GeneratedUIRendererState: Equatable {
    var status: GeneratedUIRendererStatus
    var actionsEnabled: Bool
}

enum GeneratedUIRenderer {
    static let schemaVersion: UInt64 = 1
    static let supportedComponents: Set<String> = [
        "Text", "Heading", "Monospace", "Badge", "Section", "List", "Table",
        "Tabs", "Disclosure", "ResourceRef", "InvocationRef", "GrantRef",
        "Metric", "TextField", "TextArea", "Select", "Toggle", "Stepper",
        "DateTime", "Button", "ButtonGroup", "Confirmation", "Progress",
        "Health", "Warning", "Error", "EmptyState"
    ]

    static func validate(
        surface: UiSurfaceDTO,
        resourceRef: UiSurfaceRefDTO? = nil,
        observedVersionId: String? = nil,
        now: Date = Date(),
        isOfflineCached: Bool = false
    ) -> GeneratedUIRendererState {
        guard surface.schemaVersion == schemaVersion else {
            return .init(status: .closedError("Unsupported surface schema"), actionsEnabled: false)
        }
        if let lifecycle = resourceRef?.lifecycle,
           ["damaged", "discarded"].contains(lifecycle) {
            return .init(status: .damaged(lifecycle), actionsEnabled: false)
        }
        if let observedVersionId,
           let versionId = resourceRef?.versionId,
           observedVersionId != versionId {
            return .init(status: .stale(versionId), actionsEnabled: false)
        }
        if isExpired(surface.expiresAt, now: now) {
            return .init(status: .expired, actionsEnabled: false)
        }
        if let unsupported = firstUnsupportedComponent(surface.layout) {
            return .init(status: .closedError("Unsupported UI component: \(unsupported)"), actionsEnabled: false)
        }
        if surface.actions.contains(where: { isExpired($0.expiresAt, now: now) }) {
            return .init(status: .closedError("Surface contains expired action"), actionsEnabled: false)
        }
        return .init(status: .renderable, actionsEnabled: !isOfflineCached)
    }

    static func userInput(from formValues: [String: AnyCodable], for action: UiActionDTO) -> [String: AnyCodable] {
        let allowedKeys = Set(inputPropertyKeys(for: action))
        guard !allowedKeys.isEmpty else { return [:] }
        return formValues.filter { allowedKeys.contains($0.key) }
    }

    static func inputIsSatisfied(_ formValues: [String: AnyCodable], for action: UiActionDTO) -> Bool {
        requiredInputKeys(for: action).allSatisfy { key in
            guard let value = formValues[key], !value.isNull else { return false }
            if let string = value.stringValue {
                return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
    }

    static func requiredInputKeys(for action: UiActionDTO) -> [String] {
        if let required = action.inputSchema.dictionaryValue?["required"] as? [String] {
            return required
        }
        return (action.inputSchema.dictionaryValue?["required"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    static func inputPropertyKeys(for action: UiActionDTO) -> [String] {
        guard let properties = action.inputSchema.dictionaryValue?["properties"] as? [String: Any] else {
            return []
        }
        return properties.keys.sorted()
    }

    private static func firstUnsupportedComponent(_ component: UiComponentDTO) -> String? {
        guard supportedComponents.contains(component.type) else { return component.type }
        for child in component.children ?? [] {
            if let unsupported = firstUnsupportedComponent(child) {
                return unsupported
            }
        }
        return nil
    }

    private static func isExpired(_ value: String, now: Date) -> Bool {
        parseISO8601Date(value).map { $0 <= now } ?? true
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let standard = ISO8601DateFormatter()
        if let date = standard.date(from: value) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}

struct GeneratedUIConfirmation: Identifiable {
    let id = UUID()
    let actionId: String
    let title: String
    let message: String
    let confirmLabel: String
    let buttonRole: GeneratedUIActionButtonRole
}

let generatedUIRowExpansionAnimation = Animation.smooth(duration: 0.22, extraBounce: 0)

enum GeneratedUIActionButtonRole {
    case primary
    case neutral
    case destructive

    init(presentation: UiActionPresentationDTO?) {
        switch presentation?.buttonRole {
        case "primary":
            self = .primary
        case "destructive":
            self = .destructive
        default:
            self = .neutral
        }
    }

    var dialogRole: ButtonRole? {
        switch self {
        case .destructive:
            return .destructive
        case .primary, .neutral:
            return nil
        }
    }
}

struct GeneratedUIActionButtonStyle: ButtonStyle {
    let role: GeneratedUIActionButtonRole
    let isEnabled: Bool
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TronTypography.buttonSM)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, compact ? 14 : 18)
            .padding(.vertical, compact ? 9 : 11)
            .frame(minHeight: compact ? 36 : 44)
            .background(
                RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .opacity(configuration.isPressed && isEnabled ? 0.84 : 1)
    }

    private var foregroundColor: Color {
        guard isEnabled else { return .tronTextDisabled }
        switch role {
        case .primary:
            return .tronBackground
        case .neutral:
            return .tronTextPrimary
        case .destructive:
            return .tronError
        }
    }

    private var backgroundColor: Color {
        guard isEnabled else { return .tronSurfaceElevated.opacity(0.75) }
        switch role {
        case .primary:
            return .tronEmerald
        case .neutral:
            return .tronSurfaceElevated
        case .destructive:
            return .tronError.opacity(0.08)
        }
    }

    private var borderColor: Color {
        guard isEnabled else { return .tronBorder.opacity(0.55) }
        switch role {
        case .primary:
            return .tronEmerald.opacity(0.95)
        case .neutral:
            return .tronBorder.opacity(0.78)
        case .destructive:
            return .tronError.opacity(0.35)
        }
    }
}

extension ButtonStyle where Self == GeneratedUIActionButtonStyle {
    static func generatedUIAction(
        role: GeneratedUIActionButtonRole = .primary,
        isEnabled: Bool,
        compact: Bool = false
    ) -> GeneratedUIActionButtonStyle {
        GeneratedUIActionButtonStyle(role: role, isEnabled: isEnabled, compact: compact)
    }
}

struct GeneratedUIClosedState: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(message)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.tronWarning)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(.tronWarning, cornerRadius: 8, subtle: true, compact: true, interactive: false)
    }
}
