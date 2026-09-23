import SwiftUI

@main
struct TronWatchApp: App {
    @State private var coordinator = WatchRecordingCoordinator()

    var body: some Scene {
        WindowGroup {
            WatchRecordingView(coordinator: coordinator)
                .task { await coordinator.load() }
        }
    }
}

private struct WatchRecordingView: View {
    @Bindable var coordinator: WatchRecordingCoordinator

    var body: some View {
        VStack(spacing: 10) {
            Text("Tron")
                .font(.headline)
            Text(time(coordinator.elapsed))
                .font(.system(.title2, design: .rounded).monospacedDigit())
                .accessibilityLabel("Recording duration \(time(coordinator.elapsed))")
            Text(status).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
            controls
            if !coordinator.recent.isEmpty {
                let saved = WatchRecordingConnectivity.shared.savedRecordingIDs
                ForEach(coordinator.recent.prefix(3)) { recording in
                    Text(saved.contains(recording.recordingId.uuidString.lowercased())
                         ? "\(recording.recordingId.uuidString.prefix(8)): Saved on Mac"
                         : "\(recording.recordingId.uuidString.prefix(8)): Kept on Watch — Mac receipt pending")
                        .font(.caption2).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder private var controls: some View {
        switch coordinator.state {
        case .idle, .failed, .interrupted:
            Button("Record", systemImage: "record.circle") { Task { await coordinator.start() } }
                .tint(.red).disabled(isPreparing)
        case .preparing:
            ProgressView("Preparing microphone")
        case .recording:
            HStack {
                Button("Pause", systemImage: "pause.fill") { Task { await coordinator.pause() } }
                Button("Stop", systemImage: "stop.fill", role: .destructive) { Task { await coordinator.stop() } }
            }
        case .paused:
            HStack {
                Button("Resume", systemImage: "play.fill") { Task { await coordinator.resume() } }
                Button("Stop", systemImage: "stop.fill", role: .destructive) { Task { await coordinator.stop() } }
            }
        case .finalizing:
            ProgressView("Saving recording")
        }
    }

    private var isPreparing: Bool { if case .preparing = coordinator.state { return true }; return false }
    private var status: String {
        switch coordinator.state {
        case .idle: "Ready to record"
        case .preparing: "Checking microphone and storage"
        case .recording: "Recording on this Watch"
        case .paused: "Paused — audio is saved locally"
        case .finalizing: "Saving your recording"
        case let .interrupted(message), let .failed(message): message
        }
    }
    private func time(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
