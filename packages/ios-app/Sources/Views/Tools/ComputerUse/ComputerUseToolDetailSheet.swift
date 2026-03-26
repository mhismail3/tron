import SwiftUI

// MARK: - ComputerUse Tool Detail Sheet (iOS 26 Liquid Glass)

/// Dedicated detail sheet for ComputerUse tool results.
/// Shows the action type, coordinates/keys/text, execution status,
/// and result with action-specific detail sections.
@available(iOS 26.0, *)
struct ComputerUseToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: .purple, colorScheme: colorScheme)
    }

    // MARK: - Argument Extraction

    private var action: String {
        ToolArgumentParser.action(from: data.arguments)
    }

    private var actionFromDetails: String? {
        ComputerUseDetailsHelper.action(from: data.details)
    }

    private var resolvedAction: String {
        let a = action
        return a.isEmpty ? (actionFromDetails ?? "") : a
    }

    // Coordinates (from args or details)
    private var xCoord: Double? {
        if let v = ToolArgumentParser.string("x", from: data.arguments), let d = Double(v) { return d }
        return ComputerUseDetailsHelper.x(from: data.details)
    }

    private var yCoord: Double? {
        if let v = ToolArgumentParser.string("y", from: data.arguments), let d = Double(v) { return d }
        return ComputerUseDetailsHelper.y(from: data.details)
    }

    // Click details
    private var clickCount: Int {
        ToolArgumentParser.integer("clicks", from: data.arguments)
            ?? ComputerUseDetailsHelper.clicks(from: data.details)
            ?? 1
    }

    // Type details
    private var typedText: String? {
        ToolArgumentParser.string("text", from: data.arguments)
    }

    private var typedLength: Int? {
        ComputerUseDetailsHelper.textLength(from: data.details)
    }

    // Keypress details
    private var keysArray: [String]? {
        ToolArgumentParser.stringArray("keys", from: data.arguments)
            ?? ComputerUseDetailsHelper.keys(from: data.details)
    }

    // Scroll details
    private var scrollDirection: String? {
        ToolArgumentParser.string("direction", from: data.arguments)
            ?? ComputerUseDetailsHelper.direction(from: data.details)
    }

    private var scrollAmount: Int? {
        ToolArgumentParser.integer("amount", from: data.arguments)
            ?? ComputerUseDetailsHelper.amount(from: data.details)
    }

    // Window details
    private var windowTitle: String? {
        ToolArgumentParser.string("window", from: data.arguments)
            ?? ComputerUseDetailsHelper.window(from: data.details)
    }

    // Screenshot details
    private var screenshotSize: Int? {
        ComputerUseDetailsHelper.sizeBytes(from: data.details)
    }

    private var isFallback: Bool {
        ComputerUseDetailsHelper.isFallback(from: data.details)
    }

    // MARK: - Body

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "Computer Use",
            iconName: "desktopcomputer",
            accent: .purple,
            copyContent: data.result ?? ""
        ) {
            contentBody
        }
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 16) {
                actionSection
                    .padding(.horizontal)
                statusRow
                    .padding(.horizontal)

                switch data.status {
                case .success:
                    if let result = data.result, !result.isEmpty {
                        resultSection(result)
                            .padding(.horizontal)
                    }
                case .error:
                    if let result = data.result, !result.isEmpty {
                        errorSection(result)
                            .padding(.horizontal)
                    }
                case .running:
                    ToolRunningSpinner(
                        title: "Executing",
                        accent: .purple,
                        tint: tint,
                        actionText: runningActionText
                    )
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Action Section

    private var actionSection: some View {
        ToolDetailSection(title: "Action", accent: .purple, tint: tint) {
            VStack(alignment: .leading, spacing: 10) {
                // Action label
                HStack(spacing: 8) {
                    Image(systemName: actionIcon)
                        .font(TronTypography.sans(size: TronTypography.sizeTitle))
                        .foregroundStyle(.purple)

                    Text(actionDisplayName)
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(tint.body)
                }

                // Action-specific details
                actionDetails
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var actionDetails: some View {
        switch resolvedAction {
        case "click":
            if let x = xCoord, let y = yCoord {
                detailRow(icon: "scope", label: "Position", value: ComputerUseDetailsHelper.formatCoordinates(x: x, y: y))
            }
            if clickCount > 1 {
                detailRow(icon: "hand.tap", label: "Clicks", value: "\(clickCount) (double-click)")
            }

        case "type":
            if let text = typedText {
                let preview = text.count > 60 ? String(text.prefix(57)) + "..." : text
                detailRow(icon: "character.cursor.ibeam", label: "Text", value: "\"\(preview)\"")
            }
            if let len = typedLength {
                detailRow(icon: "textformat.123", label: "Length", value: "\(len) characters")
            }

        case "keypress":
            if let keys = keysArray {
                detailRow(icon: "keyboard", label: "Keys", value: ComputerUseDetailsHelper.formatKeys(keys))
            }

        case "scroll":
            if let dir = scrollDirection {
                let dirIcon = scrollDirectionIcon(dir)
                detailRow(icon: dirIcon, label: "Direction", value: dir.capitalized)
            }
            if let amt = scrollAmount {
                detailRow(icon: "ruler", label: "Amount", value: "\(amt)px")
            }
            if isFallback {
                detailRow(icon: "arrow.triangle.2.circlepath", label: "Method", value: "Keyboard fallback")
            }

        case "screenshot":
            if let window = windowTitle {
                detailRow(icon: "macwindow", label: "Window", value: window)
            } else {
                detailRow(icon: "display", label: "Capture", value: "Full screen")
            }
            if let size = screenshotSize {
                detailRow(icon: "doc.zipper", label: "Size", value: formatBytes(size))
            }

        case "getWindows":
            detailRow(icon: "rectangle.3.group", label: "Scope", value: "All visible windows")

        case "focusWindow":
            if let window = windowTitle {
                detailRow(icon: "macwindow", label: "Window", value: window)
            }

        case "moveMouse":
            if let x = xCoord, let y = yCoord {
                detailRow(icon: "scope", label: "Target", value: ComputerUseDetailsHelper.formatCoordinates(x: x, y: y))
            }

        default:
            EmptyView()
        }
    }

    private func detailRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody2))
                .foregroundStyle(tint.subtle)
                .frame(width: 16)
            Text(label)
                .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                .foregroundStyle(tint.secondary)
            Spacer()
            Text(value)
                .font(TronTypography.mono(size: TronTypography.sizeBody3))
                .foregroundStyle(tint.body)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        ToolStatusRow(status: data.status, durationMs: data.durationMs) {
            // Action type pill
            if !resolvedAction.isEmpty {
                ToolInfoPill(
                    icon: actionIcon,
                    label: actionDisplayName,
                    color: actionPillColor
                )
            }
            // Mutating action warning
            if ComputerUseDetailsHelper.isMutating(resolvedAction) {
                ToolInfoPill(icon: "hand.raised", label: "Mutating", color: .tronAmber)
            }
            if isFallback {
                ToolInfoPill(icon: "arrow.triangle.2.circlepath", label: "Fallback", color: .tronAmber)
            }
        }
    }

    // MARK: - Result Section

    private func resultSection(_ result: String) -> some View {
        ToolDetailSection(
            title: "Result",
            accent: .purple,
            tint: tint,
            trailing: ToolCopyButton(content: result, accent: .purple)
        ) {
            Text(result)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(tint.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Error Section

    private func errorSection(_ result: String) -> some View {
        ToolDetailSection(title: "Error", accent: .tronError, tint: tint) {
            Text(result)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronError)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Computed Helpers

    private var actionIcon: String {
        switch resolvedAction {
        case "screenshot": return "camera.viewfinder"
        case "click": return "hand.point.up.left"
        case "type": return "character.cursor.ibeam"
        case "keypress": return "keyboard"
        case "scroll": return "scroll"
        case "getWindows": return "rectangle.3.group"
        case "focusWindow": return "macwindow"
        case "moveMouse": return "cursorarrow.motionlines"
        default: return "desktopcomputer"
        }
    }

    private var actionDisplayName: String {
        switch resolvedAction {
        case "screenshot": return "Screenshot"
        case "click": return clickCount > 1 ? "Double Click" : "Click"
        case "type": return "Type"
        case "keypress": return "Keypress"
        case "scroll": return "Scroll"
        case "getWindows": return "List Windows"
        case "focusWindow": return "Focus Window"
        case "moveMouse": return "Move Mouse"
        default: return resolvedAction.capitalized
        }
    }

    private var actionPillColor: Color {
        switch resolvedAction {
        case "screenshot", "getWindows": return .tronInfo
        case "click", "type", "keypress": return .purple
        case "scroll", "moveMouse": return .teal
        case "focusWindow": return .cyan
        default: return .tronSlate
        }
    }

    private var runningActionText: String {
        switch resolvedAction {
        case "screenshot": return "Capturing screenshot..."
        case "click": return "Clicking..."
        case "type": return "Typing text..."
        case "keypress": return "Pressing keys..."
        case "scroll": return "Scrolling..."
        case "getWindows": return "Listing windows..."
        case "focusWindow": return "Focusing window..."
        case "moveMouse": return "Moving mouse..."
        default: return "Executing..."
        }
    }

    private func scrollDirectionIcon(_ direction: String) -> String {
        switch direction {
        case "up": return "arrow.up"
        case "down": return "arrow.down"
        case "left": return "arrow.left"
        case "right": return "arrow.right"
        default: return "arrow.down"
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        } else if bytes >= 1024 {
            return String(format: "%.0f KB", Double(bytes) / 1024.0)
        }
        return "\(bytes) B"
    }
}

// MARK: - Previews

#if DEBUG
@available(iOS 26.0, *)
#Preview("ComputerUse - Click") {
    ComputerUseToolDetailSheet(
        data: CommandToolChipData(
            id: "call_cu1",
            toolName: "ComputerUse",
            normalizedName: "computeruse",
            icon: "desktopcomputer",
            iconColor: .purple,
            displayName: "Computer Use",
            summary: "click (960, 540)",
            status: .success,
            durationMs: 150,
            arguments: "{\"action\": \"click\", \"x\": 960, \"y\": 540}",
            result: "Clicked at (960, 540)",
            isResultTruncated: false,
            details: ["action": AnyCodable("click"), "x": AnyCodable(960), "y": AnyCodable(540), "clicks": AnyCodable(1)]
        )
    )
}

@available(iOS 26.0, *)
#Preview("ComputerUse - Type") {
    ComputerUseToolDetailSheet(
        data: CommandToolChipData(
            id: "call_cu2",
            toolName: "ComputerUse",
            normalizedName: "computeruse",
            icon: "desktopcomputer",
            iconColor: .purple,
            displayName: "Computer Use",
            summary: "type: \"hello world\"",
            status: .success,
            durationMs: 80,
            arguments: "{\"action\": \"type\", \"text\": \"hello world\"}",
            result: "Typed 11 characters",
            isResultTruncated: false,
            details: ["action": AnyCodable("type"), "length": AnyCodable(11)]
        )
    )
}

@available(iOS 26.0, *)
#Preview("ComputerUse - Keypress") {
    ComputerUseToolDetailSheet(
        data: CommandToolChipData(
            id: "call_cu3",
            toolName: "ComputerUse",
            normalizedName: "computeruse",
            icon: "desktopcomputer",
            iconColor: .purple,
            displayName: "Computer Use",
            summary: "Cmd+C",
            status: .success,
            durationMs: 50,
            arguments: "{\"action\": \"keypress\", \"keys\": [\"cmd\", \"c\"]}",
            result: "Pressed: cmd+c",
            isResultTruncated: false,
            details: ["action": AnyCodable("keypress"), "keys": AnyCodable(["cmd", "c"])]
        )
    )
}

@available(iOS 26.0, *)
#Preview("ComputerUse - Screenshot") {
    ComputerUseToolDetailSheet(
        data: CommandToolChipData(
            id: "call_cu4",
            toolName: "ComputerUse",
            normalizedName: "computeruse",
            icon: "desktopcomputer",
            iconColor: .purple,
            displayName: "Computer Use",
            summary: "screenshot",
            status: .success,
            durationMs: 500,
            arguments: "{\"action\": \"screenshot\"}",
            result: "Screenshot captured (2048576 bytes)",
            isResultTruncated: false,
            details: ["action": AnyCodable("screenshot"), "sizeBytes": AnyCodable(2048576)]
        )
    )
}

@available(iOS 26.0, *)
#Preview("ComputerUse - Scroll") {
    ComputerUseToolDetailSheet(
        data: CommandToolChipData(
            id: "call_cu5",
            toolName: "ComputerUse",
            normalizedName: "computeruse",
            icon: "desktopcomputer",
            iconColor: .purple,
            displayName: "Computer Use",
            summary: "scroll down",
            status: .success,
            durationMs: 100,
            arguments: "{\"action\": \"scroll\", \"direction\": \"down\", \"amount\": 200}",
            result: "Scrolled down by 200px at (0, 0)",
            isResultTruncated: false,
            details: ["action": AnyCodable("scroll"), "direction": AnyCodable("down"), "amount": AnyCodable(200)]
        )
    )
}

@available(iOS 26.0, *)
#Preview("ComputerUse - Error") {
    ComputerUseToolDetailSheet(
        data: CommandToolChipData(
            id: "call_cu6",
            toolName: "ComputerUse",
            normalizedName: "computeruse",
            icon: "desktopcomputer",
            iconColor: .purple,
            displayName: "Computer Use",
            summary: "click (100, 200)",
            status: .error,
            durationMs: 30,
            arguments: "{\"action\": \"click\", \"x\": 100, \"y\": 200}",
            result: "Action 'click' requires confirmation. Call GetConfirmation first.",
            isResultTruncated: false
        )
    )
}

@available(iOS 26.0, *)
#Preview("ComputerUse - Running") {
    ComputerUseToolDetailSheet(
        data: CommandToolChipData(
            id: "call_cu7",
            toolName: "ComputerUse",
            normalizedName: "computeruse",
            icon: "desktopcomputer",
            iconColor: .purple,
            displayName: "Computer Use",
            summary: "screenshot",
            status: .running,
            durationMs: nil,
            arguments: "{\"action\": \"screenshot\"}",
            result: nil,
            isResultTruncated: false
        )
    )
}
#endif
