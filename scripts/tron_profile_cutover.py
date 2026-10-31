#!/usr/bin/env python3
"""Maintainer-only Profile cutover. No build deployment, bundle replacement or new lifecycle owner."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import stat
import sys
import time

from tron_mac_replace_platform import MacPlatform, Failure
from tron_rebuild_lock import RebuildLock

ROOT = Path(__file__).resolve().parents[1]
SOURCE = '905e0510a6fbae727fdeb4cc3667d9a676fc3b99'


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
    subprocess.run(['git', '-C', ROOT, 'diff', '--quiet', SOURCE, 'HEAD', '--', 'packages/gateway/src',
                    ':(exclude)packages/gateway/src/maintenance', ':(exclude)packages/gateway/src/gateway-main.module.json'], check=True)
    active = json.loads((platform.active_payload() / 'manifest.json').read_text())
    if active.get('sourceRevision') != SOURCE:
        raise Failure('Stable payload source mismatch; this command is bound to ' + SOURCE)
    # Shared Mac replacement/reinstall leases; the Node owner additionally takes
    # Gateway's canonical runtime + workspace leases and the old SQLite writer lock.
    with RebuildLock(platform.maintenance / 'rebuild.lock'), RebuildLock(platform.maintenance / 'lock'):
        logs = platform.maintenance / 'profile-cutover'
        logs.mkdir(mode=0o700, exist_ok=True)
        log_path = logs / 'controller.log'
        fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'a') as log:
            info = os.fstat(log.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_nlink != 1:
                raise Failure('controller log must be a private owned regular file')
            subprocess.run([ROOT / 'scripts/tron-node', 'exec', 'npm', 'run', 'build'], cwd=ROOT / 'packages/gateway', stdout=log, stderr=log, check=True)
            mode = 'plan' if args.plan else 'rollback' if args.rollback else 'apply'
            argv = [ROOT / 'scripts/tron-node', 'exec', 'node', ROOT / 'packages/gateway/dist/maintenance/profile-cutover-cli.js', platform.tron_home, platform.maintenance, mode]
            with subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True) as child:
                try:
                    for line in child.stdout:
                        message = json.loads(line)
                        if 'call' not in message:
                            print(json.dumps(message, indent=2), flush=True)
                            continue
                        try:
                            if message['call'] == 'stop':
                                # Headless Stable still needs the installed wrapper's coordinated Quit.
                                if platform.gateway_pid() is not None and not platform.app_running():
                                    platform.launch_app(log)
                                    deadline = time.monotonic() + platform.start_timeout
                                    while not platform.app_running():
                                        if time.monotonic() >= deadline:
                                            raise Failure('installed wrapper did not open for coordinated Quit')
                                        time.sleep(2)
                                platform.quit_app(log)
                                wait_for(platform, True)
                                result = None
                            elif message['call'] == 'start':
                                platform.launch_app(log)
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
                    code = child.wait()
                except BaseException:
                    child.terminate()
                    child.wait()
                    raise
            if code:
                raise Failure('Cutover refused or failed. Inspect ' + str(log_path) + '; rollback: scripts/tron profile cutover --rollback')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (Failure, subprocess.CalledProcessError) as error:
        print('profile cutover: ' + str(error), file=sys.stderr)
        raise SystemExit(1)
