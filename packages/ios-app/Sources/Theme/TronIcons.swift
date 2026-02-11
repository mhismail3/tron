import SwiftUI

// MARK: - Tron Icon System

/// Semantic icon definitions using SF Symbols
enum TronIcon: String, CaseIterable {
    // MARK: - Message Roles
    case user = "person.fill"
    case assistant = "sparkles"
    case system = "gearshape.fill"

    // MARK: - Tool Status
    case toolRunning = "arrow.triangle.2.circlepath"
    case toolSuccess = "checkmark.circle.fill"
    case toolError = "xmark.circle.fill"
    case toolPending = "clock.fill"

    // MARK: - Agent State
    case thinking = "sparkle"
    case streaming = "waveform"
    case ready = "circle.fill"
    case processing = "ellipsis.circle"

    // MARK: - Actions
    case send = "arrow.up.circle.fill"
    case abort = "stop.circle.fill"
    case attach = "paperclip"
    case camera = "camera.fill"
    case photo = "photo.fill"
    case clear = "xmark.circle"

    // MARK: - Navigation
    case settings = "gearshape"
    case session = "bubble.left.and.bubble.right"
    case history = "clock.arrow.circlepath"
    case newSession = "plus.bubble"
    case back = "chevron.left"
    case close = "xmark"

    // MARK: - Connection
    case connected = "wifi"
    case disconnected = "wifi.slash"
    case connecting = "antenna.radiowaves.left.and.right"

    // MARK: - Misc
    case copy = "doc.on.doc"
    case expand = "chevron.down"
    case collapse = "chevron.up"
    case info = "info.circle"
    case warning = "exclamationmark.triangle"
    case error = "exclamationmark.circle"

    // MARK: - Properties

    var systemName: String { rawValue }

    var defaultColor: Color {
        switch self {
        case .user: return .tronMint
        case .assistant: return .tronEmerald
        case .system: return .tronTextSecondary
        case .toolRunning: return .tronInfo
        case .toolSuccess: return .tronSuccess
        case .toolError: return .tronError
        case .toolPending: return .tronTextMuted
        case .thinking: return .tronPrimaryVivid
        case .streaming: return .tronEmerald
        case .ready: return .tronSuccess
        case .processing: return .tronMint
        case .send: return .tronEmerald
        case .abort: return .tronError
        case .attach, .camera, .photo: return .tronTextSecondary
        case .clear: return .tronTextMuted
        case .settings, .session, .history, .newSession, .back, .close:
            return .tronTextSecondary
        case .connected: return .tronSuccess
        case .disconnected: return .tronError
        case .connecting: return .tronWarning
        case .copy: return .tronMint
        case .expand, .collapse: return .tronTextMuted
        case .info: return .tronInfo
        case .warning: return .tronWarning
        case .error: return .tronError
        }
    }
}

// MARK: - Icon View

struct TronIconView: View {
    let icon: TronIcon
    var size: CGFloat = 20
    var color: Color?

    var body: some View {
        Image(systemName: icon.systemName)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(color ?? icon.defaultColor)
    }
}

// MARK: - Animated Icons

struct RotatingIcon: View {
    let icon: TronIcon
    var size: CGFloat = 20
    var color: Color?

    @State private var isRotating = false

    var body: some View {
        TronIconView(icon: icon, size: size, color: color)
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .animation(
                .linear(duration: 1.5).repeatForever(autoreverses: false),
                value: isRotating
            )
            .onAppear { isRotating = true }
    }
}

struct PulsingIcon: View {
    let icon: TronIcon
    var size: CGFloat = 20
    var color: Color?

    @State private var isPulsing = false

    var body: some View {
        TronIconView(icon: icon, size: size, color: color)
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

struct WaveformIcon: View {
    var size: CGFloat = 20
    var color: Color = .tronEmerald

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                PulsingBar(
                    color: color,
                    minHeight: size * 0.15,
                    maxHeight: size * 0.65,
                    width: max(2, size / 7),
                    delay: Double(index) * 0.12
                )
            }
        }
        .frame(width: size, height: size)
    }
}

private struct PulsingBar: View {
    let color: Color
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let width: CGFloat
    let delay: Double

    @State private var expanded = false

    var body: some View {
        Capsule()
            .fill(color)
            .frame(width: width, height: expanded ? maxHeight : minHeight)
            .animation(
                .easeInOut(duration: 0.35)
                    .repeatForever(autoreverses: true)
                    .delay(delay),
                value: expanded
            )
            .onAppear { expanded = true }
    }
}

// MARK: - Connection Status Indicator

struct ConnectionIndicator: View {
    let state: ConnectionState

    var body: some View {
        statusDot
    }

    @ViewBuilder
    private var statusDot: some View {
        switch state {
        case .connected:
            Circle()
                .fill(Color.tronSuccess)
                .frame(width: 8, height: 8)
        case .connecting, .reconnecting:
            Circle()
                .fill(Color.tronWarning)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(Color.tronWarning.opacity(0.5), lineWidth: 2)
                        .scaleEffect(1.5)
                        .opacity(0.5)
                )
        case .disconnected:
            Circle()
                .fill(Color.tronTextMuted)
                .frame(width: 8, height: 8)
        case .failed:
            Circle()
                .fill(Color.tronError)
                .frame(width: 8, height: 8)
        }
    }
}

// MARK: - Thinking Indicator

struct ThinkingIndicator: View {
    @State private var dots = 0
    @State private var timerTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            PulsingIcon(icon: .thinking, size: 16, color: .tronPrimaryVivid)

            Text("Thinking" + String(repeating: ".", count: dots))
                .font(.subheadline)
                .foregroundStyle(Color.tronTextSecondary)
                .frame(width: 100, alignment: .leading)
        }
        .onAppear {
            timerTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    dots = (dots + 1) % 4
                }
            }
        }
        .onDisappear {
            timerTask?.cancel()
        }
    }
}

