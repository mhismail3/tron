#!/usr/bin/env python3
"""Maintainer-only Profile cutover. No deployment or bundle replacement."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import stat
import sys
import time

from tron_mac_replace_platform import MacPlatform, Failure
from tron_rebuild_lock import RebuildLock, RebuildBusy

ROOT = Path(__file__).resolve().parents[1]
SOURCE = '905e0510a6fbae727fdeb4cc3667d9a676fc3b99'


@contextmanager
def private_log(path):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'a') as log:
        info = os.fstat(log.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_nlink != 1:
            raise Failure('controller log must be a private owned regular file')
        yield log


def wait_for(platform, offline):
    deadline = time.monotonic() + (platform.quit_timeout if offline else platform.start_timeout)
    while True:
        if offline:
            platform.quit_progress()
            ready = platform.offline_blocker() is None
        else:
            try:
                platform.system_info()
                ready = True
            except Exception:
                ready = False
        if ready:
            if offline:
                platform.clear_quit_request()
            return
        if time.monotonic() >= deadline:
            raise Failure('Gateway did not become ' + ('offline' if offline else 'healthy'))
        time.sleep(2)


def controller_process(argv, log, leases, environment):
    return subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                            text=True, pass_fds=leases, env=environment)


def run_controller(argv, platform, log_path, leases, environment):
    """Bridge the real lifecycle owner to the leased data owner; children retain exclusion."""
    with private_log(log_path) as log:
        with controller_process(argv, log, leases, environment) as child:
            try:
                for line in child.stdout:
                    message = json.loads(line)
                    if 'call' not in message:
                        if 'error' in message:
                            print('profile cutover: ' + str(message['error']), file=sys.stderr, flush=True)
                        else:
                            print(json.dumps(message, indent=2), flush=True)
                        continue
                    try:
                        if message['call'] == 'stop':
                            if platform.gateway_pid() is not None and not platform.app_running():
                                platform.launch_app(log_path)
                                deadline = time.monotonic() + platform.start_timeout
                                while not platform.app_running():
                                    if time.monotonic() >= deadline:
                                        raise Failure('installed wrapper did not open for coordinated Quit')
                                    time.sleep(2)
                            platform.quit_app(log_path)
                            wait_for(platform, True)
                            result = None
                        elif message['call'] == 'start':
                            platform.launch_app(log_path)
                            wait_for(platform, False)
                            result = None
                        elif message['call'] == 'rpc':
                            params = message['params']
                            result = platform.rpc(params['method'], params['params'])
                        else:
                            raise Failure('unknown lifecycle request')
                        reply = {'id': message['id'], 'result': result}
                    except Exception as error:
                        reply = {'id': message['id'], 'error': str(error)}
                    child.stdin.write(json.dumps(reply) + '\n')
                    child.stdin.flush()
                return child.wait()
            except BaseException:
                child.terminate()
                child.wait()
                raise


def verify_gateway_source(root=ROOT, source=SOURCE):
    # The owning cutover documentation ships with this command, not the reader.
    subprocess.run(['git', '-C', root, 'diff', '--quiet', source, 'HEAD', '--', 'packages/gateway/src',
                    ':(exclude)packages/gateway/src/maintenance', ':(exclude)packages/gateway/src/gateway-main.module.json',
                    ':(exclude)packages/gateway/src/modules/home/profile.md'], check=True)


def main():
    parser = argparse.ArgumentParser(description='Exact prepared Profile migration; maintainer Terminal only. Prints before/after and rollback. No app install.')
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--apply', action='store_true', help='coordinated Quit, writer lease, bound publication, restart and live verification')
    action.add_argument('--rollback', action='store_true', help='coordinated Quit, byte-exact backup restore and restart; refuses new writes')
    action.add_argument('--plan', action='store_true', help='validate and print the exact bound plan without lifecycle changes')
    args = parser.parse_args()
    if not args.plan and not sys.stdin.isatty():
        parser.error('maintainer must run this command directly in Terminal; no unattended/agent apply')
    platform = MacPlatform()
    platform.admit()
    if subprocess.check_output(['git', '-C', ROOT, 'status', '--porcelain', '--untracked-files=no'], text=True).strip():
        raise Failure('commit the reviewed cutover implementation first')
    verify_gateway_source()
    active = json.loads((platform.active_payload() / 'manifest.json').read_text())
    if active.get('sourceRevision') != SOURCE:
        raise Failure('Stable payload source mismatch; this command is bound to ' + SOURCE)
    with RebuildLock(platform.maintenance / 'rebuild.lock') as rebuild, RebuildLock(platform.maintenance / 'lock') as maintenance:
        leases = (rebuild, maintenance)
        keys = ('TRON_REBUILD_LOCK_FD', 'TRON_REBUILD_LOCK_PATH')
        previous = {key: os.environ.get(key) for key in keys}
        os.environ.update(TRON_REBUILD_LOCK_FD=str(rebuild), TRON_REBUILD_LOCK_PATH=str(platform.maintenance / 'rebuild.lock'))
        try:
            logs = platform.maintenance / 'profile-cutover'
            logs.mkdir(mode=0o700, exist_ok=True)
            log_path = logs / 'controller.log'
            with private_log(log_path) as log:
                subprocess.run([ROOT / 'scripts/tron-node', 'exec', 'npm', 'run', 'build'], cwd=ROOT / 'packages/gateway',
                               stdout=log, stderr=log, check=True, pass_fds=leases, env=dict(os.environ))
            mode = 'plan' if args.plan else 'rollback' if args.rollback else 'apply'
            argv = [ROOT / 'scripts/tron-node', 'exec', 'node', ROOT / 'packages/gateway/dist/maintenance/profile-cutover-cli.js', platform.tron_home, platform.maintenance, mode]
            if run_controller(argv, platform, log_path, leases, dict(os.environ)):
                raise Failure('Cutover refused or failed. Inspect ' + str(log_path) + '; rollback: scripts/tron profile cutover --rollback')
        finally:
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (Failure, RebuildBusy, subprocess.CalledProcessError) as error:
        print('profile cutover: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
