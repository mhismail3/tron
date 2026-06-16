import AVFoundation
import UIKit

@Observable
@MainActor
final class MicAvailabilityMonitor {
    static let shared = MicAvailabilityMonitor()

    private(set) var isRecordingAvailable = true
    private(set) var unavailabilityReason: String?
    var isRecordingInProgress = false

    private var notificationTasks: [Task<Void, Never>] = []

    private init() {
        notificationTasks.append(Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                self?.handleInterruption(notification)
            }
        })
        notificationTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
                try? await Task.sleep(for: .milliseconds(300))
                await self?.checkAvailabilityAsync()
            }
        })
    }

    func checkAvailabilityAsync() async {
        guard !isRecordingInProgress else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            updateAvailability(available: false, reason: "Microphone access denied")
        case .undetermined, .granted:
            updateAvailability(available: true, reason: nil)
        @unknown default:
            updateAvailability(available: false, reason: "Microphone unavailable")
        }
    }

    func requestPermissionIfNeeded() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        await self.checkAvailabilityAsync()
                    }
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        switch type {
        case .began:
            updateAvailability(available: false, reason: "Audio interrupted")
        case .ended:
            Task { await checkAvailabilityAsync() }
        @unknown default:
            Task { await checkAvailabilityAsync() }
        }
    }

    private func updateAvailability(available: Bool, reason: String?) {
        isRecordingAvailable = available
        unavailabilityReason = reason
    }
}
