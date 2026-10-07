import Testing
import TronMobileCore
@testable import TronMobile

@MainActor
@Suite("Home designation receipt ownership")
struct HomeDesignationCoordinatorTests {
    @Test("only uncertain transmitted outcomes retain a Home receipt")
    func definitelyUnsentFailureDoesNotRetainReceiptOwnership() {
        let definitelyNotSent = GatewayDefinitelyNotSentError(failure: GatewayFailure(
            code: "disconnected",
            message: "The Home command was not sent.",
            retryable: true,
            details: nil
        ))
        #expect(!HomeDesignationCoordinator.retainsUnresolvedCommand(for: definitelyNotSent))
        #expect(!HomeDesignationCoordinator.retainsUnresolvedCommand(for: definitelyNotSent.failure))

        let uncertain = GatewayFailure(
            code: "outcome_unknown",
            message: "The Home command may have reached the Gateway.",
            retryable: false,
            details: nil
        )
        #expect(HomeDesignationCoordinator.retainsUnresolvedCommand(for: uncertain))

        let refusal = GatewayFailure(
            code: "not_ready",
            message: "Home is not ready.",
            retryable: false,
            details: nil
        )
        #expect(!HomeDesignationCoordinator.retainsUnresolvedCommand(for: refusal))
    }
}
