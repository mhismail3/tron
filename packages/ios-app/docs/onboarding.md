# iPhone onboarding

Onboarding keeps Tron terminology and treats the Mac as the private execution
host. The ordinary session shell mounts first, then presents setup in Tron's
established non-dismissible sheet only after launch credential resolution says
pairing or setup is required. A paired, completed installation never flashes the
sheet while Keychain and the gateway connection are still being checked.
Preparation/pairing pages prefer the medium
detent; workspace/provider/model pages expand to large. The drag indicator stays
hidden while the native upward sheet gesture remains available.

1. **Welcome** explains the private Mac/iPhone connection.
2. **Tailscale** preserves the established private-network preparation page.
3. **Install Tron on Mac** points to the Mac app and pairing information.
4. **Pair Mac** scans or enters
   `tron://pair?host=<tailscale>&port=<port>&code=<one-time>&label=<mac>`.
   iOS exchanges the short-lived code at `POST /v1/pair`; the returned device
   token goes directly to Keychain. Exactly one pairing attempt owns enrollment:
   a newer invitation supersedes the older attempt, and forgetting or switching
   Macs invalidates pending enrollment before profile metadata, Keychain, or a
   Gateway connection can be started from its late HTTP result.
5. **Workspace** chooses a Mac directory. Every visible folder row uses its full
   glass container as the selection target, not only the icon or label. If
   executable project resources require a decision, onboarding presents explicit
   trust controls and states that trust is not a sandbox.
6. **Anthropic** presents its runtime-reported authentication methods when the
   current runtime enables it.
7. **OpenAI** does the same without assuming one credential type.
8. **Other providers** presents the remaining dynamic provider catalog. Connect
   and Configure open the same standardized provider configuration sheet used by
   Settings, with every runtime-advertised API-key and account-login method in
   one place. API-key entry stays inline in that sheet with a value-gated Save
   action. API keys and OAuth responses go directly to the Mac credential
   flow and are not persisted by iOS.
9. **Default model** chooses a provider-qualified model, records local setup
   completion, and dismisses the sheet to reveal the already-mounted shell and
   floating new-session action.

Pairing invitations reject URLs, userinfo, paths, malformed hosts, invalid
ports, and codes outside 8–32 trimmed characters. Permanent tokens are never
accepted from QR query items.

If setup is interrupted after pairing, the Keychain-backed profile remains and
the setup sheet resumes at workspace selection. Losing or revoking the device
token requires a fresh one-time invitation from the Tron menu bar on the Mac.
Pairing validation errors belong to the sheet and use contextual inline or scoped in-app notification feedback so presentation never tears down first-run state. Cancellation caused by supersession or teardown is silent; transport, status, and decoding failures remain visible there without a blocking single-OK alert.

Every onboarding page uses the same app-wide presentation primitives as chat
and settings: selected-family semantic typography, emerald glass action and
icon controls, custom toolbar titles, glass code/text fields, custom search and
selection controls, and Tron card/section surfaces. As in the historical app,
sheet toolbar buttons use default iOS toolbar styling: Tron supplies semantic
font/color only, while iOS owns Liquid Glass containers, circle/capsule geometry,
padding, grouping, pressed states, and hit regions. App-drawn toolbar glass must
not be layered inside that system chrome. The nine-step indicator retains 6-point
dots, a 16-point active segment, 6-point spacing, and 10-by-6-point capsule
insets. Provider-driven content may
be generic, but it may not fall back to stock SwiftUI fonts, bordered buttons,
or field styles. Destructive confirmations, QR camera chrome, and external pickers remain system-owned; routine pairing feedback uses the shared notification host.
