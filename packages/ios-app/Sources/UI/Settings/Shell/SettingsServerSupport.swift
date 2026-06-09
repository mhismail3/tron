import CoreGraphics

enum PairedServerRowStatusTone: Equatable, Sendable {
    case success
    case warning
    case muted
}

struct PairedServerMenuEntry: Equatable, Identifiable, Sendable {
    let action: PairedServerMenuAction
    let title: String

    var id: PairedServerMenuAction { action }
    var systemImage: String { action.systemImage }
}

struct PairedServerRowPresentation: Equatable, Sendable {
    let status: String?
    let statusTone: PairedServerRowStatusTone
    let menuEntries: [PairedServerMenuEntry]

    static func resolve(
        isSelected: Bool,
        activeServerUnavailable: Bool,
        lastKnownStatus: String?
    ) -> Self {
        let menuEntries = resolvedMenuEntries(
            isSelected: isSelected,
            activeServerUnavailable: activeServerUnavailable
        )

        if isSelected {
            if activeServerUnavailable {
                return Self(status: "Unavailable", statusTone: .warning, menuEntries: menuEntries)
            }
            return Self(status: "Connected", statusTone: .success, menuEntries: menuEntries)
        }

        if let status = cleaned(lastKnownStatus), !status.isEmpty {
            return Self(
                status: status,
                statusTone: status == "Connected" ? .success : .muted,
                menuEntries: menuEntries
            )
        }

        return Self(status: nil, statusTone: .muted, menuEntries: menuEntries)
    }

    private static func resolvedMenuEntries(
        isSelected: Bool,
        activeServerUnavailable: Bool
    ) -> [PairedServerMenuEntry] {
        if isSelected && activeServerUnavailable {
            return [
                PairedServerMenuEntry(action: .reconnect, title: "Retry"),
                PairedServerMenuEntry(action: .forget, title: PairedServerMenuAction.forget.title),
            ]
        }

        return PairedServerMenuAction.allCases.map {
            PairedServerMenuEntry(action: $0, title: $0.title)
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum PairedServerMenuAction: CaseIterable, Hashable, Sendable {
    case reconnect
    case setUp
    case forget

    var title: String {
        switch self {
        case .reconnect:
            return "Reconnect"
        case .setUp:
            return "Set Up"
        case .forget:
            return "Forget"
        }
    }

    var systemImage: String {
        switch self {
        case .reconnect:
            return "arrow.clockwise"
        case .setUp:
            return "gearshape.2"
        case .forget:
            return "trash"
        }
    }

    var isDestructive: Bool {
        self == .forget
    }
}

enum PairedServerMenuLayout {
    static let hitTargetSize: CGFloat = 36
}

