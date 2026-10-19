# Static webpages

Small, shared HTML/CSS patterns for Tron's generated webpages. No framework,
package install, build chain, hosting service or app registry. The real first
consumer is the remote iOS development-build page.

## Canonical locations

| Content | Source of truth |
|---|---|
| Shared design tokens and patterns | [`tron.css`](tron.css), edited here only |
| OTA page markup, escaped metadata and install links | [`scripts/ios-share-publish.py`](../../scripts/ios-share-publish.py), `render_index`; do not copy its template into an app directory |
| Fixture preview and publisher/server journey | [`scripts/test-tron-ios-device-share.py`](../../scripts/test-tron-ios-device-share.py) |
| Future maintained plain-HTML mini apps | `tools/web/apps/<app-id>/` (create only for a real app); keep its source and concise purpose/preview instructions version-controlled here |
| Artifact/discovery root (default Stable installation) | `~/.tron/workspace/files/mini-apps/README.md`: small index linking back to these repository owners, not a second source tree |
| App-specific review artifacts | `~/.tron/workspace/files/mini-apps/<app-id>/previews/<review-id>/` for generated pages; `evidence/<review-id>/` for labeled screenshots/results |

Debug/custom installations have their own resolved workspace root. Internal
files are deliberately retained outputs, not an installed runtime. Never keep an
editable stylesheet, copied publisher or maintained app source in that tree.
No generic private-state namespace or API is established by this design system.
Any future mutable state needs a separately approved owner; never put credentials
or live databases in pages, previews, repositories or a publicly served tree.

## Consume the language

Use semantic HTML and opt in with `<body class="tron-page">`. Layout and patterns:

- `tron-shell`: bounded reading width, phone gutters and safe-area insets.
- `tron-stack` / `tron-row`: vertical rhythm and wrapping compact rows.
- `tron-intro`, `tron-meta`, `tron-reading`: heading, secondary metadata and
  faithful pre-wrapped reading content; normal text starts at 1rem.
- `tron-card` / `tron-card--featured`: opaque content surfaces, modest corners.
- `tron-button` / `tron-button--primary`: real button or anchor with at least
  44×44 CSS-pixel target and visible keyboard focus; no clickable divs.
- `tron-badge` / `tron-badge--accent`: noninteractive, text-labeled status.
- `tron-toolbar`: optional, small blurred chrome, not glass on content panels.

Embed `tron.css` at generation time for self-contained documents, or copy that
exact asset to an explicitly owned static output alongside a relative stylesheet
link. Do not fork it or fetch it from a CDN. The OTA publisher reads it before
mutating the output tree and embeds it in `index.html`; no asset routes or
server changes are needed. Build metadata is still escaped by the one renderer.
Future app-specific styling stays with that app; promote a pattern here only
when a real consumer needs it. No unused form or JavaScript component library.

Light/dark follow the browser preference using semantic tokens based on Tron's
native palette. Native theme/Settings files are references, not web dependencies.
Solid content stays readable without backdrop-filter. Reduced transparency and
reduced motion disable toolbar blur; forced colors uses system colors. There are
no motion effects to turn off. Preserve zoom, wrapping, focus order, labels and
color-independent status. Check actual composited contrast, not swatches alone.

## Edit → preview → approve → validate

1. Check current issue/worktree ownership; edit the canonical CSS and the real
   consumer only. Keep native Settings, host lifecycle and storage work separate.
2. From the repository root, render through the **real publisher** into a new
   fixture output (choose a fresh review id):

   ```sh
   python3 scripts/test-tron-ios-device-share.py --preview-dir build/web-preview/ios-builds/review-1
   ```

   This mode runs no regression suite, uses synthetic metadata/non-installable
   IPA files and never contacts the live host. It refuses an existing output
   directory. CSS is embedded. To inspect with the browser tool, use the existing
   static-server script against **only this fixture**, on an unused loopback port:

   ```sh
   python3 scripts/ios-share-server.py "$PWD/build/web-preview/ios-builds/review-1" 8765
   ```

   Open `http://127.0.0.1:8765/`. This is a foreground disposable preview, not
   `share-host enable`; track its PID/port and stop it when done. Do not reuse
   the live :8444 server or activate a fixture `itms-services` link.
3. Capture actual local-fixture renders in desktop and narrow phone viewports,
   light/dark, plus larger text. Label viewport simulations honestly: screenshots
   are not physical-iPhone or interaction proof. Copy useful generated output to
   the stable app preview folder and captures to its evidence folder; record the
   source commit, viewport/preferences, commands and limits. Link them from the
   workspace index. Do not commit generated pages/screenshots into this source.
4. For visual changes, checkpoint and get maintainer approval **before** full
   regression validation or merge. After approval, run the real publisher/server
   fixture and relevant browser journeys for routes, focus, phone layout and
   reduced effects. Use the existing journey, not implementation-detail tests:

   ```sh
   python3 scripts/test-tron-ios-device-share.py --fixture-only
   ```

   The command **without flags publishes a real iOS build**. Do not run it as a
   styling test. Browser fixtures must never install anything. Record meaningful
   test artifacts; source-string/style-value assertions are not behavioral proof.

## Release, retention and boundaries

A source commit does not change the live page. Only a separately authorized
normal `scripts/tron-ios-device share` from fetched main invokes this renderer
and embeds the shared CSS into the next generated index. Existing server/Tailscale
configuration stays unchanged; no Gateway/app build or restart is needed for CSS.
Do not manually edit `~/.tron/ios-builds/index.html` or other generated/live files.

Existing runtime paths remain as documented in the
[OTA runbook](../../packages/ios-app/docs/development.md#over-the-air-development-install):
`~/.tron/ios-builds` holds index/latest and the publisher's newest-five build
releases; `127.0.0.1:8444` / Tailscale HTTPS :8443 and `com.tron.ios-builds` remain
host-owned. Preserve `/`, `/latest.plist`, `/builds/<id>/…`, manifest URLs, escaped
notes and install links. No publishing/host authority comes from this guide.
Host-disable ownership is separate work (#1327).

Remove your disposable preview processes/files when finished; keep the current
approval evidence and last accepted comparison until superseded, then remove
only exact owner-identified artifacts. Do not prune other workers' previews,
canonical/private state, credentials, recovery copies, signed products or live OTA
builds. Artifact age alone is not deletion permission. This guide establishes no
automation, state migration or new retention mechanism.
