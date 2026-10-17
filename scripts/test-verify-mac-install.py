#!/usr/bin/env python3
"""Full verifier CLI with synthetic macOS artifacts/discovery and real WS/TLS.

No installed app, launchd job, real Tron home or fixed Gateway port is touched.
Signing/architecture discovery are synthetic platform boundaries, not signature
qualification. The unmodified verifier executes its real validators and probes;
fixture Node launchers redirect only the fixed probe ports to owned ephemeral
listeners, preserving the host (including IPv6) and authentication exchange.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import selectors
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "test-results/mac-verify/report.json"

SERVER = r"""
const fs = require('node:fs');
const https = require('node:https');
const { WebSocketServer } = require(process.env.FIXTURE_WS);
const servers = [];
const modes = () => fs.readFileSync(process.env.FIXTURE_MODE, 'utf8').trim();
function gateway(host, channel, kind) {
  const server = new WebSocketServer({host, port: 0}); servers.push(server);
  server.on('connection', (ws, req) => {
    if (req.headers.authorization !== 'Bearer fixture-token') return ws.close(1008);
    ws.on('message', raw => {
      const frame = JSON.parse(raw.toString());
      fs.appendFileSync(process.env.FIXTURE_EVENTS, JSON.stringify({kind, type:frame.type, method:frame.method})+'\n');
      if (frame.type === 'hello') {
        if (frame.protocolVersion !== 8 || frame.minProtocolVersion !== 8) return ws.close(1008);
        return ws.send(JSON.stringify({type:'hello',protocolVersion:8,minProtocolVersion:8}));
      }
      if (frame.type !== 'request' || frame.method !== 'system.info') return ws.close(1008);
      const result = {gatewayChannel:channel,buildFingerprint:'a'.repeat(64),sourceRevision:'b'.repeat(40),runtimeEpoch:'fixture-epoch'};
      if (kind === 'wrong') result.gatewayChannel = 'stable';
      if (channel === 'dev' && modes() === 'wrong-main') result.buildFingerprint = 'c'.repeat(64);
      ws.send(JSON.stringify({type:'response',id:frame.id,ok:true,result}));
    });
  });
  return new Promise(resolve => server.on('listening', () => resolve(server.address().port)));
}
(async () => {
  const stable = await gateway('127.0.0.1','stable','stable');
  const debug = await gateway('127.0.0.1','dev','debug');
  const wrong = await gateway('::1','dev','wrong');
  const tls = https.createServer({key:fs.readFileSync(process.env.FIXTURE_KEY),cert:fs.readFileSync(process.env.FIXTURE_CERT)});
  servers.push(tls); tls.on('tlsClientError', () => fs.appendFileSync(process.env.FIXTURE_EVENTS,JSON.stringify({kind:'tls',type:'rejected-plain'})+'\n'));
  await new Promise(resolve => tls.listen(0,'::1',resolve));
  console.log(JSON.stringify({stable,debug,wrong,tls:tls.address().port}));
})().catch(error => { console.error(error); process.exit(1); });
process.on('SIGTERM', () => { for (const server of servers) server.close(); process.exit(0); });
"""

# Only macOS observations are synthetic. In particular Python, the verifier's
# JSON identity predicate, the Node client and WS/TLS negotiation are real.
PLATFORM = r"""import json, os, pathlib, subprocess, sys
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
state=json.loads(pathlib.Path(os.environ['FIXTURE_STATE']).read_text())
mode=pathlib.Path(os.environ['FIXTURE_MODE']).read_text().strip()
if name == 'codesign':
    if '-dv' in args: print('Identifier=com.tron.mac.native-host',file=sys.stderr)
    elif '--entitlements' in args: print('<key>com.apple.security.cs.allow-jit</key><true/>')
    raise SystemExit(0)
if name == 'lipo':
    path=args[-1]
    print('arm64' if path.endswith('node-arm64') else 'x86_64' if path.endswith('node-x64') else 'arm64 x86_64')
    raise SystemExit(0)
if name == 'launchctl':
    if args != ['print',f"gui/{os.getuid()}/com.tron.server"]: raise SystemExit(1)
    print(f"state = running\nparent bundle identifier = com.tron.mac\npid = {state['child']}\nTRON_GATEWAY_SUPERVISED => 1\nTRON_GATEWAY_CHANNEL => stable")
    raise SystemExit(0)
