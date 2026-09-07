import Testing
@testable import TronMobile

struct GatewayPathDiagnosticCoalescerTests {
    @Test("OS callback bursts admit only one scheduled delivery and keep the latest observation")
    func boundedProducerAdmission() {
        let clock = ManualClock()
        let owner = GatewayPathDiagnosticCoalescer(clock: clock.clock)
        owner.setActive(true)
        #expect(owner.offer("status=first"))
        for index in 1..<1_000 { #expect(!owner.offer("status=\(index)")) }
        clock.advance(by: .milliseconds(250))
        let message = owner.take()
        #expect(message?.contains("status=999 ") == true)
        #expect(message?.contains("coalescedUpdates=1000") == true)
        #expect(message?.contains("callbackDelayMs=250") == true)
        #expect(!owner.offer("status=999"))
    }

    @Test("retired scene values cannot publish or clear a fresh reactivation value")
    func sceneFence() {
        let owner = GatewayPathDiagnosticCoalescer()
        #expect(!owner.offer("status=inactive"))
        owner.setActive(true)
        #expect(owner.offer("status=old"))
        owner.setActive(false)
        #expect(!owner.offer("status=background"))
        owner.setActive(true)
        #expect(!owner.offer("status=fresh")) // the original scheduled callback owns this slot
        #expect(owner.take()?.hasPrefix("status=fresh ") == true)
        owner.setActive(false)
        #expect(!owner.offer("status=changed-while-inactive"))
        owner.setActive(true)
        #expect(owner.offer("status=another"))
        owner.setActive(false)
        #expect(owner.take() == nil)
    }
}
