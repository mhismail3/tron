import Testing
@testable import TronMobile

@Suite("Subagent capability event formatter")
struct SubagentCapabilityEventFormatterTests {
    @Test("formats titles from capability identity")
    func formatsCapabilityTitle() {
        let identity = testCapabilityIdentity(contractId: "filesystem::read_file", functionId: "filesystem::read_file")
        #expect(SubagentEventFormatter.formatCapabilityTitle(identity) == "Read File")
    }

    @Test("formats process output compactly")
    func formatsProcessOutput() {
        let identity = testCapabilityIdentity(contractId: "process::run", functionId: "process::run")
        let invocation = testCapabilityInvocation(
            status: .success,
            result: "line 1\nline 2\nline 3\nline 4",
            identity: identity
        )

        #expect(SubagentEventFormatter.formatCapabilityResult(invocation: invocation).contains("+2 more lines"))
    }

    @Test("formats failed capability as truncated error text")
    func formatsFailure() {
        let identity = testCapabilityIdentity(contractId: "web::fetch", functionId: "web::fetch")
        let message = String(repeating: "x", count: 250)
        let invocation = testCapabilityInvocation(status: .error, result: message, identity: identity)

        #expect(SubagentEventFormatter.formatCapabilityResult(invocation: invocation).count == 150)
    }
}