if name == 'ps':
    if 'lstart=' in args:
        raise SystemExit(subprocess.call(['/bin/ps',*args]))
    # The stable and Debug fixture share a real process. The platform fixture
    # records which ownership cut the verifier is inspecting.
    print(state['stableCommand'] if pathlib.Path(os.environ['FIXTURE_CUT']).read_text() == 'stable' else state['debugCommand'])
    raise SystemExit(0)
if name == 'lsof':
    stable=any('9847' in arg for arg in args)
    pathlib.Path(os.environ['FIXTURE_CUT']).write_text('stable' if stable else 'debug')
    if any(arg.startswith('-tiTCP:') for arg in args):
        if not stable and mode == 'absent': raise SystemExit(0)
        print(state['child']); raise SystemExit(0)
    port=9847 if stable else 9848
    hosts=['127.0.0.1'] if stable or mode in ('main-only','wrong-main') else [] if mode=='no-sockets' else ['[::1]','127.0.0.1']
    print('COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME')
    for host in hosts: print(f"node {state['child']} fixture 9u IPv6 0 0t0 TCP {host}:{port} (LISTEN)")
    raise SystemExit(0)
raise SystemExit('unexpected fixture platform command')
"""


def executable(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)


def document(path: Path, value: dict, *, plist: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value) if plist else json.dumps(value).encode())


class VerifierJourney(unittest.TestCase):
    def test_debug_listener_cut_uses_first_answer_not_first_socket(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tron-mac-verify-") as directory:
            root = Path(directory)
            home = root / "home"
            home.mkdir()
            repo = root / "repo"
            shutil.copytree(ROOT / "scripts", repo / "scripts", ignore=shutil.ignore_patterns("__pycache__"))
            shutil.copytree(ROOT / "config", repo / "config")
            for relative in (
                "packages/gateway/src/version.ts", "packages/ios-app/Core/Gateway/GatewayProtocolContract.swift",
                "packages/mac-app/Sources/Server/Health/GatewayProtocolContract.swift",
                "packages/mac-app/scripts/tron-gateway-launcher.c", "packages/mac-app/scripts/verify-macho-architectures.sh",
                "packages/ios-app/project.yml", "packages/mac-app/project.yml",
                "packages/ios-app/Sources/Info.plist", "packages/mac-app/Sources/Info.plist",
            ):
                target = repo / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / relative, target)
            environment = {**os.environ, "HOME": str(home), "TMPDIR": str(root), "PYTHONDONTWRITEBYTECODE": "1"}
            node = subprocess.check_output([ROOT / "scripts/tron-node", "exec", "node", "-p", "process.execPath"], text=True).strip()
            pin = json.loads((ROOT / "packages/mac-app/cua-driver-release.json").read_text())
            cua = b"fixture-cua-not-a-production-artifact\n"
            pin["binarySHA256"] = hashlib.sha256(cua).hexdigest()
            document(repo / "packages/mac-app/cua-driver-release.json", pin)
            app = root / "Tron.app"
            native = app / "Contents/Library/Native"
            host = native / "Tron Native Host.app"
            document(app / "Contents/Info.plist", {"TRONGatewayProtocolVersion": "8", "TRONGatewayMinProtocolVersion": "8", "TronSigningTeam": "FIXTURE123"}, plist=True)
            document(host / "Contents/Info.plist", {"CFBundleIdentifier": "com.tron.mac.native-host", "CFBundleExecutable": "TronNativeHost", "TronSigningTeam": "FIXTURE123", "LSUIElement": True, "LSBackgroundOnly": False, "TronCuaDriverSHA256": pin["binarySHA256"]}, plist=True)
            executable(host / "Contents/MacOS/TronNativeHost", "#!/bin/sh\nexit 0\n")
            (native / "tron-native-capture.node").write_bytes(b"x" * 1024)
            document(native / "tron-native-capture.inputs.json", {"schema": 1, "testOnly": False, "inputs": {"fixture": "0" * 64}})
            executable(native / "cua-driver", cua.decode())
            document(native / "cua-driver.manifest.json", pin)
            (native / "cua-driver-LICENSE.txt").write_text("fixture")
            document(app / "Contents/Library/LaunchAgents/com.tron.mac.native-host.plist", {"Label": "com.tron.mac.native-host", "BundleProgram": "Contents/Library/Native/Tron Native Host.app/Contents/MacOS/TronNativeHost", "MachServices": {"com.tron.mac.native-host": True, "com.tron.mac.native-host.capture": True}, "AssociatedBundleIdentifiers": ["com.tron.mac"], "LimitLoadToSessionType": "Aqua", "RunAtLoad": True}, plist=True)
            document(app / "Contents/Library/LaunchAgents/com.tron.server.plist", {"Label": "com.tron.server", "AssociatedBundleIdentifiers": ["com.tron.mac"], "BundleProgram": "Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron", "EnvironmentVariables": {"TRON_GATEWAY_SUPERVISED": "1", "TRON_GATEWAY_CHANNEL": "stable"}, "ProgramArguments": ["tron"]}, plist=True)
            executable(app / "Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron", "#!/bin/sh\nprintf '%064d\\n' 0 | tr 0 a\n")
            payload = app / "Contents/Resources/Gateway"
            document(payload / "manifest.json", {"schema": 1, "kind": "tron-gateway-payload", "channel": "dev", "version": "fixture", "payloadFingerprint": "a" * 64, "protocolVersion": "8", "minProtocolVersion": "8", "sourceRevision": "b" * 40, "runtimeEpoch": "fixture-epoch"})
            executable(payload / "app/dist/version.js", "export const PROTOCOL_VERSION = 8;\nexport const MIN_PROTOCOL_VERSION = 8;\n")
            (payload / "app/PushService.xcconfig").write_text("fixture")
            shutil.copytree(ROOT / "packages/gateway/node_modules/ws", payload / "app/node_modules/ws")
            executable(payload / "app/node_modules/@earendil-works/pi-coding-agent/cli.js", "#!/bin/sh\nexit 0\n")
            (payload / "app/node_modules/.bin").mkdir()
            (payload / "app/node_modules/.bin/pi").symlink_to("../@earendil-works/pi-coding-agent/cli.js")
            executable(payload / "runtime/xcodegen/bin/xcodegen", "#!/bin/sh\necho 'Version: 2.45.3'\n")
            presets = payload / "runtime/xcodegen/share/xcodegen/SettingPresets"
            presets.mkdir(parents=True)
            (presets / "base.yml").write_text("fixture")
            for architecture in ("arm64", "x64"):
                executable(payload / f"runtime/node-{architecture}", f"#!{sys.executable}\nimport json,os,pathlib,sys\nif os.environ.get('VERIFY_URL'):\n from urllib.parse import urlsplit,urlunsplit\n u=urlsplit(os.environ['VERIFY_URL']);ports=json.loads(pathlib.Path(os.environ['FIXTURE_PORTS']).read_text());mode=pathlib.Path(os.environ['FIXTURE_MODE']).read_text().strip()\n key='stable' if u.port==9847 else ('wrong' if mode=='wrong-first' else 'tls') if u.hostname=='::1' else 'debug'\n os.environ['VERIFY_URL']=urlunsplit((u.scheme,('['+u.hostname+']' if ':' in u.hostname else u.hostname)+':'+str(ports[key]),u.path,'',''))\nos.execv({node!r},[{node!r},*sys.argv[1:]])\n")
                executable(payload / f"runtime/npm-{architecture}/bin/npm-cli.js", "#!/bin/sh\nexit 0\n")
                document(payload / f"runtime/npm-{architecture}/package.json", {"version": "11.19.1"})
                aliases = payload / f"runtime/bin-{architecture}"
                aliases.mkdir()
                (aliases / "node").symlink_to(f"../node-{architecture}")
                (aliases / "npm").symlink_to(f"../npm-{architecture}/bin/npm-cli.js")
                (aliases / "pi").symlink_to("../../app/node_modules/.bin/pi")
            selection = home / ".tron-dev/gateway/payloads/dev"
            document(selection / "current.json", {"schema": 1, "kind": "tron-gateway-selection", "channel": "dev", "version": "fixture", "payloadFingerprint": "a" * 64})
            (selection / "versions").mkdir()
            shutil.copytree(payload, selection / "versions/fixture", symlinks=True)
            debug_payload = selection / "versions/fixture"
            for channel in (".tron", ".tron-dev"):
                document(home / channel / "gateway/local-auth.json", {"bearerToken": "fixture-token"})
            mode, events, state, ports, cut = (root / name for name in ("mode", "events", "state.json", "ports.json", "cut"))
            mode.write_text("tls-first")
            events.write_text("")
            cut.write_text("stable")
            tools = root / "bin"
            for name in ("codesign", "lipo", "launchctl", "lsof", "ps"):
                executable(tools / name, f"#!{sys.executable}\n" + PLATFORM)
            key, cert = root / "key.pem", root / "cert.pem"
            subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=localhost"], check=True, capture_output=True)
            environment.update({"PATH": f"{tools}:{Path(sys.executable).parent}:/usr/bin:/bin:/usr/sbin:/sbin", "TRON_APP_PATH": str(app), "FIXTURE_STATE": str(state), "FIXTURE_MODE": str(mode), "FIXTURE_EVENTS": str(events), "FIXTURE_PORTS": str(ports), "FIXTURE_CUT": str(cut), "FIXTURE_WS": str(payload / "app/node_modules/ws"), "FIXTURE_KEY": str(key), "FIXTURE_CERT": str(cert)})
            server = root / "server.cjs"
            server.write_text(SERVER)
            observations = []
            error_log = (root / "server-errors").open("w+")
            process = subprocess.Popen([node, server], env=environment, stdout=subprocess.PIPE, stderr=error_log, text=True)
            try:
                with selectors.DefaultSelector() as ready:
                    ready.register(process.stdout, selectors.EVENT_READ)
                    self.assertTrue(ready.select(timeout=10), "fixture server did not become ready")
                first = process.stdout.readline()
                self.assertTrue(first, "fixture server failed to publish its ports")
                ports.write_text(first)
                command = lambda path, arguments="": f"{path}/runtime/node-{'x64' if os.uname().machine == 'x86_64' else 'arm64'} --max-old-space-size=4096 {path}/app/dist/index.js{arguments}"
                document(state, {"child": process.pid, "stableCommand": command(payload), "debugCommand": command(debug_payload, " --host 127.0.0.1 --port 9848")})
                start = lambda pid: subprocess.check_output(["/bin/ps", "-o", "lstart=", "-p", str(pid)], text=True).strip()
                document(home / ".tron-dev/gateway/lifecycle.json", {"lifecycle": "ready", "expectedPort": 9848, "expectedHome": str(home / ".tron-dev"), "expectedHost": "127.0.0.1", "supervisorPid": os.getpid(), "supervisorStartIdentity": start(os.getpid()), "childPid": process.pid, "childStartIdentity": start(process.pid), "epoch": "fixture-epoch", "sourceRevision": "b" * 40, "buildFingerprint": "a" * 64})
                for scenario, success in (("tls-first", True), ("wrong-first", False), ("main-only", True), ("wrong-main", False), ("no-sockets", False), ("absent", True)):
                    with self.subTest(scenario=scenario):
                        mode.write_text(scenario)
                        events.write_text("")
                        cut.write_text("stable")
                        result = subprocess.run(["/bin/bash", repo / "scripts/verify-mac-install.sh"], env=environment, text=True, capture_output=True, timeout=40)
                        received = [json.loads(line) for line in events.read_text().splitlines()]
                        observations.append({"scenario": scenario, "returncode": result.returncode, "stdout": result.stdout, "stderr": result.stderr, "events": received})
                        failures = [line for line in result.stdout.splitlines() if line.startswith("FAIL")]
                        self.assertEqual(result.returncode, 0 if success else 1, "\n".join(failures) + result.stderr)
                        if success:
                            self.assertEqual(failures, [])
                            self.assertIn("Debug Gateway is absent" if scenario == "absent" else "Debug authenticated system.info matches selected manifest", result.stdout)
                        else:
                            self.assertEqual(len(failures), 1, "\n".join(failures))
                            self.assertTrue(failures[0].startswith("FAIL  Debug"), failures)
                        if scenario == "tls-first":
                            self.assertTrue(any(event["kind"] == "tls" for event in received), received)
                            self.assertTrue(any(event["kind"] == "debug" and event.get("method") == "system.info" for event in received), received)
                        if scenario == "wrong-first":
                            self.assertTrue(any(event["kind"] == "wrong" and event.get("method") == "system.info" for event in received), received)
                            self.assertFalse(any(event["kind"] == "debug" for event in received), received)
            finally:
                process.terminate()
                process.wait(timeout=10)
                process.stdout.close()
                error_log.close()
                REPORT.parent.mkdir(parents=True, exist_ok=True)
                REPORT.write_text(json.dumps({"boundary": "full-verifier/synthetic-macos/real-ws-tls", "observations": observations}, indent=2) + "\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
