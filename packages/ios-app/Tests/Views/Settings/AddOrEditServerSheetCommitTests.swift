import Testing
@testable import TronMobile

/// Unit tests for the pure-value commit decision used by the
/// AddOrEditServerSheet (Phase 3.6 of the onboarding plan). The View itself
/// owns Keychain side effects and SwiftUI dismiss, but the validation +
/// duplicate-detection + preset-array assembly is delegated to this helper
/// so every classified branch can be covered without UI plumbing.
@Suite("AddOrEditServerSheetCommit")
struct AddOrEditServerSheetCommitTests {

    // MARK: - Fixtures

    private func preset(
        id: String = "preset-id-1",
        label: String = "My Mac",
        host: String = "100.64.0.1",
        port: Int = 9847
    ) -> ConnectionPreset {
        ConnectionPreset(id: id, label: label, host: host, port: port)
    }

    // MARK: - Happy path: add

    @Test("Add succeeds with valid fields and appends to existing list")
    func addAppendsPreset() {
        let existing = [preset()]
        let result = AddOrEditServerSheetCommit.decide(
            mode: .add,
            existingPresets: existing,
            rawLabel: "Second Mac",
            rawHost: "100.64.0.2",
            rawPort: "9847",
            rawToken: "tok-second",
            idGenerator: { "deterministic-id" }
        )
        guard case .success(let outcome) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(outcome.updatedPresets.count == 2)
        #expect(outcome.activePreset.id == "deterministic-id")
        #expect(outcome.activePreset.label == "Second Mac")
        #expect(outcome.activePreset.host == "100.64.0.2")
        #expect(outcome.activePreset.port == 9847)
        #expect(outcome.trimmedToken == "tok-second")
    }

    @Test("Add trims whitespace from label, host, and token before persisting")
    func addTrimsWhitespace() {
        let result = AddOrEditServerSheetCommit.decide(
            mode: .add,
            existingPresets: [],
            rawLabel: "  Padded Label  ",
            rawHost: "  100.64.0.5\n",
            rawPort: " 9847 ",
            rawToken: "  pad-token  ",
            idGenerator: { "id-trim" }
        )
        guard case .success(let outcome) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(outcome.activePreset.label == "Padded Label")
        #expect(outcome.activePreset.host == "100.64.0.5")
        #expect(outcome.activePreset.port == 9847)
        #expect(outcome.trimmedToken == "pad-token")
    }

    // MARK: - Happy path: edit

    @Test("Edit preserves the existing preset id, label, host, and port")
    func editPreservesIdentity() {
        let existing = preset(id: "stable-id-xyz", label: "Original", host: "100.64.0.7", port: 12_000)
        let result = AddOrEditServerSheetCommit.decide(
            mode: .edit(existing),
            existingPresets: [existing],
            // The View locks these inputs in edit mode, but if a malicious
            // caller passed different values we still preserve identity.
            rawLabel: "Should Be Ignored",
            rawHost: "Should Be Ignored",
            rawPort: "9999",
            rawToken: "rotated-token",
            idGenerator: { "this-id-should-not-be-used" }
        )
        guard case .success(let outcome) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(outcome.activePreset == existing)
        #expect(outcome.trimmedToken == "rotated-token")
        // Edit must NOT append a new preset — the list stays untouched.
        #expect(outcome.updatedPresets == [existing])
    }

    // MARK: - Validation failures

    @Test("Empty label is missingFields")
    func emptyLabelRejected() {
        let result = AddOrEditServerSheetCommit.decide(
            mode: .add,
            existingPresets: [],
            rawLabel: "   ",
            rawHost: "100.64.0.1",
            rawPort: "9847",
            rawToken: "tok"
        )
        if case .failure(let err) = result {
            #expect(err == .missingFields)
        } else { Issue.record("expected missingFields") }
    }

    @Test("Empty host is missingFields")
    func emptyHostRejected() {
        let result = AddOrEditServerSheetCommit.decide(
            mode: .add,
            existingPresets: [],
            rawLabel: "label",
            rawHost: "",
            rawPort: "9847",
            rawToken: "tok"
        )
        if case .failure(let err) = result {
            #expect(err == .missingFields)
        } else { Issue.record("expected missingFields") }
    }

    @Test("Empty token is missingFields")
    func emptyTokenRejected() {
        let result = AddOrEditServerSheetCommit.decide(
            mode: .add,
            existingPresets: [],
            rawLabel: "label",
            rawHost: "100.64.0.1",
            rawPort: "9847",
            rawToken: "   "
        )
        if case .failure(let err) = result {
            #expect(err == .missingFields)
        } else { Issue.record("expected missingFields") }
    }

