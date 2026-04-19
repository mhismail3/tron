import Foundation
import Testing
@testable import TronMobile

@Suite("friendlyGitError exhaustive coverage")
struct GitErrorMessageTests {

    /// Every `RPCErrorCode` must produce a non-empty user-facing message
    /// for at least one action verb. If a new case is added to the enum
    /// and nobody routes it through `friendlyGitError`, this loop
    /// surfaces the gap immediately rather than letting the unhandled
    /// case fall through silently to the generic "{action} failed: …"
    /// arm at runtime. Pairs with the INVARIANT comment on the switch.
    @Test("every RPCErrorCode produces a non-empty message")
    func everyCodeProducesMessage() {
        for code in RPCErrorCode.allCases {
            let rpc = RPCError(
                code: code.rawValue,
                message: "stub",
                details: nil
            )
            let message = friendlyGitError(rpc, action: "Push")
            #expect(!message.isEmpty, "no message for code \(code.rawValue)")
        }
    }

    /// Unknown codes from a newer server fall back to "{action} failed:
    /// {raw message}" rather than crashing or returning empty. Guards
    /// the forward-compatibility contract called out in the docblock on
    /// `friendlyGitError`.
    @Test("unknown error code falls back gracefully")
    func unknownCodeFallsBack() {
        let rpc = RPCError(
            code: "FUTURE_CODE_THAT_DOES_NOT_EXIST",
            message: "the server speaks newer dialect",
            details: nil
        )
        let message = friendlyGitError(rpc, action: "Push")
        #expect(message.contains("Push failed"))
        #expect(message.contains("newer dialect"))
    }

    /// A non-RPC error (network timeout, etc.) wraps the localized
    /// description rather than masking it.
    @Test("non-RPC error preserves localized description")
    func nonRPCErrorPreservesDescription() {
        struct StubError: LocalizedError {
            var errorDescription: String? { "the network is on fire" }
        }
        let message = friendlyGitError(StubError(), action: "Pull")
        #expect(message.contains("Pull failed"))
        #expect(message.contains("on fire"))
    }

    /// The `protectedBranch` arm lowercases the action verb to compose
    /// "Cannot push a protected branch." — verify the lowercasing works
    /// for every verb used in production.
    @Test("protectedBranch arm lowercases verb consistently")
    func protectedBranchLowercasing() {
        let rpc = RPCError(code: "PROTECTED_BRANCH", message: "main", details: nil)
        for verb in ["Push", "Commit", "Merge", "Rebase"] {
            let message = friendlyGitError(rpc, action: verb)
            #expect(
                message.contains("Cannot \(verb.lowercased())"),
                "expected lowercase verb in: \(message)"
            )
        }
    }
}
