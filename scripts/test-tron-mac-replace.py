#!/usr/bin/env python3
"""Real-boundary E2E for `scripts/tron mac replace` (#984).

Drives the real orchestrator, detached under launchd exactly as on the Mac,
against a fixture install that never touches Stable: an ad-hoc-signed fixture
`Tron.app` whose launcher runs this worktree's built Gateway as a launchd job
(supervised, so `gateway.stop` is the real drain-and-stop) on a private port and
home. The fixture platform replaces only what needs a real Release install
(Xcode build, Developer ID team, the menu-bar app).

Journeys, in order, on one fixture:
  1. failing preflight: an active manual reinstall stops it at preflight; nothing changes.
  2. interrupted completed stop resumes offline without replaying worker stops.
  3. partial app copy fails, cleans staging, and restores the previous app.
  4. failure after the swap: the new Gateway never answers; the old app is restored automatically.
  5. resumed post-swap retry reuses the verified build and succeeds.
  6. the plan then reports nothing to do.

Run: python3 scripts/test-tron-mac-replace.py   (writes test-results/mac-replace-e2e.json)
RPC boundary only: python3 scripts/test-tron-mac-replace.py --rpc-only
(writes test-results/mac-replace-rpc-e2e.json; no build, app or launchd effects).
AppKit handoff only: --quit-only (writes test-results/mac-replace-quit-e2e.json;
compiles a standalone app using the production termination/handoff owners).
The full command runs all three journeys.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import tron_mac_replace as replace  # noqa: E402
from tron_mac_replace_platform import Failure, MacPlatform, capture, run  # noqa: E402
from tron_mac_replace_journal import write_json_atomic  # noqa: E402

REPO = HERE.parent


class FixturePlatform(MacPlatform):
    quit_timeout = 120
    start_timeout = 45

    def __init__(self, config_path):
        self.config_path = Path(config_path)
        self.config = json.loads(self.config_path.read_text())
        super().__init__(self.config['home'])
        self.installed = Path(self.config['installed'])
        self.gateway_label = self.config['label']
        self.helper_label = self.config['label'] + '.helper'
        self.bundle_id = 'com.tron.mac.e2e'
        self.port = self.config['port']

    def admit(self):
        pass

    def runner_files(self):
        return ('test-tron-mac-replace.py',)

    def runner_entry(self):
        return 'test-tron-mac-replace.py'

    def runner_arguments(self):
        return ['--fixture', str(self.config_path)]

    def node(self):
        return Path(self.config['node']), Path(self.config['repo']) / 'packages/gateway/node_modules'

    def protocol(self):
        return int(json.loads((self.bundled_gateway(self.installed) / 'manifest.json').read_text())['protocolVersion'])

    def app_running(self):
        return self.launchd_state(self.gateway_label) == 'running'

    def quit_app(self, log):
        # The fixture "app" is its Gateway job: the same authenticated
        # supervised stop the menu-bar Quit sends. A crash-looping Gateway has
        # nothing to drain, so its job is unloaded instead.
        try:
            self.mutation('gateway.stop', timeout=30)
        except replace.RpcError:
            capture(['/bin/launchctl', 'bootout', f'gui/{os.getuid()}/{self.gateway_label}'], timeout=30)

    def launch_app(self, log):
        # Reload the stopped (or crash-looping) job so RunAtLoad starts the installed bundle.
        capture(['/bin/launchctl', 'bootout', f'gui/{os.getuid()}/{self.gateway_label}'], timeout=30)
        for _ in range(100):  # bootout completes asynchronously
            if self.launchd_state(self.gateway_label) == 'absent':
                break
            time.sleep(0.2)
        run(['/bin/launchctl', 'bootstrap', f'gui/{os.getuid()}', self.config['plist']], log, timeout=30)

    def offline_blocker(self):
        if (Path(self.config['root']) / 'hold-after-stop').exists() and self.gateway_pid() is None:
            return 'fixture holds runner after actual Gateway retirement'
        return super().offline_blocker()

    def helper_state(self):
        return self.launchd_state(self.gateway_label), 'stopped'

    def signing_identities(self):
        return 1

    def build(self, source_root, revision, log):
        counter = Path(self.config['root']) / 'build-count'
        counter.write_text(str(int(counter.read_text() if counter.exists() else '0') + 1))
        app = self.built_app(revision)
        if app.exists():
            shutil.rmtree(app)
        app.parent.mkdir(parents=True, exist_ok=True)
        make_app(app, revision, (Path(self.config['repo']) / 'packages/gateway/package-lock.json').read_bytes(), self.config)
        return app

    def built_app(self, revision):
        return self.store / 'builds' / revision / 'Tron.app'

    def verify_artifact(self, app, revision, log):
        return self.codesign_identity(app, log)

    def verify_installed(self, revision, log):
        self.codesign_identity(self.installed, log)

    def replace_app_bytes(self, candidate, destination, log):
        if (Path(self.config['root']) / 'fail-copy').exists():
            destination.mkdir()
            (destination / 'partial').write_text('incomplete app')
            raise Failure('fixture app copy failed')
        super().replace_app_bytes(candidate, destination, log)


LAUNCHER = """#!/bin/bash
# Fixture launcher: runs the repository Gateway with this bundle's identity.
here="$(cd "$(dirname "$0")/.." && pwd)"
revision="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sourceRevision"])' "$here/Resources/Gateway/manifest.json")"
[[ -e "$FIXTURE_ROOT/fail-start-$revision" ]] && { echo "fixture: refusing to start $revision" >&2; exit 1; }
export TRON_GATEWAY_SOURCE_REVISION="$revision"
# The fixture payload root names this bundle; the Gateway runs from the
# repository build, so the payload-runtime contract stays inactive.
export TRON_GATEWAY_PAYLOAD_ROOT="$here/Resources/Gateway"
exec "$FIXTURE_NODE" "$FIXTURE_GATEWAY/dist/index.js"
"""


def make_app(app, revision, lock, config):
    gateway = app / 'Contents/Resources/Gateway'
    (app / 'Contents/MacOS').mkdir(parents=True)
    (gateway / 'app').mkdir(parents=True)
    with (app / 'Contents/Info.plist').open('wb') as stream:
        plistlib.dump({'CFBundleIdentifier': 'com.tron.mac.e2e', 'CFBundleExecutable': 'launch',
                       'CFBundlePackageType': 'APPL', 'TronReplacementQuitVersion': 1}, stream)
    launcher = app / 'Contents/MacOS/launch'
    launcher.write_text(LAUNCHER)
    launcher.chmod(0o755)
    repo = Path(config['repo'])
    protocol, minimum = replace.source_protocol(repo)
    (gateway / 'manifest.json').write_text(json.dumps({'sourceRevision': revision, 'protocolVersion': str(protocol),
                                                       'minProtocolVersion': str(minimum)}))
    (gateway / 'app/package-lock.json').write_bytes(lock)
    (gateway / 'app/dist').mkdir()
    (gateway / 'app/dist/index.js').write_text('// fixture payload placeholder\n')
    shutil.copy2(repo / 'packages/gateway/package.json', gateway / 'app/package.json')
    subprocess.run(['/usr/bin/codesign', '-s', '-', '--force', '--deep', app], check=True, capture_output=True)


class Fixture:
    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix='tron-mac-replace-e2e-')).resolve()
        self.home = self.root / 'home'
        self.label = f'com.tron.e2e.mac-replace.{os.getpid()}'
        self.node = Path(subprocess.run([REPO / 'scripts/tron-node'], check=True, capture_output=True, text=True).stdout.strip())
        # The fixture Gateway binds IPv6 loopback, not 127.0.0.1: like live Stable
        # (bound to its Tailscale address, #1059), the runner must reach the
        # listener the Gateway job actually holds rather than an assumed one.
        self.host = '::1'
        with socket.socket(socket.AF_INET6) as probe:
            probe.bind((self.host, 0))
            self.port = probe.getsockname()[1]
        # Isolate Git state as well as files: a worktree would inherit the real
        # checkout and could redirect this fixture's source revision.
        self.source = self.root / 'source'
        self.revision = capture(['git', '-C', REPO, 'rev-parse', 'HEAD'])[1].strip()
        subprocess.run(['git', 'clone', '--shared', '--no-checkout', '--quiet', REPO, self.source], check=True)
        subprocess.run(['git', '-C', self.source, 'checkout', '--quiet', '-b', 'fixture-source', self.revision], check=True)
        # Own the remote main too: concurrent workers may advance the real repo.
        # Planning must choose this main, not the caller's unpublished/dirty bytes.
        remote = self.root / 'remote.git'
        subprocess.run(['git', 'init', '--bare', '--quiet', remote], check=True)
        subprocess.run(['git', '-C', self.source, 'remote', 'set-url', 'origin', remote], check=True)
        subprocess.run(['git', '-C', self.source, 'push', '--quiet', 'origin', 'HEAD:main'], check=True)
        subprocess.run(['git', '-C', self.source, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@invalid',
                        'commit', '--quiet', '--allow-empty', '-m', 'unpublished worker change'], check=True)
        (self.source / 'README.md').write_text('uncommitted caller bytes, not the build source\n')
        self.old_revision = capture(['git', '-C', self.source, 'rev-parse', f'{self.revision}~1'])[1].strip()
        (self.home / '.tron/gateway').mkdir(parents=True)
        (self.home / '.tron/gateway/gateway.json').write_text(json.dumps({'version': 1, 'machineId': 'tron-mac-replace-e2e', 'machineName': 'Replace E2E'}))
        for path in (self.home, self.home / '.tron', self.home / '.tron/gateway'):
            path.chmod(0o700)
        (self.home / '.tron/gateway/gateway.json').chmod(0o600)
        self.installed = self.home / 'Applications/Tron.app'
        self.config_path = self.root / 'fixture.json'
        self.config = {'root': str(self.root), 'home': str(self.home), 'installed': str(self.installed), 'label': self.label,
                       'port': self.port, 'node': str(self.node), 'repo': str(REPO), 'plist': str(self.root / 'gateway.plist')}
        self.config_path.write_text(json.dumps(self.config))
        # The installed "old" app: an older revision with a different lock, so the plan is a full replacement.
        make_app(self.installed, self.old_revision, b'{"lockfileVersion": 3, "fixture": "old"}\n', self.config)
        plist = self.root / 'gateway.plist'
        with plist.open('wb') as stream:
            plistlib.dump({'Label': self.label, 'ProgramArguments': [str(self.installed / 'Contents/MacOS/launch')],
                           'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 1,
                           'StandardOutPath': str(self.root / 'gateway.log'), 'StandardErrorPath': str(self.root / 'gateway.log'),
                           'EnvironmentVariables': {
                               'PATH': f'{self.node.parent}:/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(self.home),
                               'TRON_DATA_DIR': str(self.home / '.tron'), 'PI_CODING_AGENT_DIR': str(self.home / '.tron/agent'),
                               'PI_SUBAGENTS_TEMP_ROOT': str(self.home / '.tron/internal/subagents'),
                               'TRON_MACHINE_GROUP_ID': 'tron-mac-replace-e2e', 'TRON_GATEWAY_HOST': self.host,
                               'TRON_GATEWAY_PORT': str(self.port), 'TRON_GATEWAY_SUPERVISED': '1', 'TRON_GATEWAY_CHANNEL': 'stable',
                               'FIXTURE_ROOT': str(self.root), 'FIXTURE_NODE': str(self.node),
                               'FIXTURE_GATEWAY': str(REPO / 'packages/gateway')}}, stream)
        subprocess.run(['/bin/launchctl', 'bootstrap', f'gui/{os.getuid()}', plist], check=True)
        self.platform = FixturePlatform(self.config_path)
        self.wait_revision(self.old_revision)

    def wait_revision(self, revision, timeout=90):
        deadline, last = time.monotonic() + timeout, None
        while time.monotonic() < deadline:
            try:
                last = self.platform.system_info().get('sourceRevision')
                if last == revision:
                    return
            except Exception as error:  # noqa: BLE001 - not up yet
                last = error
            time.sleep(1)
        log = (self.root / 'gateway.log').read_text()[-2000:] if (self.root / 'gateway.log').exists() else ''
        raise AssertionError(f'fixture Gateway did not report {revision} (last: {last})\n{log}')

    def start(self):
        journal, outcome = replace.start(self.platform, self.source, script_dir=HERE)
        return journal.data['id'], outcome

    def wait_settled(self, operation, timeout=400):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            data = replace.Journal(self.platform.store / operation).load().data
            if data['state'] in replace.TERMINAL_STATES:
                return data
            time.sleep(1)
        raise AssertionError(f'operation {operation} did not settle; see {self.platform.store / operation}')

    def status_text(self):
        return subprocess.run([sys.executable, HERE / 'test-tron-mac-replace.py', '--fixture', self.config_path, '--status'],
                              capture_output=True, text=True).stdout

    def close(self):
        labels = [self.label] if hasattr(self, 'label') else []
        if hasattr(self, 'platform') and self.platform.store.exists():
            labels += [replace.runner_label(entry.name) for entry in self.platform.store.iterdir() if (entry / 'journal.json').exists()]
        for label in labels:
            capture(['/bin/launchctl', 'bootout', f'gui/{os.getuid()}/{label}'], timeout=30)
        if hasattr(self, 'root'):
            shutil.rmtree(self.root, ignore_errors=True)


def check(condition, message, evidence):
    evidence.append({'check': message, 'pass': bool(condition)})
    if not condition:
        raise AssertionError(message)


def journeys():
    evidence, fixture = [], Fixture.__new__(Fixture)
    try:
        fixture.__init__()
    except BaseException:
        fixture.close()
        raise
    report = REPO / 'test-results/mac-replace-e2e.json'
    started = time.time()
    try:
        platform = fixture.platform
        # 1. Failing preflight: a manual reinstall operation is active.
        (platform.maintenance).mkdir(mode=0o700, parents=True, exist_ok=True)
        (platform.maintenance / 'active.json').write_text('{"schema":1,"id":"x"}')
        operation, outcome = fixture.start()
        data = fixture.wait_settled(operation)
        check(data['path'] == 'full' and 'dependency lock changed' in data['reason'], 'plan picks the full path for a lock change', evidence)
        check(data['source']['revision'] == fixture.revision and data['source']['head'] != fixture.revision,
              'plan selects fetched origin/main without receipts despite unpublished dirty caller changes', evidence)
        check(data['state'] == 'failed' and data['error']['step'] == 'preflight', 'preflight failure stops at preflight', evidence)
        check('reinstall' in data['error']['message'] and data['error']['log'].endswith('logs/preflight.log'), 'preflight error is exact with its log path', evidence)
        check(not (platform.store / 'builds').exists(), 'nothing was built after a failed preflight', evidence)
        check(platform.system_info()['sourceRevision'] == fixture.old_revision, 'the old Gateway kept running', evidence)
        check(platform.endpoint == f'ws://[::1]:{fixture.port}/v1/socket',
              'the runner reaches the listener the Gateway job holds, not an assumed 127.0.0.1', evidence)
        check(data['notification']['state'] == 'requested', 'the failure was pushed through the running Gateway', evidence)
        (platform.maintenance / 'active.json').unlink()

        # Partial-copy failure restores the old app and cleans only owned staging.
        (fixture.root / 'fail-copy').write_text('')
        (fixture.root / 'hold-after-stop').write_text('')
        retry_operation, outcome = fixture.start()
        journal = replace.Journal(platform.store / operation)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            data = journal.load().data
            if data['currentStep'] == 'stop-gateway' and platform.gateway_pid() is None:
                break
            time.sleep(0.1)
        check(data['currentStep'] == 'stop-gateway' and platform.gateway_pid() is None,
              'runner reached actual Gateway retirement before swap', evidence)
        capture(['/bin/launchctl', 'bootout', f'gui/{os.getuid()}/{replace.runner_label(operation)}'], timeout=30)
        for _ in range(50):
            if platform.launchd_state(replace.runner_label(operation)) == 'absent':
                break
            time.sleep(0.2)
        (fixture.root / 'hold-after-stop').unlink()
        retry_operation, outcome = fixture.start()
        check(outcome == 'resuming interrupted', 'interrupted pre-swap stop resumes without a live Gateway', evidence)
        data = fixture.wait_settled(operation)
        check('already retired' in next(step['detail'] for step in data['steps'] if step['name'] == 'drain-workers'),
              'offline retry preserves worker records instead of replaying stops against closed transport', evidence)
        check(data['state'] == 'rolled-back' and data['error']['step'] == 'swap-app',
              'partial app copy fails at its real swap boundary and rolls back', evidence)
        check(not platform.installed.with_name('.Tron.app.replacing').exists(),
              'partial staging app is removed after failed copy', evidence)
        check(platform.system_info()['sourceRevision'] == fixture.old_revision,
              'partial-copy rollback restores the previous Gateway', evidence)
        (fixture.root / 'fail-copy').unlink()

        # 2. Failure after the swap: the new Gateway refuses to start; automatic rollback.
        (fixture.root / f'fail-start-{fixture.revision}').write_text('')
        retry_operation, outcome = fixture.start()
        check(retry_operation == operation and outcome == 'retrying', 'a retry reuses the failed operation', evidence)
        data = fixture.wait_settled(operation)
        check(data['state'] == 'rolled-back' and data['error']['step'] == 'start', 'a failed start after the swap rolls back', evidence)
        check(data['rollback']['state'] == 'restored', 'rollback restored and verified the previous app', evidence)
        check(platform.system_info()['sourceRevision'] == fixture.old_revision, 'the previous Gateway runs again', evidence)
        manifest = json.loads((platform.bundled_gateway(platform.installed) / 'manifest.json').read_text())
        check(manifest['sourceRevision'] == fixture.old_revision, 'the previous app bundle is back in place', evidence)
        check(Path(data['swap']['snapshot']).is_dir(), 'the ~/.tron snapshot rollback point is kept', evidence)
        status = fixture.status_text()
        check('rolled-back' in status and 'logs/start.log' in status, 'terminal status shows the failure and its log', evidence)
        check((fixture.root / 'build-count').read_text() == '1', 'built once', evidence)

        # 3. The runner dies after the swap (crash or reboot); the resumed retry first restores
        # the previous app, then reuses the verified build and succeeds.
        retry_operation, outcome = fixture.start()
        check(retry_operation == operation and outcome == 'retrying', 'the second retry reuses the operation', evidence)
        journal = replace.Journal(platform.store / operation)
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            data = journal.load().data
            if data['currentStep'] == 'start' and data['swap'].get('previousApp'):
                break
            time.sleep(0.5)
        check(data['currentStep'] == 'start', 'the retry reached the new app start', evidence)
        capture(['/bin/launchctl', 'bootout', f'gui/{os.getuid()}/{replace.runner_label(operation)}'], timeout=30)
        for _ in range(50):
            if platform.launchd_state(replace.runner_label(operation)) == 'absent':
                break
            time.sleep(0.2)
        check(journal.load().data['state'] == 'running', 'a killed runner leaves the attempt unsettled', evidence)
        (fixture.root / f'fail-start-{fixture.revision}').unlink()
        retry_operation, outcome = fixture.start()
        check(retry_operation == operation and outcome == 'resuming interrupted', 'start resumes the interrupted operation', evidence)
        data = fixture.wait_settled(operation)
        log = journal.log_path.read_text()
        check('restoring the previous app first' in log, 'the resumed runner restored the previous app before retrying', evidence)
        check(data['state'] == 'succeeded' and data['attempt'] == 6, 'the resumed retry succeeds', evidence)
        check((fixture.root / 'build-count').read_text() == '1', 'the verified build was reused, not rebuilt', evidence)
        check(platform.system_info()['sourceRevision'] == fixture.revision, 'the new Gateway runs the source revision', evidence)
        check(platform.codesign_identity(platform.installed)['cdhash'] == data['artifact']['cdhash'], 'the installed app is the verified artifact', evidence)
        check(data['result']['revision'] == fixture.revision and data['notification']['state'] == 'requested', 'result verified and pushed', evidence)
        timings = [step for step in data['steps'] if step['state'] == 'done' and step.get('durationSeconds') is not None]
        check(len(timings) >= 6, 'every live step records its timing', evidence)
        status = platform.rpc('mac.replace.status')
        check(status['operation']['id'] == operation and status['operation']['state'] == 'succeeded', 'the new Gateway projects the full journal', evidence)

        # 4. Nothing left to do.
        check(replace.plan(platform, fixture.source)['path'] == 'none', 'the plan then reports nothing to do', evidence)
        passed = True
    except Exception as error:  # noqa: BLE001
        evidence.append({'check': 'error', 'pass': False, 'detail': f'{type(error).__name__}: {error}'})
        passed = False
        if hasattr(fixture, 'platform') and (fixture.platform.store / 'current.json').exists():
            data = replace.current_journal(fixture.platform).data; print(json.dumps({key: data.get(key) for key in ('state', 'error', 'rollback', 'swap')}, indent=1), file=sys.stderr)
        for path in sorted(fixture.platform.store.rglob('*.log')) if fixture.platform.store.exists() else []:
            print(f'--- {path}\n{path.read_text()[-3000:]}', file=sys.stderr)
        print(f'--- gateway.log\n{(fixture.root / "gateway.log").read_text()[-3000:] if (fixture.root / "gateway.log").exists() else ""}', file=sys.stderr)
    finally:
        fixture.close()
    report.parent.mkdir(exist_ok=True)
    report.write_text(json.dumps({'passed': passed, 'seconds': round(time.time() - started, 1), 'checks': evidence}, indent=1) + '\n')
    for item in evidence:
        print(f'{"PASS" if item["pass"] else "FAIL"}  {item["check"]}{" - " + item["detail"] if "detail" in item else ""}')
    print(f'report: {report}')
    return 0 if passed else 1


def quit_journey():
    """Real AppKit + production replacement handoff; no installed app/services."""
    evidence, passed = [], False
    report = REPO / 'test-results/mac-replace-quit-e2e.json'
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix='tron-replacement-quit-') as temporary:
        root = Path(temporary)
        platform = MacPlatform(root / 'home')
        platform.home.mkdir()
        platform.installed = root / 'Fixture.app'
        platform.bundle_id = f'com.tron.test.replacement-quit.{os.getpid()}'
        platform.gateway_label = platform.bundle_id + '.gateway'
        platform.helper_label = platform.bundle_id + '.helper'
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); platform.port = sock.getsockname()[1]
        contents = platform.installed / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        binary = contents / 'MacOS/probe'
        info = contents / 'Info.plist'
        info.write_bytes(plistlib.dumps({'CFBundleIdentifier': platform.bundle_id, 'CFBundleExecutable': 'probe',
                                        'CFBundlePackageType': 'APPL', 'TronReplacementQuitVersion': 1}))
        mac = REPO / 'packages/mac-app'
        run(['/usr/bin/xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
             mac / 'Sources/App/Lifecycle/ApplicationTermination.swift',
             mac / 'Sources/App/Lifecycle/MacReplacementQuit.swift',
             mac / 'Sources/Support/AtomicFileWriter.swift',
             mac / 'scripts/fixtures/AppKitTerminationProbe.swift', '-o', binary], root / 'compile.log', timeout=60)
        output = root / 'app.log'
        process = None
        try:
            with output.open('w') as stream:
                process = subprocess.Popen([binary, 'replacement-failure', platform.quit_directory],
                                           stdout=stream, stderr=stream,
                                           env=dict(os.environ, HOME=str(platform.home), TMPDIR=str(root)))
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and 'application-ready' not in output.read_text():
                time.sleep(0.05)
            check('application-ready' in output.read_text(), 'isolated AppKit app launched', evidence)
            check(platform.app_identity()['pid'] == process.pid, 'runner pins the actual AppKit wrapper identity', evidence)
            # A stale result cannot fail or satisfy a new request.
            platform.quit_app(root / 'quit.log')
            first = platform.quit_request()
            deadline = time.monotonic() + 5
            refused = None
            while time.monotonic() < deadline:
                try:
                    platform.quit_progress()
                except Failure as error:
                    refused = str(error); break
                time.sleep(0.05)
            check(refused is not None and 'Quit refused' in refused,
                  'replacement receives an actionable failure immediately, not a 45-minute wait', evidence)
            check(process.poll() is None and 'ordinary-modal-would-open' not in output.read_text(),
                  'replacement failure cancels AppKit termination without opening ordinary-Quit modal', evidence)
            check(platform.offline_blocker() is not None, 'live captured app forbids replacement', evidence)
            # Retry the same live app. This is a new nonce; the failed predecessor
            # result must not poison it. No app restart or manual Quit is involved.
            platform.quit_app(root / 'quit.log')
            check(platform.quit_request()['id'] != first['id'], 'retry gets a fresh exact-app request', evidence)
            platform.quit_progress()
            process.wait(timeout=10)
            check(process.returncode == 0, 'successful retry completes real deferred AppKit termination', evidence)
            check(platform.quit_progress() == 'Gateway and native helper retired; app exiting',
                  'runner observes the exact successful receipt', evidence)
            check(platform.offline_blocker() is None, 'offline requires captured processes, app, services and listeners gone', evidence)
            result_path = platform.quit_directory / 'result.json'
            late = json.loads(result_path.read_text())
            result_path.write_text('{malformed')
            try:
                platform.quit_progress()
                check(False, 'malformed handoff must refuse progress', evidence)
            except Failure as error:
                check('malformed' in str(error), 'malformed handoff is an actionable bounded failure', evidence)
            result_path.unlink()
            foreign = root / 'foreign-result.json'
            foreign.write_text(json.dumps(late))
            result_path.symlink_to(foreign)
            try:
                platform.quit_progress()
                check(False, 'symlinked handoff must refuse progress', evidence)
            except Failure:
                check(json.loads(foreign.read_text()) == late, 'symlinked handoff is refused without touching its target', evidence)
            result_path.unlink()
            late.update(state='failed', detail='prior bounded observation timed out')
            write_json_atomic(platform.quit_directory / 'result.json', late)
            platform.quit_app(root / 'quit.log')
            check(not (platform.quit_directory / 'request.json').exists() and not (platform.quit_directory / 'result.json').exists(),
                  'explicit retry after late retirement clears stale failure only after independent offline proof', evidence)
            # An interrupted/restarted runner must join the pending Quit rather
            # than invalidate the nonce whose receipt AppKit will eventually send.
            with output.open('w') as stream:
                process = subprocess.Popen([binary, 'replacement', platform.quit_directory], stdout=stream, stderr=stream,
                                           env=dict(os.environ, HOME=str(platform.home), TMPDIR=str(root)))
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and 'application-ready' not in output.read_text():
                time.sleep(0.05)
            platform.quit_app(root / 'quit.log')
            pending = platform.quit_request()
            platform.quit_app(root / 'quit.log')
            check(platform.quit_request()['id'] == pending['id'],
                  'repeated replacement joins the in-flight exact-app Quit receipt', evidence)
            process.wait(timeout=10)
            check(process.returncode == 0 and platform.quit_progress() == 'Gateway and native helper retired; app exiting',
                  'joined replacement receives eventual success with no manual Quit', evidence)
            platform.clear_quit_request()
            # Old app adoption is explicit, not a legacy ordinary-Quit fallback.
            info.write_bytes(plistlib.dumps({'CFBundleIdentifier': platform.bundle_id}))
            try:
                platform.require_replacement_quit()
                check(False, 'old wrapper must refuse unattended replacement', evidence)
            except Failure as error:
                check('install the prepared fixed Release app once' in str(error),
                      'old wrapper gets precise maintainer adoption requirement before effects', evidence)
            passed = True
        except Exception as error:
            evidence.append({'check': 'error', 'pass': False, 'detail': f'{type(error).__name__}: {error}'})
            print(output.read_text() if output.exists() else '', file=sys.stderr)
            quit_log = root / 'quit.log'
            if quit_log.exists():
                evidence.append({'check': 'Quit diagnostics', 'pass': False, 'detail': quit_log.read_text()})
                print(quit_log.read_text(), file=sys.stderr)
        finally:
            if process is not None and process.poll() is None:
                # Only this test-created AppKit subprocess, never a live Tron app.
                process.kill(); process.wait()
    report.parent.mkdir(exist_ok=True)
    report.write_text(json.dumps({'passed': passed, 'seconds': round(time.monotonic() - started, 1), 'checks': evidence}, indent=1) + '\n')
    for item in evidence:
        print(f'{"PASS" if item["pass"] else "FAIL"}  {item["check"]}{" - " + item["detail"] if "detail" in item else ""}')
    print(f'report: {report}')
    return 0 if passed else 1


RPC_RESPONDER = r'''
const { WebSocketServer } = require("ws");
const fs = require("node:fs");
const server = new WebSocketServer({ host: "127.0.0.1", port: 0 });
server.on("listening", () => console.log(server.address().port));
server.on("connection", (ws, request) => {
  if (request.headers.authorization !== "Bearer fixture-token") return ws.close(1008, "bad token");
  ws.on("message", raw => {
    const frame = JSON.parse(raw);
    if (frame.type === "hello" && frame.protocolVersion === 8) {
      return ws.send(JSON.stringify({ type: "hello", protocolVersion: 8, minProtocolVersion: 8 }));
    }
    fs.appendFileSync(process.argv[1], frame.method + "\n");
    if (frame.type !== "request" || frame.method !== "home.taskList") return ws.close(1008, "unexpected request");
    const scenario = frame.params.scenario;
    if (scenario === "closed") return ws.close(1008, "fixture refused request");
    if (scenario === "timeout") return;
    if (scenario === "handshake-error") return ws.send(JSON.stringify({ type: "error", error: { code: "unauthorized", message: "fixture handshake refused" } }));
    if (scenario === "error") return ws.send(JSON.stringify({ type: "response", id: frame.id, ok: false, error: { code: "conflict", message: "fixture task list refused" } }));
    // The installed protocol-8 Gateway returns history even when nothing is
    // active. Make stdout backpressure inevitable, including multibyte text.
    const items = Array.from({ length: 50 }, (_, i) => ({ taskId: `task-${i}`, sessionId: `session-${i}`,
      lifecycle: "terminal", title: "history 🦊 ".repeat(4096) + `tail-${i}` }));
    ws.send(JSON.stringify({ type: "response", id: frame.id, ok: true,
      result: { items, counts: { active: 0, finished: 50 } } }));
  });
});
'''


def rpc_journey():
    """Real Node child/stdout pipe and protocol-8 socket, never the live install."""
    evidence, started, passed = [], time.time(), False
    report = REPO / 'test-results/mac-replace-rpc-e2e.json'
    try:
        with tempfile.TemporaryDirectory(prefix='tron-mac-replace-rpc-') as directory:
            root = Path(directory)
            home, temporary = root / 'home', root / 'tmp'
            home.mkdir()
            temporary.mkdir()
            node = Path(capture([REPO / 'scripts/tron-node'])[1].strip())
            modules = REPO / 'packages/gateway/node_modules'
            calls = root / 'calls'
            env = dict(os.environ, HOME=str(home), TMPDIR=str(temporary), NODE_PATH=str(modules))
            with (root / 'server.log').open('w') as log:
                server = subprocess.Popen([node, '-e', RPC_RESPONDER, str(calls)], env=env,
                                          stdout=subprocess.PIPE, stderr=log, text=True)
                try:
                    import select
                    ready, _, _ = select.select([server.stdout], [], [], 10)
                    check(bool(ready), 'fixture socket starts within 10 seconds', evidence)
                    port = int(server.stdout.readline().strip())

                    class RpcPlatform(MacPlatform):
                        def node(self):
                            return node, modules

                        def token(self):
                            return 'fixture-token'

                        def protocol(self):
                            return 8  # The installed Gateway's contract, not current-source handlers.

                        def endpoints(self):
                            return [f'ws://127.0.0.1:{port}/v1/socket']

                    platform = RpcPlatform(home)
                    page = platform.rpc('home.taskList', {'limit': 50})
                    check(len(page['items']) == 50 and all(item['title'] == 'history 🦊 ' * 4096 + f'tail-{i}'
                          for i, item in enumerate(page['items'])),
                          'large task history survives the child stdout pipe intact, including its tail and Unicode', evidence)
                    journal = replace.Journal.create(root / 'operation', 'fixture', 'full', 'RPC regression', {})
                    detail = replace.Runner(platform, journal).step_drain_workers()
                    check(detail == 'no running workers' and journal.load().data['workers'] == [],
                          'terminal history succeeds as nothing to stop against the old Gateway wire contract', evidence)
                    for scenario, code, message in (
                        ('error', 'conflict', 'fixture task list refused'),
                        ('handshake-error', 'unauthorized', 'fixture handshake refused'),
                        ('closed', 'connection-lost', '1008: fixture refused request'),
                        ('timeout', 'timeout', 'home.taskList timed out'),
                    ):
                        began = time.monotonic()
                        try:
                            platform.rpc('home.taskList', {'scenario': scenario}, timeout=5 if scenario == 'closed' else 0.5)
                        except replace.RpcError as error:
                            check(error.code == code and message in error.message,
                                  f'{scenario} reports its exact cause, not no response: {error}', evidence)
                        else:
                            check(False, f'{scenario} must refuse', evidence)
                        if scenario == 'closed':
                            check(time.monotonic() - began < 3, 'socket closure is reported without waiting for the request deadline', evidence)
                    check(calls.read_text().splitlines() == ['home.taskList'] * 6,
                          'the no-worker and diagnostic journeys never send a stop or any other method', evidence)
                    passed = True
                finally:
                    server.terminate()
                    try:
                        server.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait()
                    server.stdout.close()
    except Exception as error:  # noqa: BLE001 - retain RED evidence as well as GREEN.
        evidence.append({'check': 'error', 'pass': False, 'detail': f'{type(error).__name__}: {error}'})
    report.parent.mkdir(exist_ok=True)
    report.write_text(json.dumps({'passed': passed, 'seconds': round(time.time() - started, 1), 'checks': evidence}, indent=1) + '\n')
    for item in evidence:
        print(f'{"PASS" if item["pass"] else "FAIL"}  {item["check"]}{" - " + item["detail"] if "detail" in item else ""}')
    print(f'report: {report}')
    return 0 if passed else 1


def fixture_main():
    """`--fixture <config> ...`: the orchestrator CLI/runner against the fixture platform."""
    arguments = sys.argv[1:]
    index = arguments.index('--fixture')
    config = arguments[index + 1]
    del arguments[index:index + 2]
    return replace.main(lambda: FixturePlatform(config), arguments)


if __name__ == '__main__':
    if '--fixture' in sys.argv:
        sys.exit(fixture_main())
    if '--quit-only' in sys.argv:
        sys.exit(quit_journey())
    rpc_result = rpc_journey()
    if rpc_result or '--rpc-only' in sys.argv:
        sys.exit(rpc_result)
    if quit_journey():
        sys.exit(1)
    # The fixture launches dist/index.js. A fresh worktree has no dist, and a
    # warm one may have another source revision; never test that ambient build.
    print('Mac replacement E2E: verifying dependencies and building the current-source Gateway', flush=True)
    node = Path(subprocess.run([REPO / 'scripts/tron-node'], check=True, capture_output=True, text=True).stdout.strip())
    subprocess.run([node, REPO / 'scripts/gateway-install-inputs.mjs', 'ensure',
                    REPO / 'packages/gateway', node.parent], check=True, cwd=REPO)
    subprocess.run([REPO / 'scripts/tron-node', 'exec', 'npm', '--prefix',
                    REPO / 'packages/gateway', 'run', 'build'], check=True, cwd=REPO)
    sys.exit(journeys())
