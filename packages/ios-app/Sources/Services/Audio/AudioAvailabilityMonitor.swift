import AVFoundation
import UIKit

/// Monitors audio recording availability and publishes changes.
/// Detects when recording is unavailable (e.g., during phone calls).
@Observable
@MainActor
final class AudioAvailabilityMonitor {
    static let shared = AudioAvailabilityMonitor()

    private(set) var isRecordingAvailable: Bool = true
    private(set) var unavailabilityReason: String?

    /// Set to true when actively recording to prevent polling from interfering
    var isRecordingInProgress: Bool = false

    private var notificationTasks: [Task<Void, Never>] = []
    private var pollingTask: Task<Void, Never>?
    private var isInForeground = true

    private init() {
        setupNotifications()
        startPolling()
        // Do initial check after a short delay to not block init
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            await checkAvailabilityAsync()
        }
    }

    private func setupNotifications() {
        // Listen for audio session interruptions (phone calls, alarms, etc.)
        notificationTasks.append(Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                await self?.handleInterruption(notification)
            }
        })

        // Listen for route changes (headphones connected/disconnected, etc.)
        notificationTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
                // Simple debounce: wait before checking
                try? await Task.sleep(for: .milliseconds(300))
                await self?.checkAvailabilityAsync()
            }
        })

        // Listen for media services reset
        notificationTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVAudioSession.mediaServicesWereResetNotification) {
                await self?.checkAvailabilityAsync()
            }
        })

        // Listen for app becoming active (user might have ended call)
        notificationTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                self?.isInForeground = true
                await self?.checkAvailabilityAsync()
            }
        })

        // Stop polling when app goes to background
        notificationTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
                self?.isInForeground = false
            }
        })
    }

    /// Poll periodically to detect phone calls and other interruptions
    /// Uses 10-second interval since notifications handle most urgent cases (interruptions, route changes)
    private func startPolling() {
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                // Only poll when in foreground
                if self?.isInForeground == true {
                    await self?.checkAvailabilityAsync()
                }
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
            updateAvailability(available: false, reason: "Audio interrupted")
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

    /// Only update @Published properties if values actually changed
    private func updateAvailability(available: Bool, reason: String?) {
        if isRecordingAvailable != available {
            isRecordingAvailable = available
        }
        if unavailabilityReason != reason {
            unavailabilityReason = reason
        }
    }

    /// Actively check if we can record by trying to configure the audio session
    func checkAvailabilityAsync() async {
        // Skip check if recording is in progress to avoid interfering
        if isRecordingInProgress {
            return
        }

        // Check record permission first (this is fast, OK on main thread)
        // Use AVAudioApplication.shared.recordPermission (iOS 17+) to avoid deprecation warning
        let permission = AVAudioApplication.shared.recordPermission
        switch permission {
        case .denied:
            updateAvailability(available: false, reason: "Microphone access denied")
            return
        case .undetermined:
            // Permission not yet requested - allow button but it will request on tap
            updateAvailability(available: true, reason: nil)
            return
        case .granted:
            break
        @unknown default:
            break
        }

        // Check if we can configure the audio session category (without activating it)
        // This verifies recording capability without interrupting other audio playback
        let isAvailable = await Task.detached {
            let session = AVAudioSession.sharedInstance()
            do {
                // Only set the category - do NOT activate the session
                // Activating would interrupt other apps' audio playback
                // Use .allowBluetoothHFP instead of deprecated .allowBluetooth
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
                return true
            } catch {
                return false
            }
        }.value

        if isAvailable {
            updateAvailability(available: true, reason: nil)
        } else {
            updateAvailability(available: false, reason: "Audio unavailable")
        }
    }

    /// Request microphone permission if not already granted
    func requestPermissionIfNeeded() async -> Bool {
        // Use AVAudioApplication.shared for iOS 17+ to avoid deprecation
        let permission = AVAudioApplication.shared.recordPermission

        switch permission {
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
}
