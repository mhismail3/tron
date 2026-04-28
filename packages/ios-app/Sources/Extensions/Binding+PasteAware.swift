import SwiftUI

/// Universal-paste detection helper for the pairing flow.
///
/// The onboarding `PairingStep` form needs this UX: pasting a
/// `tron://pair?host=…&port=…&token=…[&label=…]` URL into ANY of the
/// host / port / token / label fields should auto-distribute the
/// parsed values across all the fields, instead of dropping the URL
/// literal into whichever field caught the paste.
///
/// **Why a Binding extension** (vs a `View` modifier or `onChange`):
///   - The detection has to fire INSIDE the binding's `set` so that
///     SwiftUI never gets a chance to render the literal URL into the
///     field — the moment the URL appears on screen, it's already
///     ugly. By intercepting in `set`, the user sees the
///     auto-distributed fields directly with no "URL flash".
///   - Composes cleanly with `TextField` and `SecureField` —
///     `TextField(placeholder, text: binding.pasteAware { … })`.
///   - Doesn't depend on a specific destination state shape — the
///     consumer supplies a closure that knows how to apply the payload.
///
/// Non-pairing pastes (anything that doesn't contain `tron://pair`)
/// fall through to the underlying binding unchanged so the helper is
/// transparent for normal text input.
extension Binding where Value == String {
    /// Wraps the binding so a `tron://pair?…` URL pasted (or typed)
    /// into the field is parsed and dispatched to `onPairingPayload`
    /// instead of being written into the field literally.
    ///
    /// The fast-path string check (`contains("tron://pair")`) keeps the
    /// hot keystroke path free of full URL parsing — the parser only
    /// runs when the prefix appears, which is rare for normal typing
    /// and ~always-true for a paste.
    @MainActor
    func pasteAware(
        onPairingPayload: @escaping (PairingURLParser.PairingPayload) -> Void
    ) -> Binding<String> {
        Binding<String>(
            get: { self.wrappedValue },
            set: { newValue in
                if newValue.contains("tron://pair"),
                   case .success(let payload) = PairingURLParser.parse(newValue) {
                    onPairingPayload(payload)
                    return
                }
                self.wrappedValue = newValue
            }
        )
    }
}
