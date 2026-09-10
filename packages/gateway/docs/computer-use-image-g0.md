# Computer-use image serialization G0

This qualification fixture covers only the Pi image path. It does not expose a
computer-use tool, select an executor, call a provider, read credentials, or
change Gateway production behavior.

## Frozen boundary

- Pi packages are pinned to `0.84.4` by `packages/gateway/package.json` and
  `package-lock.json`. The inspected `pi-ai/dist/api/openai-responses-shared.js`
  is SHA-256
  `7006d5fc69946078ae4113906bd251d0387f148e06756a2670e00807a0aa8744`.
- The fixture uses the public lazy `openAIResponsesApi()` provider surface and
  its public `onPayload` callback. An intercepted fetch reads the actual serialized
  request body and returns a local HTTP 418 response without invoking any real
  transport. The captured body must match the constructed payload.
- The history contains a synthetic `computer` tool call and a separate
  unrelated call. Each result has text plus an in-memory PNG. The payload
  assertion checks exact data-URL bytes, PNG IHDR dimensions, result order, and
  the exact `call_id` correlation.
- The pinned serializer currently emits `detail: "auto"` for both user and
  tool-result images. This result is from the provider-bound payload, not a
  source-text or regex assertion.

The second test registers the public
`before_provider_request` extension event and applies a fixture-only transform
that changes `detail` to `"original"` for the synthetic native result's exact
call ID. It asserts that user history and the unrelated tool result remain
unchanged, and that the original captured payload is not mutated. This
intentionally does **not** make a production detail choice.

Run the focused suite with:

```bash
cd packages/gateway
npx vitest run src/providers/pi-image-serialization.test.ts
```

## G0 result and limits

Use the pinned development Node/npm pair, not a hardened Gateway payload Node
with unrelated development native modules. No signature or dependency changes
are needed to run the source tests.

The fixture can establish serialization integrity and the narrow public hook
seam. It cannot establish that a live provider accepts `detail: "original"`,
that a model interprets the pixels correctly, or that model coordinates survive
native crop/scale inversion. Those remain the live-provider/model fidelity gate
before any production override or native tool is considered. The synthetic PNG
also does not stand in for ScreenCaptureKit dimensions, Retina scale, negative
display origins, or an application effect oracle.
