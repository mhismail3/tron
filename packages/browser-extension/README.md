# Tron Browser Operator extension

This unpacked Manifest V3 extension is the fixed actuator for the ordinary
runtime-managed `browser-operator` worker. The worker plans and verifies work.
The extension only discovers bounded tabs, observes the active page, captures a
bounded screenshot, or applies one closed click/type/key/scroll/navigation
action.

The boundary requires explicit foreground consent. Click the extension toolbar
button on the tab Tron may control. Chrome shows an `ON` badge and the page
shows “Tron is controlling this tab.” Clicking the button again stops control.
Any controlled action is rejected if that tab is no longer foreground. Password
fields are neither observed nor writable.

## Local setup

1. Open `chrome://extensions`, enable Developer mode, and choose **Load
   unpacked** for this directory.
2. Copy the 32-character extension ID Chrome displays.
3. Build or select the exact Tron binary used by the target engine.
4. Install the owner-only Native Messaging manifest:

   ```bash
   packages/browser-extension/scripts/install-native-host.sh --extension-id EXTENSION_ID --tron-binary /absolute/path/to/tron --tron-home /absolute/path/to/.tron
   ```

Reload the extension after changing its source. No extension, host, or worker is
installed automatically by the server. Production deployment remains manual.

## Security and lifecycle

- Chrome starts and stops the native host with the extension connection.
- The host socket is owner-only and permits one serialized actuator request.
- Requests and responses have hard byte, queue, and deadline limits.
- Client cancellation emits a fixed cancellation message to the extension.
  Cancellation is retained only for an admitted queued/running request, expires
  after the maximum request lifetime, and is removed at completion; late
  cancellation cannot accumulate request IDs in the service worker.
- Navigation accepts HTTPS and loopback HTTP only and rejects embedded
  credentials.
- No arbitrary JavaScript, cookies, credentials, downloads, headers, extension
  API calls, shell commands, or background tabs are expressible.
- Every mutation returns a fresh observation. Failure to observe after acting is
  a failed operation, never assumed success. Navigation listeners, cancellation
  handlers, consent state, observations, and request state are removed by their
  owning completion, tab-close, consent-disable, or disconnect path.

Run the pure protocol and mocked-Chrome lifecycle tests with `npm test`.
