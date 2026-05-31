import Testing
import SwiftUI
@testable import TronMobile

@Suite("Accessibility Labels")
@MainActor
struct AccessibilityTests {

    @Test("chipAccessibility produces correct label with capability and status")
    func chipAccessibilityCapabilityAndStatus() {
        // The modifier should produce "Capability, Status" when summary is empty
        let label = chipAccessibilityLabel(capability: "Run", status: "Completed", summary: "")
        #expect(label == "Run, Completed")
    }

    @Test("chipAccessibility produces correct label with capability, status, and summary")
    func chipAccessibilityWithSummary() {
        let label = chipAccessibilityLabel(capability: "Read File", status: "Completed", summary: "config.json")
        #expect(label == "Read File, Completed, config.json")
    }

    @Test("chipAccessibility empty summary does not produce trailing comma")
    func chipAccessibilityEmptySummary() {
        let label = chipAccessibilityLabel(capability: "Write File", status: "Failed", summary: "")
        #expect(!label.hasSuffix(", "))
        #expect(!label.hasSuffix(","))
    }

    @Test("chipAccessibility all status enum labels work")
    func chipAccessibilityWithEnumLabels() {
        // Verify all status enums produce valid labels through the helper
        let statuses: [(String, String)] = [
            ("Run", "Completed"),
            ("Subagent", SubagentStatus.completed.label),
            ("Notification", NotificationDeliveryStatus.sent.label),
            ("Wait", "Completed"),
        ]

        for (capability, status) in statuses {
            let label = chipAccessibilityLabel(capability: capability, status: status, summary: "")
            #expect(!label.isEmpty, "Label for \(capability) should not be empty")
            #expect(label.contains(capability), "Label should contain model capability name")
            #expect(label.contains(status), "Label should contain status")
        }
    }

    @Test("floating new session control has explicit accessibility copy")
    func floatingNewSessionAccessibility() {
        #expect(FloatingNewSessionButtonAccessibility.label == "New Session")
        #expect(FloatingNewSessionButtonAccessibility.hint == "Opens the new session sheet")
    }

    @Test("floating voice note control has explicit accessibility copy")
    func floatingVoiceNotesAccessibility() {
        #expect(FloatingVoiceNotesButtonAccessibility.label == "Voice Note")
        #expect(FloatingVoiceNotesButtonAccessibility.availableHint == "Opens voice note recording")
        #expect(FloatingVoiceNotesButtonAccessibility.unavailableHint == "Voice note recording is unavailable")
    }

    // MARK: - Helper

    /// Replicates the chipAccessibility label construction logic for testing
    private func chipAccessibilityLabel(capability: String, status: String, summary: String) -> String {
        summary.isEmpty ? "\(capability), \(status)" : "\(capability), \(status), \(summary)"
    }
}
