import Foundation
import Testing
@testable import TronMobile

/// `PairingStepValidator` is the pure-value classifier for the onboarding
/// PairingStep. It mirrors the validation in `AddOrEditServerSheetCommit`
/// but is purpose-built for onboarding (no preset-list dedupe — onboarding
/// happens before the user has any presets to collide against).
///
/// The classification feeds directly into the inline error label below
/// the form. Each case has an accompanying `userFacingMessage` so the
/// View renders strings without conditional branching.
@Suite("PairingStepValidator")
struct PairingValidationTests {

    // MARK: - Happy path

    @Test("Valid inputs return success with trimmed values")
    func validInputsSucceed() {
        let result = PairingStepValidator.validate(
            host: "100.64.0.1",
            port: "9847",
            token: "abc123",
            label: "My Mac"
        )
        guard case .success(let payload) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(payload.host == "100.64.0.1")
        #expect(payload.port == 9847)
        #expect(payload.token == "abc123")
        #expect(payload.label == "My Mac")
    }

    @Test("Whitespace and newlines trimmed from inputs")
    func trimsAllWhitespace() {
        let result = PairingStepValidator.validate(
            host: "  100.64.0.1\n",
            port: " 9847 ",
            token: "  tok\n",
            label: "  My Mac  "
        )
        guard case .success(let payload) = result else {
            Issue.record("expected success")
            return
        }
        #expect(payload.host == "100.64.0.1")
        #expect(payload.port == 9847)
        #expect(payload.token == "tok")
        #expect(payload.label == "My Mac")
    }

    // MARK: - Validation failures

    @Test("Empty host classified as missingFields")
    func emptyHost() {
        let result = PairingStepValidator.validate(host: "", port: "9847", token: "t", label: "L")
        if case .failure(let err) = result {
            #expect(err == .missingFields)
        } else { Issue.record("expected missingFields") }
    }

    @Test("Empty token classified as missingFields")
    func emptyToken() {
        let result = PairingStepValidator.validate(host: "h", port: "9847", token: "  ", label: "L")
        if case .failure(let err) = result {
            #expect(err == .missingFields)
        } else { Issue.record("expected missingFields") }
    }

    @Test("Empty label classified as missingFields")
    func emptyLabel() {
        let result = PairingStepValidator.validate(host: "h", port: "9847", token: "t", label: "")
        if case .failure(let err) = result {
            #expect(err == .missingFields)
        } else { Issue.record("expected missingFields") }
    }

    @Test("Empty port classified as missingFields (caught BEFORE invalidPort)")
    func emptyPort() {
        let result = PairingStepValidator.validate(host: "h", port: "", token: "t", label: "L")
        if case .failure(let err) = result {
            #expect(err == .missingFields,
                    "empty port must classify as missingFields not invalidPort")
        } else { Issue.record("expected missingFields") }
    }

    @Test("Non-numeric port classified as invalidPort")
    func nonNumericPort() {
        let result = PairingStepValidator.validate(host: "h", port: "abc", token: "t", label: "L")
        if case .failure(let err) = result {
            #expect(err == .invalidPort("abc"))
        } else { Issue.record("expected invalidPort") }
    }

    @Test("Out-of-range port classified as invalidPort")
    func outOfRangePort() {
        let result = PairingStepValidator.validate(host: "h", port: "70000", token: "t", label: "L")
        if case .failure(let err) = result {
            #expect(err == .invalidPort("70000"))
        } else { Issue.record("expected invalidPort") }
    }

    @Test("Boundary: port 1 + port 65535 accepted")
    func portBoundaries() {
        for port in ["1", "65535"] {
            let result = PairingStepValidator.validate(host: "h", port: port, token: "t", label: "L")
            if case .success(let payload) = result {
                #expect(payload.port == Int(port)!)
            } else {
                Issue.record("port boundary \(port) rejected")
            }
        }
    }

    // MARK: - User-facing messages

    @Test("Error messages are user-facing and classify the failure")
    func errorMessages() {
        let missing = PairingStepValidator.Failure.missingFields.userFacingMessage
        #expect(missing.lowercased().contains("fill"))

        let invalid = PairingStepValidator.Failure.invalidPort("99").userFacingMessage
        #expect(invalid.contains("65535"))

        let unreachable = PairingStepValidator.Failure.unreachable("100.64.0.1").userFacingMessage
        #expect(unreachable.lowercased().contains("can"))

        let unauthorized = PairingStepValidator.Failure.unauthorized.userFacingMessage
        #expect(unauthorized.lowercased().contains("token"))

        let incompatible = PairingStepValidator.Failure.incompatibleServer("0.5.0").userFacingMessage
        #expect(incompatible.contains("0.5.0"))
    }

    // MARK: - Failure classification helper

    @Test("Classify NSURLErrorCannotConnectToHost as .unreachable")
    func classifyNetworkError() {
        let err = NSError(domain: NSURLErrorDomain, code: -1004, userInfo: nil)
        let classified = PairingStepValidator.classify(error: err, hostHint: "100.64.0.1")
        #expect(classified == .unreachable("100.64.0.1"))
    }

    @Test("Classify NSURLErrorTimedOut as .unreachable")
    func classifyTimeout() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        let classified = PairingStepValidator.classify(error: err, hostHint: "h")
        #expect(classified == .unreachable("h"))
    }

    @Test("Classify a thrown WebSocketError.unauthorized as .unauthorized")
    func classifyUnauthorized() {
        let err = PairingStepConnectError.unauthorized
        let classified = PairingStepValidator.classify(error: err, hostHint: "h")
        #expect(classified == .unauthorized)
    }

    @Test("Classify a thrown PairingStepConnectError.incompatible as .incompatibleServer")
    func classifyIncompatible() {
        let err = PairingStepConnectError.incompatible(serverVersion: "0.4.9")
        let classified = PairingStepValidator.classify(error: err, hostHint: "h")
        #expect(classified == .incompatibleServer("0.4.9"))
    }

    @Test("Unknown errors fall through to .unreachable (defensive)")
    func classifyUnknown() {
        struct Garbage: Error {}
        let classified = PairingStepValidator.classify(error: Garbage(), hostHint: "h")
        // Defensive: an unclassified error still reads as a connect failure
        // to the user. This keeps the inline error never blank.
        if case .unreachable = classified { /* ok */ } else {
            Issue.record("unknown error should fall back to unreachable: got \(classified)")
        }
    }
}
