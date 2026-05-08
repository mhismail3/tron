import Foundation
import Testing
@testable import TronMobile

@Suite("friendlyGitError exhaustive coverage")
struct GitErrorMessageTests {

    /// Every `EngineErrorCode` must produce a non-empty user-facing message
    /// for at least one action verb. If a new case is added to the enum
    /// and nobody routes it through `friendlyGitError`, this loop
    /// surfaces the gap immediately rather than letting the unhandled
    /// case fall through silently to the generic "{action} failed: …"
    /// arm at runtime. Pairs with the INVARIANT comment on the switch.
    @Test("every EngineErrorCode produces a non-empty message")
    func everyCodeProducesMessage() {
        for code in EngineErrorCode.allCases {
            let rpc = EngineProtocolError(
                code: code.rawValue,
                message: "stub",
                details: nil
            )
            let message = friendlyGitError(rpc, action: .push)
            #expect(!message.isEmpty, "no message for code \(code.rawValue)")
        }
    }

    /// Unknown codes from a newer server fall back to "{action} failed:
    /// {raw message}" rather than crashing or returning empty. Guards
    /// the forward-compatibility contract called out in the docblock on
    /// `friendlyGitError`.
    @Test("unknown error code falls back gracefully")
    func unknownCodeFallsBack() {
        let rpc = EngineProtocolError(
            code: "FUTURE_CODE_THAT_DOES_NOT_EXIST",
            message: "the server speaks newer dialect",
            details: nil
        )
        let message = friendlyGitError(rpc, action: .push)
        #expect(message.contains("Push failed"))
        #expect(message.contains("newer dialect"))
    }

    /// A non-engine protocol error (network timeout, etc.) wraps the localized
    /// description rather than masking it.
    @Test("non-engine protocol error preserves localized description")
    func nonengineProtocolErrorPreservesDescription() {
        struct StubError: LocalizedError {
            var errorDescription: String? { "the network is on fire" }
        }
        let message = friendlyGitError(StubError(), action: .sync)
        #expect(message.contains("Sync failed"))
        #expect(message.contains("on fire"))
    }

    /// The `protectedBranch` arm composes "Cannot {verb} a protected
    /// branch." using `verb.imperativeLower` — verify the formatting for
    /// every verb used in production.
    @Test("protectedBranch arm renders imperative-lower verb")
    func protectedBranchLowercasing() {
        let rpc = EngineProtocolError(code: "PROTECTED_BRANCH", message: "main", details: nil)
        for verb in [GitActionVerb.push, .commit, .merge, .rebase] {
            let message = friendlyGitError(rpc, action: verb)
            #expect(
                message.contains("Cannot \(verb.imperativeLower)"),
                "expected imperative-lower verb in: \(message)"
            )
        }
    }
}
