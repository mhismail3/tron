#!/usr/bin/env python3
"""Replace the installed Mac app (Tron.app + bundled Gateway) in one tracked operation (#984).

    scripts/tron mac replace --plan [--json]      which path, and why
    scripts/tron mac replace --start [--json]     start or retry; runs detached under launchd
    scripts/tron mac replace --status [--follow] [--json]

The runner is a launchd job of its own, so it survives the Gateway and app it
replaces. It picks one path: a quick Gateway source rebuild when the active
payload's dependency lock, dependency manifest and protocol all still match and
the Mac app sources are unchanged; otherwise a full signed build and app swap.
Every attempt writes the step journal in `~/.tron-maintenance/replace/<id>/`.
A failure stops at its step with the exact error and log path; after the swap
it automatically restores the previous app. A retry reuses the verified build.
"""
import argparse
import ctypes
import fcntl
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tron_mac_replace_journal import Journal, TERMINAL_STATES, describe, now, private_mkdir  # noqa: E402
from tron_mac_replace_platform import Failure, MacPlatform, RpcError, capture, run  # noqa: E402

LIBC = ctypes.CDLL(None, use_errno=True)
DISK_RESERVE = {'full': 15 * 1024 ** 3, 'quick': 3 * 1024 ** 3}
WORKER_STOP_TIMEOUT = 10 * 60
RESUME_TEXT = ('The Mac app was replaced while this task ran, so it was stopped and preserved. '
               'Continue the task in place from where you left off.')


# Plan ----------------------------------------------------------------------

def git(root, *args):
    code, out, err = capture(['/usr/bin/git', '-C', root, *args], timeout=60)
    if code != 0:
        raise Failure(f'git {" ".join(args[:2])} failed in {root}: {err.strip()[:300]}')
    return out.strip()


def source_file(root, revision, path):
    """A source file at the revision being replaced (which may trail the checkout's HEAD)."""
    return git(root, 'show', f'{revision}:{path}')


def source_protocol(root, revision='HEAD'):
    text = source_file(root, revision, 'packages/gateway/src/version.ts')
    import re
    version = re.search(r'export const PROTOCOL_VERSION = (\d+);', text)
    minimum = re.search(r'export const MIN_PROTOCOL_VERSION = (\d+);', text)
    if not version or not minimum:
        raise Failure('cannot read the source Gateway protocol from packages/gateway/src/version.ts')
    return int(version[1]), int(minimum[1])


def dependency_manifest(package):
    return {key: package.get(key) for key in ('name', 'version', 'dependencies', 'optionalDependencies', 'overrides')}


def plan(platform, root):
    """Build the fetched origin/main revision, independent of local check history."""
    root = Path(root)
    git(root, 'fetch', '--no-tags', 'origin', 'refs/heads/main:refs/remotes/origin/main')
    head = git(root, 'rev-parse', 'HEAD')
    revision = git(root, 'rev-parse', 'origin/main')
    decided = _plan(platform, root, head, revision, '')
    if decided['path'] == 'quick' and (revision != head or git(root, 'status', '--porcelain', '--untracked-files=no')):
        # Quick rebuild compiles the checkout; use the detached full builder if
        # its bytes cannot represent the selected main revision.
        decided.update(path='full', reason=f'Full signed build of origin/main ({revision[:9]}): '
                       'the source checkout differs from the selected revision.')
    return decided


