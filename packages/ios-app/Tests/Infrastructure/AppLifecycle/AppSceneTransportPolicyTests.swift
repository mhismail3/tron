import SwiftUI
import Testing

@testable import TronMobile

@Suite("App scene transport policy")
struct AppSceneTransportPolicyTests {
    @Test("a background launch starts with transport work suspended")
    func backgroundLaunchStartsSuspended() {
        #expect(AppSceneTransportPolicy.shouldStartSuspended(in: .background))
        #expect(!AppSceneTransportPolicy.shouldStartSuspended(in: .inactive))
        #expect(!AppSceneTransportPolicy.shouldStartSuspended(in: .active))
    }

    @Test("only real background suspends the transport")
    func onlyBackgroundSuspends() {
        #expect(
            AppSceneTransportPolicy.transition(from: .active, to: .background)
                == .suspend
        )
        #expect(
            AppSceneTransportPolicy.transition(from: .active, to: .inactive)
                == .none
        )
    }

    @Test("inactive does not release a prior background suspension")
    func inactivePreservesBackgroundSuspension() {
        #expect(
            AppSceneTransportPolicy.transition(from: .background, to: .inactive)
                == .none
        )
        #expect(
            AppSceneTransportPolicy.transition(from: .inactive, to: .active)
                == .resumeAndRecover
        )
    }

    @Test("direct background to active transition also recovers")
    func directForegroundRecovers() {
        #expect(
            AppSceneTransportPolicy.transition(from: .background, to: .active)
                == .resumeAndRecover
        )
    }
}
