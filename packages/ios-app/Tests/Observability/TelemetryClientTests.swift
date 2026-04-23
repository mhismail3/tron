import Testing
import Foundation

@testable import TronMobile

@Suite("TelemetryClient")
struct TelemetryClientTests {

    @Test("NullTelemetryClient drops events silently — no state retained")
    func nullClientDropsEvents() {
        let client = NullTelemetryClient()
        client.track(.onboardingStarted)
        client.track(.onboardingStepCompleted(step: "welcome"))
        client.track(.onboardingCompleted)
        // No assertion needed — contract is "no observable side effect."
        // The test pins the API shape so swapping in the real SDK is
        // a one-line change in TelemetryClientFactory.
    }

    @Test("InMemoryTelemetryClient records emitted events when enabled")
    func inMemoryRecordsWhenEnabled() {
        let client = InMemoryTelemetryClient(enabled: true)
        client.track(.onboardingStarted)
        client.track(.pairingCompleted)
        #expect(client.recordedEvents.count == 2)
        if case .onboardingStarted = client.recordedEvents[0] { /* ok */ } else {
            Issue.record("expected onboardingStarted event at index 0")
        }
    }

    @Test("InMemoryTelemetryClient drops events when disabled — opt-in off by default")
    func inMemoryDropsWhenDisabled() {
        let client = InMemoryTelemetryClient(enabled: false)
        client.track(.onboardingStarted)
        client.track(.pairingCompleted)
        #expect(client.recordedEvents.isEmpty)
    }

    @Test("InMemoryTelemetryClient respects rate limiter")
    func inMemoryRespectsRateLimit() {
        var clock = Date(timeIntervalSince1970: 0)
        let bucket = TokenBucket(capacity: 2, refillPerSecond: 0.0, now: { clock })
        let client = InMemoryTelemetryClient(enabled: true, rateLimiter: bucket)
        client.track(.onboardingStarted)
        client.track(.onboardingStarted)
        client.track(.onboardingStarted) // dropped by limiter
        #expect(client.recordedEvents.count == 2)
        _ = clock // keep unused-var warning away
    }

    @Test("TelemetryEvent name is stable — schema pinned")
    func eventNamesAreStable() {
        #expect(TelemetryEvent.onboardingStarted.name == "onboarding_started")
        #expect(TelemetryEvent.onboardingStepCompleted(step: "welcome").name == "onboarding_step_completed")
        #expect(TelemetryEvent.onboardingCompleted.name == "onboarding_completed")
        #expect(TelemetryEvent.pairingCompleted.name == "pairing_completed")
        #expect(TelemetryEvent.providerAuthenticated(provider: "anthropic").name == "provider_authenticated")
        #expect(TelemetryEvent.feedbackSubmitted.name == "feedback_submitted")
        #expect(TelemetryEvent.updateCheckCompleted(current: "1.0", latest: "1.1", action: "notify").name == "update_check_completed")
    }

    @Test("TelemetryEvent properties expose expected metadata")
    func eventPropertiesExposed() {
        let event = TelemetryEvent.onboardingStepCompleted(step: "pairing")
        #expect(event.properties["step"] as? String == "pairing")

        let providerEvent = TelemetryEvent.providerAuthenticated(provider: "openai")
        #expect(providerEvent.properties["provider"] as? String == "openai")
    }
}