def _plan(platform, root, head, revision, warning):
    active = platform.active_payload()
    manifest = json.loads((active / 'manifest.json').read_text())
    bundled = json.loads((platform.bundled_gateway(platform.installed) / 'manifest.json').read_text())
    reasons = []
    if (active / 'app/package-lock.json').read_text().strip() != source_file(root, revision, 'packages/gateway/package-lock.json'):
        reasons.append('the Gateway dependency lock changed')
    active_package = json.loads((active / 'app/package.json').read_text())
    source_package = json.loads(source_file(root, revision, 'packages/gateway/package.json'))
    if dependency_manifest(active_package) != dependency_manifest(source_package):
        reasons.append('the Gateway dependency manifest changed')
    protocol, minimum = source_protocol(root, revision)
    if (str(protocol), str(minimum)) != (str(manifest.get('protocolVersion')), str(manifest.get('minProtocolVersion'))):
        reasons.append(f'the Gateway protocol changes {manifest.get("protocolVersion")} → {protocol}')
    app_revision = bundled.get('sourceRevision', '')
    code, _, _ = capture(['/usr/bin/git', '-C', root, 'cat-file', '-e', f'{app_revision}^{{commit}}'])
    if code != 0:
        reasons.append('the installed app was built from a revision this checkout does not have')
    else:
        code, _, _ = capture(['/usr/bin/git', '-C', root, 'diff', '--quiet', app_revision, revision, '--',
                              'packages/mac-app', ':(exclude)packages/mac-app/docs'])
        if code != 0:
            reasons.append(f'Mac app sources changed since the installed build ({app_revision[:9]})')
    running = manifest.get('sourceRevision', '')
    if reasons:
        path, reason = 'full', 'Full signed build: ' + '; '.join(reasons)
    elif running == revision:
        path, reason = 'none', f'Already running {revision[:9]}'
    else:
        path, reason = 'quick', 'Quick rebuild: dependency lock, protocol and Mac app sources are unchanged'
    if warning:
        reason = f'{reason}. Warning: {warning}'
    return {'path': path, 'reason': reason, 'revision': revision, 'head': head, 'root': str(root),
            'running': running, 'appRevision': app_revision, 'protocol': protocol, 'warning': warning}


# Runner --------------------------------------------------------------------