    @Test("Empty port is missingFields (caught BEFORE invalidPort parse)")
    func emptyPortIsMissingNotInvalid() {
        let result = AddOrEditServerSheetCommit.decide(
            mode: .add,
            existingPresets: [],
            rawLabel: "label",
            rawHost: "100.64.0.1",
            rawPort: "",
            rawToken: "tok"
        )
        if case .failure(let err) = result {
            #expect(err == .missingFields,
                    "empty port should classify as missingFields, not invalidPort")
        } else { Issue.record("expected missingFields") }
    }

    @Test("Non-numeric port is invalidPort")
    func nonNumericPortRejected() {
        let result = AddOrEditServerSheetCommit.decide(
            mode: .add,
            existingPresets: [],
            rawLabel: "label",
            rawHost: "100.64.0.1",
            rawPort: "abc",
            rawToken: "tok"
        )
        if case .failure(let err) = result {
            #expect(err == .invalidPort("abc"))
        } else { Issue.record("expected invalidPort") }
    }

    @Test("Out-of-range port is invalidPort")
    func outOfRangePortRejected() {
        let result = AddOrEditServerSheetCommit.decide(
            mode: .add,
            existingPresets: [],
            rawLabel: "label",
            rawHost: "100.64.0.1",
            rawPort: "70000",
            rawToken: "tok"
        )
        if case .failure(let err) = result {
            #expect(err == .invalidPort("70000"))
        } else { Issue.record("expected invalidPort") }
    }

    @Test("Zero port is invalidPort")
    func zeroPortRejected() {
        let result = AddOrEditServerSheetCommit.decide(
            mode: .add,
            existingPresets: [],
            rawLabel: "label",
            rawHost: "100.64.0.1",
            rawPort: "0",
            rawToken: "tok"
        )
        if case .failure(let err) = result {
            #expect(err == .invalidPort("0"))
        } else { Issue.record("expected invalidPort for 0") }
    }

    @Test("Boundary: port=1 succeeds; port=65535 succeeds")
    func portBoundariesAccepted() {
        for port in ["1", "65535"] {
            let result = AddOrEditServerSheetCommit.decide(
                mode: .add,
                existingPresets: [],
                rawLabel: "label",
                rawHost: "100.64.0.1",
                rawPort: port,
                rawToken: "tok",
                idGenerator: { "id-boundary" }
            )
            if case .success(let outcome) = result {
                #expect(outcome.activePreset.port == Int(port)!)
            } else {
                Issue.record("port boundary \(port) was rejected")
            }
        }
    }

    // MARK: - Duplicate detection

    @Test("Add rejects duplicate (host, port) combo")
    func duplicateHostPortRejected() {
        let existing = [preset(host: "100.64.0.1", port: 9847)]
        let result = AddOrEditServerSheetCommit.decide(
            mode: .add,
            existingPresets: existing,
            rawLabel: "Different Label",
            rawHost: "100.64.0.1",
            rawPort: "9847",
            rawToken: "tok"
        )
        if case .failure(.duplicateHostPort(let host, let port)) = result {
            #expect(host == "100.64.0.1")
            #expect(port == 9847)
        } else {
            Issue.record("expected duplicateHostPort, got \(result)")
        }
    }

    @Test("Add allows same host on different port")
    func sameHostDifferentPortAccepted() {
        let existing = [preset(host: "100.64.0.1", port: 9847)]
        let result = AddOrEditServerSheetCommit.decide(
            mode: .add,
            existingPresets: existing,
            rawLabel: "Different Port",
            rawHost: "100.64.0.1",
            rawPort: "9848",
            rawToken: "tok",
            idGenerator: { "id-other-port" }
        )
        if case .success(let outcome) = result {
            #expect(outcome.updatedPresets.count == 2)
        } else {
            Issue.record("expected success — different port should not collide")
        }
    }

    @Test("Edit mode skips the duplicate (host, port) check entirely")
    func editSkipsDuplicateCheck() {
        // The edit flow keeps the same preset, so the (host, port) lookup
        // would always find itself and falsely report a collision. Verify the
        // helper doesn't make that mistake.
        let existing = preset(id: "id-edit", host: "100.64.0.99", port: 9847)
        let result = AddOrEditServerSheetCommit.decide(
            mode: .edit(existing),
            existingPresets: [existing],
            rawLabel: existing.label,
            rawHost: existing.host,
            rawPort: String(existing.port),
            rawToken: "rotated"
        )
        if case .success(let outcome) = result {
            #expect(outcome.activePreset == existing)
        } else {
            Issue.record("edit must not be blocked by self-collision: \(result)")
        }
    }

    // MARK: - Failure messages

    @Test("Failure messages are user-facing and include classified detail")
    func failureMessagesUserFacing() {
        #expect(AddOrEditServerSheetCommit.Failure.missingFields.userFacingMessage
                .contains("Fill in"))
        #expect(AddOrEditServerSheetCommit.Failure.invalidPort("99").userFacingMessage
                .contains("65535"))
        let dup = AddOrEditServerSheetCommit.Failure.duplicateHostPort(host: "h", port: 1)
        #expect(dup.userFacingMessage.contains("h:1"))
        #expect(dup.userFacingMessage.lowercased().contains("re-pair"))
    }

    // MARK: - Mode helpers

    @Test("Mode.isEdit is true only for .edit")
    func modeIsEdit() {
        #expect(AddOrEditServerSheet.Mode.add.isEdit == false)
        #expect(AddOrEditServerSheet.Mode.edit(preset()).isEdit == true)
    }

    @Test("Mode is Equatable so SwiftUI sheet(item:) can compare")
    func modeEquatable() {
        let p = preset()
        #expect(AddOrEditServerSheet.Mode.add == AddOrEditServerSheet.Mode.add)
        #expect(AddOrEditServerSheet.Mode.edit(p) == AddOrEditServerSheet.Mode.edit(p))
        #expect(AddOrEditServerSheet.Mode.add != AddOrEditServerSheet.Mode.edit(p))
    }
}
