import Testing
@testable import TronMobile

@Suite("Context Revision Mutation Policy")
struct SessionBriefingMutationPolicyTests {
    @Test("Context boundaries cannot be committed during an active agent run")
    func activeRunBlocksMutation() {
        #expect(!ContextControlSheet.SessionBriefingMutationPolicy.canMutate(
            isAgentRunning: true,
            isMutationActive: false
        ))
    }

    @Test("Idle sessions admit one context mutation at a time")
    func idleSessionIsSingleFlight() {
        #expect(ContextControlSheet.SessionBriefingMutationPolicy.canMutate(
            isAgentRunning: false,
            isMutationActive: false
        ))
        #expect(!ContextControlSheet.SessionBriefingMutationPolicy.canMutate(
            isAgentRunning: false,
            isMutationActive: true
        ))
    }
}