class Runner:
    def __init__(self, platform, journal):
        self.platform, self.journal = platform, journal
        self.data = journal.data

    @property
    def revision(self):
        return self.data['source']['revision']

    @property
    def root(self):
        return Path(self.data['source']['root'])

    def log(self, step):
        return self.journal.step_log(step)

    def run(self):
        if self.data['swap'].get('previousApp') and self.data['state'] not in ('succeeded',):
            # A runner that died after the swap (crash, reboot) left no verdict:
            # restore the previous app before trying again.
            self.journal.note('the previous attempt stopped after the swap; restoring the previous app first')
            self.rollback()
            if self.data['state'] == 'rollback-failed':
                return 1
        self.journal.begin_attempt({'pid': os.getpid(), 'startedAt': now()})
        step = None
        try:
            for item in self.data['steps']:
                step = item['name']
                if item['state'] == 'done' and self.reuse(step):
                    self.journal.note(f'{step}: reused from attempt {self.data["attempt"] - 1}')
                    continue
                self.journal.start_step(step)
                detail = getattr(self, 'step_' + step.replace('-', '_'))()
                self.journal.finish_step(step, detail)
            self.journal.settle('succeeded')
        except Exception as error:  # noqa: BLE001 - every failure is journaled, then rolled back
            message = str(error) if isinstance(error, (Failure, RpcError)) else f'{type(error).__name__}: {error}'
            if step is not None:
                self.journal.fail_step(step, message)
            self.recover()
        self.notify()
        return 0 if self.data['state'] == 'succeeded' else 1

    def reuse(self, step):
        """A completed build/signature step stays valid while its artifact is unchanged."""
        artifact = self.data.get('artifact')
        if not artifact:
            return False
        try:
            return self.platform.codesign_identity(Path(artifact['path']))['cdhash'] == artifact['cdhash']
        except Failure:
            return False

    # Steps ---------------------------------------------------------------
    def step_preflight(self):
        platform, path = self.platform, self.data['path']
        platform.admit()
        checks = []
        if (platform.maintenance / 'active.json').exists():
            raise Failure('a manual `scripts/tron mac reinstall` operation is active; finish it with '
                          '`scripts/tron mac reinstall --verify` then `--finish` (or `--abandon`) first')
        if git(self.root, 'rev-parse', 'HEAD') != self.data['source'].get('head', self.revision):
            raise Failure(f'source HEAD moved since this operation started; start again for the new revision')
        dirty = git(self.root, 'status', '--porcelain', '--untracked-files=no')
        if dirty:
            raise Failure(f'source checkout {self.root} has uncommitted tracked changes:\n{dirty[:600]}')
        checks.append(f'clean {self.revision[:9]}')
        free = shutil.disk_usage(platform.home).free
        if free < DISK_RESERVE[path]:
            raise Failure(f'only {free // 1024 ** 3} GiB free; need {DISK_RESERVE[path] // 1024 ** 3} GiB')
        checks.append(f'{free // 1024 ** 3} GiB free')
        gateway, helper = platform.helper_state()
        if gateway != 'running':
            raise Failure(f'{platform.gateway_label} is {gateway}; Tron must be running before a replacement')
        if helper == 'absent':
            raise Failure(f'the native helper ({platform.helper_label}) is not registered; repair it in Tron first')
        checks.append('helper registered')
        info = platform.system_info()
        protocol, minimum = source_protocol(self.root, self.revision)
        client = self.data['source'].get('clientProtocol')
        if client is not None and not minimum <= client <= protocol and not self.data['source'].get('allowProtocolChange'):
            raise Failure(f'this iPhone speaks protocol {client} but the new Gateway needs {minimum}-{protocol}; '
                          'install the matching iPhone build first, or start from the Mac terminal with --allow-protocol-change')
        self.data['source']['fromRevision'] = info.get('sourceRevision')
        checks.append(f'protocol {info.get("protocolVersion")} → {protocol}')
        if path == 'full':
            identities = platform.signing_identities()
            if identities == 0:
                raise Failure('no valid code-signing identity in the login keychain')
            checks.append(f'{identities} signing identities')
            if not platform.app_running():
                raise Failure('Tron.app is not running; launch it first so Quit can retire its helper')
        elif 'gateway-update.v1' not in info.get('capabilities', []):
            raise Failure('this Gateway has no LaunchAgent-owned update helper for a quick rebuild')
        self.journal.save()
        return ', '.join(checks)

    def step_build(self):
        app = self.platform.build(self.root, self.revision, self.log('build'))
        if not Path(app).is_dir():
            raise Failure(f'the build produced no app at {app}')
        self.data['artifact'] = {'path': str(app), 'cdhash': None}
        return f'built {self.revision[:9]}'

    def step_verify_signature(self):
        app = Path(self.data['artifact']['path'])
        identity = self.platform.verify_artifact(app, self.revision, self.log('verify-signature'))
        manifest = json.loads((self.platform.bundled_gateway(app) / 'manifest.json').read_text())
        if manifest.get('sourceRevision') != self.revision:
            raise Failure(f'bundled Gateway revision {manifest.get("sourceRevision")} is not {self.revision}')
        self.data['artifact'].update(identity, protocol=manifest.get('protocolVersion'))
        self.journal.save()
        return f'team {identity["team"]}, cdhash {identity["cdhash"][:12]}'

    def step_drain_workers(self):
        stopped = self.stop_workers()
        return f'stopped {len(stopped)} worker{"s" if len(stopped) != 1 else ""}' if stopped else 'no running workers'

    def stop_workers(self):
        """Stop running Home workers through the task stop path; sessions, worktrees and claims stay."""
        platform, active, cursor = self.platform, [], None
        for _ in range(40):
            page = platform.rpc('home.taskList', {'limit': 50, **({'cursor': cursor} if cursor else {})})
            active += [task for task in page.get('items', []) if task.get('lifecycle') == 'active' and task.get('sessionId')]
            cursor = page.get('nextCursor')
            if not cursor:
                break
        known = {worker['taskId'] for worker in self.data['workers']}
        for task in active:
            status = platform.rpc('home.taskStatus', {'taskId': task['taskId']})
            record = status.get('task', status)
            operation = record.get('operationId')
            if not operation:
                continue
            platform.mutation('home.stopTask', {'taskId': task['taskId'], 'operationId': operation})
            if task['taskId'] not in known:
                self.data['workers'].append({'taskId': task['taskId'], 'sessionId': task['sessionId'],
                                             'title': task.get('title') or task['taskId'], 'stoppedAt': now()})
            self.journal.progress('drain-workers', f'stopping {task.get("title") or task["taskId"]}')
        deadline = time.monotonic() + WORKER_STOP_TIMEOUT
        for task in active:
            while True:
                status = platform.rpc('home.taskStatus', {'taskId': task['taskId']})
                if status.get('task', status).get('lifecycle') == 'terminal':
                    break
                if time.monotonic() > deadline:
                    raise Failure(f'worker {task["taskId"]} did not stop within {WORKER_STOP_TIMEOUT // 60} minutes')
                time.sleep(2)
        self.journal.save()
        return active

    def step_stop_gateway(self):
        self.platform.quit_app(self.log('stop-gateway'))
        self.wait_offline('stop-gateway', self.platform.quit_timeout)
        return 'Tron quit; Gateway and native helper retired'

    def wait_offline(self, step, timeout):
        deadline, reported = time.monotonic() + timeout, None
        while True:
            blocker = self.platform.offline_blocker()
            if blocker is None:
                return
            if blocker != reported:
                self.journal.progress(step, f'waiting: {blocker}')
                reported = blocker
            if time.monotonic() > deadline:
                raise Failure(f'Quit did not finish within {timeout}s: {blocker}')
            time.sleep(2)

    def step_swap_app(self):
        """Snapshot ~/.tron, retire the external Stable payload, and swap the app, journaling each move."""
        platform, swap, operation = self.platform, self.data['swap'], self.journal.directory
        lock = self.maintenance_lock()
        try:
            blocker = platform.offline_blocker()
            if blocker:
                raise Failure(f'not offline before the swap: {blocker}')
            snapshot = operation / 'state-snapshot'
            if snapshot.exists():
                shutil.rmtree(snapshot)
            # One APFS clonefile of the whole tree: a consistent, space-shared
            # rollback point taken while every Stable writer is stopped.
            if LIBC.clonefile(os.fsencode(platform.tron_home), os.fsencode(snapshot), 0) != 0:
                raise Failure(f'could not snapshot {platform.tron_home}: {os.strerror(ctypes.get_errno())}')
            swap['snapshot'] = str(snapshot)
            self.journal.save()
            # Each move is journaled before it happens; rollback restores by what exists,
            # so a runner that dies between journal and rename still recovers.
            channel = platform.stable_channel()
            if channel.exists():
                retired = operation / f'retired-stable-payloads-{self.data["attempt"]}'
                swap['retiredChannel'] = str(retired)
                self.journal.save()
                os.rename(channel, retired)
            previous = private_mkdir(operation / f'previous-app-{self.data["attempt"]}') / 'Tron.app'
            swap['previousApp'] = str(previous)
            self.journal.save()
            os.rename(platform.installed, previous)
            staging = platform.installed.with_name('.Tron.app.replacing')
            if staging.exists():
                shutil.rmtree(staging)
            platform.replace_app_bytes(Path(self.data['artifact']['path']), staging, self.log('swap-app'))
            os.rename(staging, platform.installed)
            swap['installed'] = True
            self.journal.save()
        finally:
            os.close(lock)
        return f'installed {self.revision[:9]}; previous app kept at {previous}'

    def maintenance_lock(self):
        """Exclude `mac reinstall` for the offline window (its own flock)."""
        root = private_mkdir(self.platform.maintenance)
        fd = os.open(root / 'lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            raise Failure('another reinstall or cutover command holds ~/.tron-maintenance/lock') from None
        return fd

    def step_start(self):
        self.platform.launch_app(self.log('start'))
        return self.wait_healthy('start', self.platform.start_timeout)

    def wait_healthy(self, step, timeout):
        deadline, last = time.monotonic() + timeout, None
        while time.monotonic() < deadline:
            try:
                info = self.platform.system_info()
                return f'Gateway {str(info.get("sourceRevision", "?"))[:9]} answering on protocol {info.get("protocolVersion")}'
            except (RpcError, OSError, ValueError, KeyError) as error:
                if str(error) != last:
                    self.journal.progress(step, f'waiting for the Gateway: {error}')
                    last = str(error)
            time.sleep(3)
        raise Failure(f'the Gateway did not answer within {timeout}s ({last})')

    def step_verify(self):
        info = self.platform.system_info()
        if info.get('sourceRevision') != self.revision:
            raise Failure(f'running Gateway reports revision {info.get("sourceRevision")}, expected {self.revision}')
        protocol, _ = source_protocol(self.root, self.revision)
        if info.get('protocolVersion') != protocol:
            raise Failure(f'running Gateway speaks protocol {info.get("protocolVersion")}, expected {protocol}')
        result = {'revision': info['sourceRevision'], 'protocol': protocol}
        if self.data['path'] == 'full':
            identity = self.platform.codesign_identity(self.platform.installed, self.log('verify'))
            if identity['cdhash'] != self.data['artifact']['cdhash']:
                raise Failure(f'installed app cdhash {identity["cdhash"]} is not the verified candidate')
            self.platform.verify_installed(self.revision, self.log('verify'))
            result['cdhash'] = identity['cdhash']
            result['team'] = identity['team']
        self.data['result'] = result
        return f'{self.revision[:9]} on protocol {protocol}' + (f', cdhash {result["cdhash"][:12]}' if 'cdhash' in result else '')

    def step_rebuild(self):
        """Quick path: the Gateway's own LaunchAgent-owned source update, followed to its terminal state."""
        command = self.platform.mutation('gateway.update', {'channel': 'stable', 'mode': 'source'})['commandId']
        deadline, last = time.monotonic() + 30 * 60, None
        while time.monotonic() < deadline:
            time.sleep(3)
            try:
                status = self.platform.rpc('gateway.update.status', {'channel': 'stable'})
            except RpcError as error:
                status = {'state': 'restarting', 'commandId': command, 'detail': str(error)}
            if status.get('commandId') != command:
                continue
            if status['state'] != last:
                self.journal.progress('rebuild', f'Gateway update {status["state"]}')
                last = status['state']
            if status['state'] == 'ready':
                return self.wait_healthy('rebuild', self.platform.start_timeout)
            if status['state'] in ('failure', 'failed', 'rolled-back'):
                raise Failure(f'Gateway source update {status["state"]}: {status.get("error") or "no error recorded"} '
                              f'(log: {self.platform.tron_home}/gateway/payloads/stable/update-progress.json)')
        raise Failure('the Gateway source update did not settle within 30 minutes')

    def step_finish(self):
        prune_builds(self.platform, keep=self.revision)
        return 'replacement complete'

    # Failure handling ----------------------------------------------------
    def recover(self):
        swap = self.data['swap']
        if swap.get('previousApp'):
            self.rollback()
            return
        self.journal.settle('failed')
        # Before the swap only Quit can have changed live state: bring the
        # unchanged app back rather than leave Tron down.
        try:
            if self.data['path'] == 'full' and self.platform.offline_blocker() is None:
                self.platform.launch_app(self.log('stop-gateway'))
                self.wait_healthy('stop-gateway', self.platform.start_timeout)
                self.journal.note('previous app relaunched')
        except Failure as error:
            self.journal.note(f'could not relaunch the previous app: {error}')

    def rollback(self):
        """Restore the previous app and payload channel; keep the ~/.tron snapshot as a rollback point."""
        platform, swap, operation = self.platform, self.data['swap'], self.journal.directory
        attempt = self.data['attempt']
        self.data['rollback'] = {'state': 'running', 'startedAt': now()}
        self.journal.save()
        self.journal.note('rollback: restoring the previous app')
        log = self.journal.step_log('rollback')
        try:
            if platform.app_running() or platform.offline_blocker():
                platform.quit_app(log)
                self.wait_offline('rollback', 10 * 60)
            lock = self.maintenance_lock()
            try:
                previous = Path(swap['previousApp'])
                if previous.exists():
                    if platform.installed.exists():
                        os.rename(platform.installed, operation / f'failed-app-{attempt}.app')
                    os.rename(previous, platform.installed)
                elif not platform.installed.exists():
                    raise Failure(f'neither the previous app ({previous}) nor an installed app exists')
                retired = Path(swap['retiredChannel']) if swap.get('retiredChannel') else None
                if retired is not None and retired.exists():
                    channel = platform.stable_channel()
                    if channel.exists():
                        os.rename(channel, operation / f'failed-stable-payloads-{attempt}')
                    os.rename(retired, channel)
            finally:
                os.close(lock)
            self.data['swap'] = {'snapshot': swap.get('snapshot')}
            self.journal.save()
            platform.launch_app(log)
            detail = self.wait_healthy('rollback', platform.start_timeout)
            from_revision = self.data['source'].get('fromRevision')
            info = platform.system_info()
            if from_revision and info.get('sourceRevision') != from_revision:
                raise Failure(f'restored Gateway reports {info.get("sourceRevision")}, expected {from_revision}')
            self.data['rollback'] = {'state': 'restored', 'endedAt': now(),
                                     'detail': f'previous app restored; {detail}; ~/.tron snapshot kept at {swap.get("snapshot")}'}
            self.journal.settle('rolled-back')
        except Exception as error:  # noqa: BLE001
            self.data['rollback'] = {'state': 'failed', 'endedAt': now(), 'detail': f'{error} (log: {log})'}
            self.journal.settle('rollback-failed')

    def notify(self):
        """Ask the running Gateway to push the journal's result; it reads the journal itself."""
        try:
            self.platform.mutation('mac.replace.complete', {'operationId': self.data['id']})
            self.data['notification'] = {'state': 'requested', 'at': now()}
        except (RpcError, Failure, OSError, ValueError, KeyError) as error:
            self.data['notification'] = {'state': 'unavailable', 'detail': str(error)[:300]}
        self.journal.save()


def prune_builds(platform, keep):
    """Keep the current and one previous build worktree; each holds gigabytes of DerivedData."""
    builds = platform.store / 'builds'
    if not builds.is_dir():
        return
    entries = sorted((entry for entry in builds.iterdir() if entry.name != keep), key=lambda entry: entry.stat().st_mtime)
    for entry in entries[:-1]:
        capture(['/usr/bin/git', '-C', entry, 'worktree', 'remove', '--force', entry], timeout=600)
        if entry.exists():
            shutil.rmtree(entry, ignore_errors=True)


# Operation store -----------------------------------------------------------

def current_journal(platform):
    pointer = platform.store / 'current.json'
    if not pointer.exists():
        return None
    operation = json.loads(pointer.read_text())['id']
    return Journal(platform.store / operation).load()


def runner_alive(platform, journal):
    label = runner_label(journal.data['id'])
    return platform.launchd_state(label) == 'running'


def runner_label(operation):
    return f'com.tron.mac.replace.{operation[:8]}'


def launch_runner(platform, journal, script_dir):
    """Detach the runner as its own launchd job, from a private copy of this script."""
    operation = journal.directory
    runtime = private_mkdir(operation / 'runner')
    for name in ('tron_mac_replace.py', 'tron_mac_replace_journal.py', 'tron_mac_replace_platform.py', *platform.runner_files()):
        shutil.copy2(Path(script_dir) / name, runtime / name)
    label = runner_label(journal.data['id'])
    plist = operation / 'runner.plist'
    with plist.open('wb') as stream:
        plistlib.dump({'Label': label, 'ProgramArguments': ['/usr/bin/python3', str(runtime / platform.runner_entry()),
                                                            '--run', journal.data['id'], *platform.runner_arguments()],
                       'RunAtLoad': True, 'KeepAlive': False, 'AbandonProcessGroup': True, 'ProcessType': 'Interactive',
                       'StandardOutPath': str(operation / 'runner.out'), 'StandardErrorPath': str(operation / 'runner.out'),
                       'EnvironmentVariables': {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(platform.home)}}, stream)
    domain = f'gui/{os.getuid()}'
    capture(['/bin/launchctl', 'bootout', f'{domain}/{label}'], timeout=30)
    code, _, err = capture(['/bin/launchctl', 'bootstrap', domain, plist], timeout=30)
    if code != 0:
        raise Failure(f'launchctl bootstrap {label} failed: {err.strip()[:300]}')
    journal.note(f'runner launched as launchd job {label}')


def start(platform, root, client_protocol=None, allow_protocol_change=False, script_dir=None):
    platform.store.mkdir(parents=True, exist_ok=True)
    private_mkdir(platform.store)
    with store_lock(platform):
        journal = current_journal(platform)
        if journal and journal.data['state'] not in TERMINAL_STATES:
            if runner_alive(platform, journal):
                return journal, 'already running'
            # Its runner died (crash, reboot): rerun the same operation, which
            # first restores the previous app if it had already swapped.
            journal.data['source'].update(clientProtocol=client_protocol, allowProtocolChange=allow_protocol_change)
            journal.save()
            launch_runner(platform, journal, script_dir or Path(__file__).resolve().parent)
            return journal, 'resuming interrupted'
        decided = plan(platform, root)
        if decided['path'] == 'none':
            raise Failure(decided['reason'])
        retry = (journal is not None and journal.data['state'] in ('failed', 'rolled-back')
                 and journal.data['source']['revision'] == decided['revision'] and journal.data['path'] == decided['path'])
        if journal and journal.data['state'] == 'rollback-failed':
            raise Failure(f'operation {journal.data["id"]} could not roll back; restore Tron by hand from its journal first')
        if not retry:
            operation = str(uuid.uuid4())
            journal = Journal.create(platform.store / operation, operation, decided['path'], decided['reason'], {
                'root': decided['root'], 'revision': decided['revision'], 'head': decided['head'],
                'running': decided['running'],
                'clientProtocol': client_protocol, 'allowProtocolChange': allow_protocol_change})
            from tron_mac_replace_journal import write_json_atomic
            write_json_atomic(platform.store / 'current.json', {'id': operation})
        else:
            journal.data['source'].update(clientProtocol=client_protocol, allowProtocolChange=allow_protocol_change)
            journal.data['state'] = 'queued'
            journal.save()
        launch_runner(platform, journal, script_dir or Path(__file__).resolve().parent)
        return journal, 'retrying' if retry else 'started'


class store_lock:
    def __init__(self, platform):
        self.path = platform.store / 'lock'

    def __enter__(self):
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *_):
        os.close(self.fd)


