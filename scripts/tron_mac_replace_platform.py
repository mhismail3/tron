"""The installed-Mac boundary of `scripts/tron mac replace` (#984).

`MacPlatform` is the only owner of live Stable effects: it quits Tron through
the app's coordinated Quit (AppKit terminate, so the Gateway drains and the
native helper retires normally; only a proven completed exit stall permits the
app to boot out its exact Gateway job without relaunch or Login Item disable), launches
the installed app so its approved Login Item starts the Gateway, and talks to
the Gateway over the authenticated socket its launchd job actually listens on. The E2E fixture subclasses it
with a launchd-supervised fixture Gateway; the orchestrator never branches on
which platform it drives.
"""
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import subprocess
import time
import uuid

REPO = Path(__file__).resolve().parent.parent


class Failure(Exception):
    """A step failure with its exact, user-facing message."""


def run(argv, log=None, timeout=600, env=None, cwd=None, check=True):
    """Run one owned command; full output goes to the step log, never stdout."""
    stream = open(log, 'a') if log else subprocess.DEVNULL
    try:
        if log:
            stream.write(f'$ {" ".join(str(arg) for arg in argv)}\n')
            stream.flush()
        result = subprocess.run([str(arg) for arg in argv], stdout=stream, stderr=subprocess.STDOUT,
                                timeout=timeout, env=env, cwd=cwd, start_new_session=True)
    except subprocess.TimeoutExpired:
        raise Failure(f'{Path(str(argv[0])).name} timed out after {timeout}s') from None
    finally:
        if log:
            stream.close()
    if check and result.returncode != 0:
        raise Failure(f'{Path(str(argv[0])).name} {" ".join(str(arg) for arg in argv[1:3])} exited {result.returncode}')
    return result.returncode


def capture(argv, timeout=60, env=None, cwd=None):
    result = subprocess.run([str(arg) for arg in argv], capture_output=True, timeout=timeout, env=env, cwd=cwd)
    return result.returncode, result.stdout.decode(errors='replace'), result.stderr.decode(errors='replace')


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


