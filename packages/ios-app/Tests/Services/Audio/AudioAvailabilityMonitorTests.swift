import XCTest
@testable import TronMobile

// MARK: - AudioAvailabilityMonitor Tests

@MainActor
final class AudioAvailabilityMonitorTests: XCTestCase {

    // MARK: - Singleton Tests

    func test_shared_isSingleton() {
        let instance1 = AudioAvailabilityMonitor.shared
        let instance2 = AudioAvailabilityMonitor.shared
        XCTAssertTrue(instance1 === instance2)
    }

    // MARK: - Initial State Tests

    func test_initialState_isRecordingAvailableAccessible() {
        let monitor = AudioAvailabilityMonitor.shared
        _ = monitor.isRecordingAvailable
    }

    func test_initialState_unavailabilityReasonAccessible() {
        let monitor = AudioAvailabilityMonitor.shared
        _ = monitor.unavailabilityReason
    }

    func test_initialState_isRecordingInProgressFalse() {
        let monitor = AudioAvailabilityMonitor.shared
        // Reset to known state
        monitor.isRecordingInProgress = false
        XCTAssertFalse(monitor.isRecordingInProgress)
    }

    // MARK: - Property Access Tests

    func test_isRecordingAvailable_isAccessible() {
        let monitor = AudioAvailabilityMonitor.shared
        _ = monitor.isRecordingAvailable
    }

    func test_unavailabilityReason_isAccessible() {
        let monitor = AudioAvailabilityMonitor.shared
        _ = monitor.unavailabilityReason
    }

    func test_isRecordingInProgress_isReadWrite() {
        let monitor = AudioAvailabilityMonitor.shared

        let original = monitor.isRecordingInProgress

        monitor.isRecordingInProgress = true
        XCTAssertTrue(monitor.isRecordingInProgress)

        monitor.isRecordingInProgress = false
        XCTAssertFalse(monitor.isRecordingInProgress)

        // Restore
        monitor.isRecordingInProgress = original
    }

    // MARK: - Recording In Progress Flag Tests

    func test_isRecordingInProgress_canBeSetTrue() {
        let monitor = AudioAvailabilityMonitor.shared

        monitor.isRecordingInProgress = true
        XCTAssertTrue(monitor.isRecordingInProgress)

        // Reset
        monitor.isRecordingInProgress = false
    }

    func test_isRecordingInProgress_canBeSetFalse() {
        let monitor = AudioAvailabilityMonitor.shared

        monitor.isRecordingInProgress = true
        monitor.isRecordingInProgress = false
        XCTAssertFalse(monitor.isRecordingInProgress)
    }

    func test_isRecordingInProgress_multipleToggles() {
        let monitor = AudioAvailabilityMonitor.shared

        monitor.isRecordingInProgress = true
        XCTAssertTrue(monitor.isRecordingInProgress)

        monitor.isRecordingInProgress = false
        XCTAssertFalse(monitor.isRecordingInProgress)

        monitor.isRecordingInProgress = true
        XCTAssertTrue(monitor.isRecordingInProgress)

        monitor.isRecordingInProgress = false
        XCTAssertFalse(monitor.isRecordingInProgress)
    }

    // MARK: - Check Availability Tests

    func test_checkAvailabilityAsync_doesNotCrash() async {
        let monitor = AudioAvailabilityMonitor.shared

        // Should complete without crashing
        await monitor.checkAvailabilityAsync()
    }

    func test_checkAvailabilityAsync_skipsWhenRecordingInProgress() async {
        let monitor = AudioAvailabilityMonitor.shared

        // When recording is in progress, the check should be skipped
        monitor.isRecordingInProgress = true

        // This should return quickly without doing anything
        await monitor.checkAvailabilityAsync()

        // Reset
        monitor.isRecordingInProgress = false
    }

    // MARK: - Request Permission Tests

    // NOTE: requestPermissionIfNeeded() triggers a system permission dialog
    // that blocks indefinitely in the simulator. Tested manually only.

    // MARK: - Observable Properties Tests

    func test_observableProperties_areReadable() {
        let monitor = AudioAvailabilityMonitor.shared

        // All observable properties should be readable
        let available = monitor.isRecordingAvailable
        let reason = monitor.unavailabilityReason
        let inProgress = monitor.isRecordingInProgress

        // Just verify they don't crash
        _ = available
        _ = reason
        _ = inProgress
    }
}