def run_operation(platform, operation):
    journal = Journal(platform.store / operation).load()
    lock = os.open(journal.directory / 'runner.lock', os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return 0
    return Runner(platform, journal).run()


def follow(platform, as_json):
    journal = current_journal(platform)
    if journal is None:
        print('No Mac replacement has run on this Mac.')
        return 0
    offset = 0
    while True:
        journal.load()
        if not as_json and journal.log_path.exists():
            with journal.log_path.open() as stream:
                stream.seek(offset)
                sys.stdout.write(stream.read())
                offset = stream.tell()
            sys.stdout.flush()
        if journal.data['state'] in TERMINAL_STATES:
            print(json.dumps(journal.data, indent=1) if as_json else describe(journal.data))
            return 0 if journal.data['state'] == 'succeeded' else 1
        time.sleep(2)


def main(platform_factory=MacPlatform, arguments=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument('--plan', action='store_true', help='print which path a replacement takes, and why')
    actions.add_argument('--start', action='store_true', help='start (or retry) the replacement as a detached launchd job')
    actions.add_argument('--status', action='store_true', help='print the current journal')
    actions.add_argument('--run', metavar='OPERATION', help=argparse.SUPPRESS)
    parser.add_argument('--follow', action='store_true', help='with --status: stream the journal until it settles')
    parser.add_argument('--json', action='store_true', help='machine-readable output')
    parser.add_argument('--client-protocol', type=int, help=argparse.SUPPRESS)
    parser.add_argument('--allow-protocol-change', action='store_true',
                        help='proceed although the requesting iPhone cannot speak the new protocol')
    args = parser.parse_args(arguments)
    platform = platform_factory()
    root = Path(__file__).resolve().parent.parent
    try:
        if args.run:
            return run_operation(platform, args.run)
        platform.admit()
        if args.plan:
            decided = plan(platform, root)
            print(json.dumps(decided) if args.json else f'{decided["path"]}: {decided["reason"]}')
            return 0
        if args.start:
            journal, outcome = start(platform, root, args.client_protocol, args.allow_protocol_change)
            if args.json:
                print(json.dumps({'operationId': journal.data['id'], 'outcome': outcome, 'path': journal.data['path'],
                                  'reason': journal.data['reason'], 'journal': str(journal.log_path)}))
            else:
                print(f'{outcome}: {journal.data["path"]} replacement {journal.data["id"]}\n{journal.data["reason"]}\n'
                      f'Follow it with: scripts/tron mac replace --status --follow')
            return 0
        if args.follow:
            return follow(platform, args.json)
        journal = current_journal(platform)
        if journal is None:
            print('{}' if args.json else 'No Mac replacement has run on this Mac.')
            return 0
        print(json.dumps(journal.data, indent=1) if args.json else describe(journal.data))
        return 0
    except (Failure, RpcError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f'STOP: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
