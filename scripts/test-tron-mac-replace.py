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
  2. failure after the swap: the new Gateway never answers; the old app is restored automatically.
  3. resumed retry: the same operation reruns, reuses the verified build, and succeeds.
  4. the plan then reports nothing to do.

Run: python3 scripts/test-tron-mac-replace.py   (writes test-results/mac-replace-e2e.json)
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
                       'CFBundlePackageType': 'APPL'}, stream)
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
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            self.port = probe.getsockname()[1]
        # A clean source checkout at this commit: the orchestrator refuses dirty sources.
        self.source = self.root / 'source'
        subprocess.run(['git', '-C', REPO, 'worktree', 'add', '--detach', '--quiet', self.source, 'HEAD'], check=True)
        self.revision = capture(['git', '-C', self.source, 'rev-parse', 'HEAD'])[1].strip()
        self.old_revision = capture(['git', '-C', self.source, 'rev-parse', 'HEAD~1'])[1].strip()
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
                               'TRON_MACHINE_GROUP_ID': 'tron-mac-replace-e2e', 'TRON_GATEWAY_HOST': '127.0.0.1',
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
        if hasattr(self, 'source'):
            subprocess.run(['git', '-C', REPO, 'worktree', 'remove', '--force', self.source], capture_output=True)
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
        (platform.maintenance).mkdir(parents=True, exist_ok=True)
        (platform.maintenance / 'active.json').write_text('{"schema":1,"id":"x"}')
        operation, outcome = fixture.start()
        data = fixture.wait_settled(operation)
        check(data['path'] == 'full' and 'dependency lock changed' in data['reason'], 'plan picks the full path for a lock change', evidence)
        check(data['state'] == 'failed' and data['error']['step'] == 'preflight', 'preflight failure stops at preflight', evidence)
        check('reinstall' in data['error']['message'] and data['error']['log'].endswith('logs/preflight.log'), 'preflight error is exact with its log path', evidence)
        check(not (platform.store / 'builds').exists(), 'nothing was built after a failed preflight', evidence)
        check(platform.system_info()['sourceRevision'] == fixture.old_revision, 'the old Gateway kept running', evidence)
        check(data['notification']['state'] == 'requested', 'the failure was pushed through the running Gateway', evidence)
        (platform.maintenance / 'active.json').unlink()

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
        check(data['state'] == 'succeeded' and data['attempt'] == 4, 'the resumed retry succeeds', evidence)
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
    if os.environ.get('TRON_HEAVY_LEASE_HELD') is None:
        os.execvp('python3', ['python3', str(REPO / 'tools/work/heavy.py'), 'run', '--owner', f'mac replace E2E in {REPO.name}',
                              '--', sys.executable, __file__])
    sys.exit(journeys())
