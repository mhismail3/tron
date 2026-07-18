# Tron Native UI Definitions

These files are the bundled, known-good [A2UI v0.9.1 protocol](https://github.com/a2ui-project/a2ui/blob/main/specification/v0_9_1/docs/a2ui_protocol.md)
definitions shared by the server and iOS client. They contain canonical A2UI
messages plus the smallest Tron-owned definition envelope needed to pin catalog
revision and lifecycle.

Live server revisions use the same shape. The iOS copies are an emergency
fallback only; validated active server revisions remain authoritative.

The current catalog is `https://tron.local/native-ui/catalogs/sheet/v1`
revision 1. Unknown catalog revisions fail closed. A2UI v1 is not wire
compatible by assumption and requires a separately tested compatibility and
catalog revision change.

Tron intentionally does not depend on the upstream repository's placeholder
[Swift core](https://github.com/a2ui-project/a2ui/blob/main/swift/core/Sources/A2UICore/A2UICore.swift)
or [SwiftUI renderer](https://github.com/a2ui-project/a2ui/blob/main/swift/swiftui/Sources/A2UISwiftUI/A2UISwiftUI.swift).
Only the protocol is pinned; decoding, validation, and the precompiled native
catalog remain Tron-owned.

Publication is always validate → isolated preview → explicit compare-and-swap
activation. History and rollback use the same immutable revision store. Future
agent-authored definitions must use this exact seam; there is no model-only
publication shortcut.
