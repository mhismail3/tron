import AVFoundation
import Combine
import UIKit

/// Monitors audio recording availability and publishes changes.
/// Detects when recording is unavailable (e.g., during phone calls).
@MainActor
class AudioAvailabilityMonitor: ObservableObject {
    static let shared = AudioAvailabilityMonitor()

    @Published private(set) var isRecordingAvailable: Bool = true
    @Published private(set) var unavailabilityReason: String?

    /// Set to true when actively recording to prevent polling from interfering
    var isRecordingInProgress: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var pollingTask: Task<Void, Never>?

    private init() {
        setupNotifications()
        startPolling()
        Task {
            await checkAvailabilityAsync()
        }
    }

    private func setupNotifications() {
        // Listen for audio session interruptions (phone calls, alarms, etc.)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleInterruption(notification)
            }
            .store(in: &cancellables)

        // Listen for route changes (headphones connected/disconnected, etc.)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.checkAvailabilityAsync() }
            }
            .store(in: &cancellables)

        // Listen for media services reset
        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.checkAvailabilityAsync() }
            }
            .store(in: &cancellables)

        // Listen for app becoming active (user might have ended call)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.checkAvailabilityAsync() }
            }
            .store(in: &cancellables)
    }

    /// Poll periodically to detect phone calls and other interruptions
    private func startPolling() {
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.checkAvailabilityAsync()
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            isRecordingAvailable = false
            unavailabilityReason = "Audio interrupted"
        case .ended:
            // Re-check availability after interruption ends
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                await checkAvailabilityAsync()
            }
        @unknown default:
            Task { await checkAvailabilityAsync() }
        }
    }

    /// Actively check if we can record by trying to configure the audio session
    func checkAvailabilityAsync() async {
        // Skip check if recording is in progress to avoid interfering
        if isRecordingInProgress {
            return
        }

        let session = AVAudioSession.sharedInstance()

        // Check record permission first
        switch session.recordPermission {
        case .denied:
            await MainActor.run {
                isRecordingAvailable = false
                unavailabilityReason = "Microphone access denied"
            }
            return
        case .undetermined:
            // Permission not yet requested - allow button but it will request on tap
            await MainActor.run {
                isRecordingAvailable = true
                unavailabilityReason = nil
            }
            return
        case .granted:
            break
        @unknown default:
            break
        }

        // Try to configure the audio session to see if it's actually available
        do {
            // Use a category that allows recording
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            // If we got here, recording is available
            await MainActor.run {
                isRecordingAvailable = true
                unavailabilityReason = nil
            }

            // Deactivate to be a good citizen
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Failed to configure - likely phone call or other exclusive use
            await MainActor.run {
                isRecordingAvailable = false
                unavailabilityReason = "Audio unavailable"
            }
        }
    }

    /// Request microphone permission if not already granted
    func requestPermissionIfNeeded() async -> Bool {
        let session = AVAudioSession.sharedInstance()

        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { granted in
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
}