class MacPlatform:
    """Live Stable install: /Applications/Tron.app, com.tron.server on 9847, ~/.tron."""
    bundle_id = 'com.tron.mac'
    gateway_label = 'com.tron.server'
    helper_label = 'com.tron.mac.native-host'
    port = 9847
    quit_timeout = 45 * 60
    start_timeout = 5 * 60

    def __init__(self, home=None):
        self.home = Path(home or pwd.getpwuid(os.getuid()).pw_dir)
        self.installed = Path('/Applications/Tron.app')
        self.endpoint = None

    # Locations ---------------------------------------------------------
    @property
    def tron_home(self):
        return self.home / '.tron'

    @property
    def maintenance(self):
        return self.home / '.tron-maintenance'

    @property
    def store(self):
        # The Gateway derives the same path from its tronHome's parent.
        return self.maintenance / 'replace'

    def admit(self):
        """Refuse any environment that could aim live effects at the wrong home."""
        if os.getuid() == 0:
            raise Failure('run as the logged-in macOS user, not root')
        if Path.home().resolve() != Path(pwd.getpwuid(os.getuid()).pw_dir).resolve():
            raise Failure('HOME differs from the account home; refusing to act on another Tron install')
        for key in ('TRON_DATA_DIR', 'TRON_HOME_NAME', 'PI_CODING_AGENT_DIR'):
            if os.environ.get(key):
                raise Failure(f'{key} is set; the replacement acts only on the Stable install')

    def bundled_gateway(self, app):
        return Path(app) / 'Contents/Resources/Gateway'

    def active_payload(self):
        """The payload the running Stable launcher selected: the external channel when present, else bundled."""
        channel = self.tron_home / 'gateway/payloads/stable'
        current = channel / 'current.json'
        if current.exists():
            selected = json.loads(current.read_text())
            root = channel / 'versions' / selected['version']
            if (root / 'manifest.json').exists():
                return root
        return self.bundled_gateway(self.installed)

    def stable_channel(self):
        return self.tron_home / 'gateway/payloads/stable'

    # Detached runner: the launchd job runs a private copy of these files.
    def runner_files(self):
        return ()

    def runner_entry(self):
        return 'tron_mac_replace.py'

    def runner_arguments(self):
        return []

    # Gateway RPC -------------------------------------------------------
    def node(self):
        payload = self.bundled_gateway(self.installed)
        arch = 'node-x64' if os.uname().machine == 'x86_64' else 'node-arm64'
        return payload / 'runtime' / arch, payload / 'app/node_modules'

    def protocol(self):
        manifest = json.loads((self.bundled_gateway(self.installed) / 'manifest.json').read_text())
        return int(manifest['protocolVersion'])

    def token(self):
        return json.loads((self.tron_home / 'gateway/local-auth.json').read_text())['bearerToken']

    def gateway_pid(self):
        code, out, _ = capture(['/bin/launchctl', 'print', f'gui/{os.getuid()}/{self.gateway_label}'], timeout=15)
        match = re.search(r'^\tpid = (\d+)$', out, re.M) if code == 0 else None
        return int(match.group(1)) if match else None

    def endpoints(self):
        """Plain WebSocket URLs of the Gateway job's own listeners on its port.

        The bind is the launcher's choice, not ours: Stable binds its Tailscale
        address (plus a TLS-only LAN listener on a private address) and never
        loopback, so an assumed 127.0.0.1 is refused (#1059). Like
        verify-mac-install.sh, read the exact launchd PID's listeners; only the
        main one answers a plain socket, and rpc() remembers the one that did.
        """
        pid = self.gateway_pid()
        if pid is None:
            raise RpcError('unreachable', f'{self.gateway_label} has no running process to reach on port {self.port}')
        _, out, _ = capture(['/usr/sbin/lsof', '-nP', '-a', '-p', str(pid), f'-iTCP:{self.port}', '-sTCP:LISTEN', '-Fn'],
                            timeout=15)
        urls = []
        for line in out.splitlines():
            if not line.startswith('n'):
                continue
            host = line[1:].rsplit(':', 1)[0].strip('[]')
            host = {'*': '127.0.0.1', '0.0.0.0': '127.0.0.1', '::': '::1'}.get(host, host)
            url = f'ws://{f"[{host}]" if ":" in host else host}:{self.port}/v1/socket'
            if url not in urls:
                urls.append(url)
        if not urls:
            raise RpcError('unreachable', f'{self.gateway_label} (pid {pid}) has no TCP listener on port {self.port}')
        # The listener that answered last goes first, so the TLS-only one is
        # probed at most once per Gateway process.
        return sorted(urls, key=lambda url: url != self.endpoint)

    def rpc(self, method, params=None, timeout=30):
        node, modules = self.node()
        env = {'PATH': '/usr/bin:/bin', 'NODE_PATH': str(modules), 'HOME': str(self.home)}
        refused = []
        for url in self.endpoints():
            argv = [node, '-e', RPC_CLIENT, url, self.token(), str(self.protocol()),
                    method, json.dumps(params or {}), str(timeout * 1000)]
            try:
                code, out, _ = capture(argv, timeout=timeout + 15, env=env)
            except subprocess.TimeoutExpired:
                raise RpcError('timeout', f'{method} timed out on {url}') from None
            try:
                value = json.loads(out)
            except ValueError:
                detail = 'invalid JSON' if out else 'no output'
                raise RpcError('client-output', f'{method}: RPC client returned {detail} from {url} '
                               f'(exit {code}, stdout {len(out.encode())} bytes)') from None
            if code == 4:
                refused.append(f'{url}: {value["error"].get("message", "unreachable")}')
                continue
            self.endpoint = url
            if 'error' in value:
                error = value['error']
                raise RpcError(error.get('code', 'error'), f'{error.get("message", "request failed")} ({url})')
            return value['result']
        raise RpcError('unreachable', f'{method}: no {self.gateway_label} listener answered ({"; ".join(refused)})')

    def mutation(self, method, params=None, timeout=30):
        return self.rpc(method, {'commandId': f'mac-replace-{uuid.uuid4()}', **(params or {})}, timeout)

    def system_info(self):
        return self.rpc('system.info', timeout=10)

    # App lifecycle -----------------------------------------------------
    def app_running(self):
        code, out, _ = capture(['/usr/bin/osascript', '-l', 'JavaScript', '-e',
                                f"ObjC.import('AppKit'); $.NSRunningApplication.runningApplicationsWithBundleIdentifier('{self.bundle_id}').count"])
        return code == 0 and out.strip() not in ('', '0')

    def quit_app(self, log):
        # NSRunningApplication.terminate is AppKit's ordinary quit request: the
        # app runs its coordinated Quit (drain, authenticated stop, helper
        # retirement) exactly as the menu item does. It needs no Automation
        # consent, and it never signals a process.
        script = (f"ObjC.import('AppKit'); var a = $.NSRunningApplication.runningApplicationsWithBundleIdentifier('{self.bundle_id}');"
                  " a.count > 0 ? a.objectAtIndex(0).terminate : true")
        run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', script], log, timeout=30)

    def launch_app(self, log):
        run(['/usr/bin/open', '-g', self.installed], log, timeout=60)

    def launchd_state(self, label):
        code, out, _ = capture(['/bin/launchctl', 'print', f'gui/{os.getuid()}/{label}'], timeout=15)
        if code != 0:
            return 'absent'
        return 'running' if re.search(r'^\tpid = \d+$', out, re.M) else 'stopped'

    def port_listening(self):
        code, out, _ = capture(['/usr/sbin/lsof', '-nP', f'-iTCP:{self.port}', '-sTCP:LISTEN', '-t'], timeout=15)
        return bool(out.strip())

    def offline_blocker(self):
        """None once the app, Gateway and helper have all retired, else what still runs."""
        if self.app_running():
            return 'Tron is still quitting (accepted Gateway work drains first)'
        if self.launchd_state(self.gateway_label) == 'running':
            return f'{self.gateway_label} is still running'
        if self.launchd_state(self.helper_label) == 'running':
            return 'the native helper is still retiring'
        if self.port_listening():
            return f'port {self.port} still has a listener'
        return None

    def helper_state(self):
        return self.launchd_state(self.gateway_label), self.launchd_state(self.helper_label)

    # Build and verification -------------------------------------------
    def signing_identities(self):
        _, out, _ = capture(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'])
        return len(re.findall(r'^\s+\d+\) [0-9A-F]{40} ', out, re.M))

    def build_root(self, revision):
        return self.store / 'builds' / revision

    def build(self, source_root, revision, log):
        """Release build of `revision` in its own detached worktree; returns the signed app."""
        worktree = self.build_root(revision)
        if not (worktree / '.git').exists():
            worktree.parent.mkdir(parents=True, exist_ok=True)
            run(['/usr/bin/git', '-C', source_root, 'worktree', 'add', '--detach', worktree, revision], log, timeout=300)
        # The one repository resolver picks the pinned development Node (#242);
        # this process inherits the Gateway's signed payload runtime on PATH.
        code, out, err = capture([Path(source_root) / 'scripts/tron-node'], env=dict(os.environ, HOME=str(self.home)))
        if code != 0:
            raise Failure(err.strip() or 'no repository-pinned Node')
        env = dict(os.environ, PATH=f'{Path(out.strip()).parent}:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin')
        run([worktree / 'scripts/install-ci-tools.sh', 'xcodegen'], log, timeout=900, env=env, cwd=worktree)
        run(['npm', 'ci', '--no-audit', '--no-fund'], log, timeout=1200, env=env, cwd=worktree / 'packages/gateway')
        run([worktree / 'scripts/tron', 'mac', 'generate'], log, timeout=300, env=env, cwd=worktree)
        run(['xcodebuild', '-project', 'TronMac.xcodeproj', '-scheme', 'TronMac', '-configuration', 'Release',
             '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', 'build/DerivedData-Release', 'build'],
            log, timeout=3600, env=env, cwd=worktree / 'packages/mac-app')
        return self.built_app(revision)

    def built_app(self, revision):
        return self.build_root(revision) / 'packages/mac-app/build/DerivedData-Release/Build/Products/Release/Tron.app'

    def codesign_identity(self, app, log=None):
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app], log, timeout=600)
        _, out, err = capture(['/usr/bin/codesign', '-d', '--verbose=4', app])
        text = out + err
        team = re.search(r'^TeamIdentifier=(\S+)$', text, re.M)
        cdhash = re.search(r'^CDHash=([a-f0-9]+)$', text, re.M)
        if not cdhash:
            raise Failure(f'{app} has no code directory hash')
        return {'team': team[1] if team else 'not set', 'cdhash': cdhash[1]}

    def verify_artifact(self, app, revision, log):
        identity = self.codesign_identity(app, log)
        installed = self.codesign_identity(self.installed)
        if identity['team'] != installed['team'] or identity['team'] == 'not set':
            raise Failure(f'candidate team {identity["team"]} differs from installed team {installed["team"]}')
        env = dict(os.environ, TRON_APP_PATH=str(app))
        run(['/bin/bash', self.build_root(revision) / 'scripts/verify-mac-install.sh', '--artifact-only'], log, timeout=900, env=env)
        return identity

    def verify_installed(self, revision, log):
        run([self.build_root(revision) / 'scripts/verify-mac-install.sh', '--require-bundled'], log, timeout=900,
            env=dict(os.environ, TRON_APP_PATH=str(self.installed)))

    def replace_app_bytes(self, candidate, destination, log):
        run(['/usr/bin/ditto', candidate, destination], log, timeout=900)
