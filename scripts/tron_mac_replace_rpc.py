"""The Gateway RPC client of `scripts/tron mac replace`: one request per Node child.

`MacPlatform.rpc` runs `RPC_CLIENT` with the installed payload's Node and maps
its exit code and JSON output onto `RpcError`.
"""

RPC_CLIENT = r'''
const WebSocket = require("ws");
const [url, token, protocolVersion, method, paramsJson, timeoutMs] = process.argv.slice(1);
const ws = new WebSocket(url, { headers: { authorization: `Bearer ${token}` }, perMessageDeflate: false });
let sent = false, finished = false;
const done = (code, value) => {
  if (finished) return;
  finished = true;
  clearTimeout(timer);
  ws.terminate();
  // A task-history response can exceed the stdout pipe's capacity. Natural
  // exit drains that write; process.exit() silently truncates it (#1254).
  process.exitCode = code;
  process.stdout.write(JSON.stringify(value));
};
const timer = setTimeout(() => done(2, { error: { code: "timeout", message: `${method} timed out waiting for ${sent ? "response" : "handshake"}` } }), Number(timeoutMs));
ws.on("open", () => ws.send(JSON.stringify({ type: "hello", protocolVersion: Number(protocolVersion), minProtocolVersion: Number(protocolVersion) })));
ws.on("message", raw => {
  let frame; try { frame = JSON.parse(raw.toString()); } catch { return; }
  if (frame.type === "hello" && !sent) { sent = true; ws.send(JSON.stringify({ type: "request", id: "replace", method, params: JSON.parse(paramsJson) })); }
  if (frame.type === "error" && frame.id === undefined) { done(3, { error: frame.error ?? { code: "handshake", message: "handshake refused" } }); }
  if (frame.type === "response" && frame.id === "replace") {
    done(frame.ok === true ? 0 : 3, frame.ok === true ? { result: frame.result } : { error: frame.error ?? { code: "error", message: "request failed" } });
  }
});
// Exit 4: the request never left this process, so another listener may be
// tried. Once sent, a lost connection is that request's own failure.
ws.on("error", error => done(sent ? 5 : 4, { error: { code: sent ? "connection-lost" : "unreachable", message: String(error.message || error) } }));
ws.on("close", (code, reason) => done(5, { error: { code: "connection-lost", message: `${method}: socket closed before ${sent ? "response" : "handshake"} (${code}${reason.length ? ": " + reason.toString() : ""})` } }));
'''


class RpcError(Exception):
    def __init__(self, code, message):
        super().__init__(f'{code}: {message}')
        self.code, self.message = code, message
