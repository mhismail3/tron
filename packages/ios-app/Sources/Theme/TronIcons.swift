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
    case thinking = "brain"
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

    @State private var animating = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: size / 6, height: size * 0.3)
                    .scaleEffect(y: animating ? 1.0 : 0.3, anchor: .center)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .frame(width: size, height: size)
        .onAppear { animating = true }
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

    var body: some View {
        HStack(spacing: 8) {
            RotatingIcon(icon: .thinking, size: 16, color: .tronPrimaryVivid)

            Text("Thinking" + String(repeating: ".", count: dots))
                .font(.subheadline)
                .foregroundStyle(Color.tronTextSecondary)
                .frame(width: 100, alignment: .leading)
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                dots = (dots + 1) % 4
            }
        }
    }
}

// MARK: - Streaming Cursor

struct StreamingCursor: View {
    @State private var visible = true

    var body: some View {
        Rectangle()
            .fill(Color.tronEmerald)
            .frame(width: 2, height: 18)
            .opacity(visible ? 1 : 0)
            .animation(
                .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                value: visible
            )
            .onAppear { visible = false }
    }
}
