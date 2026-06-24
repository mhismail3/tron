import Foundation
import SwiftUI
import Testing
@testable import TronMobile

/// `Binding<String>.pasteAware(onPairingPayload:)` is the universal-paste
/// helper used by the onboarding `PairingStep`.
///
/// **Why these tests**: the helper is intercepting EVERY keystroke into
/// the field — a regression that caused legitimate text input to be
/// dropped (or worse, routed to the pairing callback) would break the
/// pairing form silently. We pin behavior on:
///   - `tron://pair?…` URLs route to the callback AND do NOT write to
///     the underlying binding (so the literal URL never flashes on screen
///     before the auto-distribute).
///   - Any other text falls through to the binding unchanged.
///   - Malformed `tron://pair` strings (missing required fields, bad port)
///     fall through too — partial typing must not silently disappear and
///     must not call back with a half-built payload.
///   - Calls to `set` are forwarded synchronously (no Task hops needed).
///
/// All work happens on the main actor since `Binding` write closures
/// run on the actor that owns the @State / @Bindable storage; SwiftUI
/// guarantees that's the main actor for our usage.
@MainActor
@Suite("Binding+PasteAware")
struct BindingPasteAwareTests {

    // MARK: - Helpers

    /// A box around a String that the test code can mutate through a
    /// `Binding`. Using a class so the binding's `get`/`set` closures
    /// share the same state across the test.
    final class StringBox {
        var value: String
        init(_ initial: String = "") { self.value = initial }
    }

    /// Records every payload the callback receives, in arrival order.
    final class PayloadRecorder {
        private(set) var payloads: [PairingURLParser.PairingPayload] = []
        var callCount: Int { payloads.count }
        func record(_ payload: PairingURLParser.PairingPayload) {
            payloads.append(payload)
        }
    }

    /// Standard test fixture: paired box + recorder + the wrapped binding.
    private func makeFixture(initial: String = "") -> (StringBox, PayloadRecorder, Binding<String>) {
        let box = StringBox(initial)
        let recorder = PayloadRecorder()
        let raw = Binding<String>(
            get: { box.value },
            set: { box.value = $0 }
        )
        let wrapped = raw.pasteAware { payload in
            recorder.record(payload)
        }
        return (box, recorder, wrapped)
    }

    // MARK: - Pairing-URL routing

    @Test("Pasting a complete tron://pair URL fires the callback and does NOT write to the binding")
    func completePairURLRoutesToCallback() {
        let (box, recorder, wrapped) = makeFixture(initial: "before")

        wrapped.wrappedValue = "tron://pair?host=100.64.0.1&port=9847&token=secret-token"

        #expect(recorder.callCount == 1)
        #expect(recorder.payloads.first?.host == "100.64.0.1")
        #expect(recorder.payloads.first?.port == 9847)
        #expect(recorder.payloads.first?.token == "secret-token")
        #expect(recorder.payloads.first?.label == nil)
        // Critical: the URL literal never reaches the binding. SwiftUI
        // therefore never renders it — the user sees the auto-distributed
        // field values directly.
        #expect(box.value == "before")
    }

    @Test("Pasting a tron://pair URL with optional label includes it in the payload")
    func pairURLWithLabel() {
        let (box, recorder, wrapped) = makeFixture(initial: "")

        wrapped.wrappedValue = "tron://pair?host=10.0.0.1&port=9847&token=tok&label=My%20Mac"

        #expect(recorder.callCount == 1)
        #expect(recorder.payloads.first?.label == "My Mac")
        #expect(box.value == "")
    }

    @Test("Multiple distinct pastes each fire the callback exactly once")
    func multiplePastesEachFireCallback() {
        let (_, recorder, wrapped) = makeFixture()

        wrapped.wrappedValue = "tron://pair?host=1.1.1.1&port=9847&token=a"
        wrapped.wrappedValue = "tron://pair?host=2.2.2.2&port=9000&token=b"
        wrapped.wrappedValue = "tron://pair?host=3.3.3.3&port=8000&token=c"

        #expect(recorder.callCount == 3)
        #expect(recorder.payloads.map { $0.host } == ["1.1.1.1", "2.2.2.2", "3.3.3.3"])
        #expect(recorder.payloads.map { $0.port } == [9847, 9000, 8000])
        #expect(recorder.payloads.map { $0.token } == ["a", "b", "c"])
    }

    // MARK: - Fall-through for normal text

    @Test("Plain text writes through to the binding and does NOT fire the callback")
    func plainTextFallsThrough() {
        let (box, recorder, wrapped) = makeFixture(initial: "")

        wrapped.wrappedValue = "100.64.0.1"

        #expect(box.value == "100.64.0.1")
        #expect(recorder.callCount == 0)
    }

    @Test("Single keystrokes write through one at a time without firing the callback")
    func keystrokesFallThrough() {
        let (box, recorder, wrapped) = makeFixture(initial: "")

        // Simulate the SwiftUI binding being assigned each successive value
        // as the user types one character at a time into a TextField.
        let keystrokes = ["t", "tr", "tro", "tron", "tron@", "tron@dev"]
        for value in keystrokes {
            wrapped.wrappedValue = value
        }

        #expect(box.value == "tron@dev")
        #expect(recorder.callCount == 0)
    }

    @Test("Empty string write goes straight to the binding")
    func emptyWriteFallsThrough() {
        let (box, recorder, wrapped) = makeFixture(initial: "old")

        wrapped.wrappedValue = ""

        #expect(box.value == "")
        #expect(recorder.callCount == 0)
    }

    @Test("A tron://pair substring NOT matching the parser falls through to the binding")
    func partialOrMalformedPairURLFallsThrough() {
        // The fast-path string check matches `"tron://pair"`, so the
        // parser runs — but the parser rejects this (port is invalid).
        // That MUST write the literal so the user can keep
        // editing. (In practice the user would never type this exactly,
        // but the safety property matters: a bad parse must not silently
        // drop the keystroke.)
        let (box, recorder, wrapped) = makeFixture(initial: "")

        let malformed = "tron://pair?host=1.1.1.1&port=NOT_A_NUMBER&token=t"
        wrapped.wrappedValue = malformed

        #expect(box.value == malformed)
        #expect(recorder.callCount == 0)
    }

    @Test("A tron://pair URL missing required fields falls through to the binding")
    func pairURLMissingFieldsFallsThrough() {
        let (box, recorder, wrapped) = makeFixture(initial: "")

        // Missing token — parser returns .failure, helper falls through.
        let missingToken = "tron://pair?host=1.1.1.1&port=9847"
        wrapped.wrappedValue = missingToken

        #expect(box.value == missingToken)
        #expect(recorder.callCount == 0)
    }

    @Test("A user typing 'tron://' partially does not crash and lands as plain text")
    func partialSchemeTextFallsThrough() {
        let (box, recorder, wrapped) = makeFixture(initial: "")

        // Doesn't contain "tron://pair" — fast-path rejects, never even
        // calls the parser.
        wrapped.wrappedValue = "tron://"
        #expect(box.value == "tron://")
        #expect(recorder.callCount == 0)

        wrapped.wrappedValue = "tron://pa"
        #expect(box.value == "tron://pa")
        #expect(recorder.callCount == 0)
    }

    // MARK: - Binding read-through

    @Test("Reading the wrapped binding returns the current value of the underlying binding")
    func getReturnsCurrentValue() {
        let (box, _, wrapped) = makeFixture(initial: "initial")

        #expect(wrapped.wrappedValue == "initial")

        box.value = "mutated externally"
        #expect(wrapped.wrappedValue == "mutated externally")
    }
}
