"""Maintainer-only one-shot #2500 cutover; never run from an agent task."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

SOURCE = Path(__file__).resolve().parents[2]
REVISION = ""
REVIEWED_TREE = ""


def require(value, message):
    if not value:
        raise RuntimeError(message)


def command(args, log, cwd=None):
    subprocess.run([str(value) for value in args], cwd=cwd, stdout=log, stderr=subprocess.STDOUT, check=True)


def save(path, value):
    temporary = path.with_suffix('.next')
    with temporary.open('x') as stream:
        os.chmod(temporary, 0o600)
        json.dump(value, stream, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def platform_log(log):
    log.flush()
    return Path(log.name)


def stop(platform, log):
    platform.quit_app(platform_log(log))
    deadline = time.monotonic() + platform.quit_timeout
    while True:
        platform.quit_progress()
        blocker = platform.offline_blocker()
        if blocker is None:
            platform.clear_quit_request()
            return
        require(time.monotonic() < deadline, 'Quit did not finish: ' + blocker)
        time.sleep(1)


def ssh(root, hidden, log, hide=False):
    target = Path.home() / 'Library/LaunchAgents' / (terminal.label(root) + '.plist')
    if target.exists():
        require(not target.is_symlink() and target.read_bytes() == terminal.plist(root), 'SSH plist is not exactly owned; stop for review')
        if not hide:
            command(['/bin/cp', '-p', target, hidden], log)
    job = terminal.job(layout, root, target)
    if job is not None:
        result = terminal.command(layout, ['/bin/launchctl', 'bootout', f'gui/{os.getuid()}/{terminal.label(root)}'])
        require(result.returncode == 0, 'owned SSH listener did not retire')
        require(terminal.job(layout, root, target) is None, 'owned SSH job remains loaded')
    if hide and target.exists():
        require(not hidden.exists(), 'held SSH intent already exists; inspect the receipt')
        target.rename(hidden)
    return str(target)


def migrate(build, action, operation, log, home):
    output = operation / (action.lstrip('-') + '.json')
    with output.open('xb') as stream:
        os.chmod(output, 0o600)
        subprocess.run([sys.executable, '-B', str(build / 'tools/home-layout/home_layout.py'), 'migrate', '--home', str(home), action], stdout=stream, stderr=log, check=True)
    return json.loads(output.read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['apply', 'rollback'])
    args = parser.parse_args()
    require(re.fullmatch('[0-9a-f]{40}', REVISION), 'cutover has not been bound to its reviewed main merge')
    head = subprocess.check_output(['git', '-C', str(SOURCE), 'rev-parse', 'HEAD'], text=True).strip()
    tree = subprocess.check_output(['git', '-C', str(SOURCE), 'rev-parse', REVISION + '^{tree}'], text=True).strip()
    dirty = subprocess.check_output(['git', '-C', str(SOURCE), 'status', '--porcelain', '--untracked-files=no'], text=True)
    require(head == REVISION and tree == REVIEWED_TREE and not dirty, 'landed main checkout is not the exact clean reviewed tree')
    global layout, terminal
    sys.path[:0] = [str(SOURCE / 'scripts'), str(SOURCE / 'tools/home-layout')]
    import home_layout as layout
    import terminal_layout as terminal
    from tron_mac_reinstall import exclusive, private_dir, read_json
    from tron_mac_replace_platform import MacPlatform
    platform = MacPlatform()
    platform.admit()
    require(not os.environ.get('PI_SESSION_ID'), 'maintainer Terminal only; no agent shell')
    maintenance = platform.maintenance
    private_dir(maintenance, create=True)
    operation = maintenance / ('cutover-2500-' + REVISION[:12])
    receipt_path = operation / 'receipt.json'
    if args.action == 'apply':
        require(shutil.disk_usage(platform.home).free >= 450_000_000_000, 'less than the conservative450GB free-space budget')
        operation.mkdir(mode=0o700)
        receipt = {'revision': REVISION, 'phase': 'building', 'started': time.time()}
        save(receipt_path, receipt)
    else:
        private_dir(operation)
        receipt = read_json(receipt_path)
        require(receipt['revision'] == REVISION and receipt.get('migrationCompleted'), 'rollback command is for a completed forward migration; preserve partial-operation evidence for owner recovery')
    log_path = operation / (args.action + '.log')
    log_path.touch(mode=0o600, exist_ok=False)
    with log_path.open('a') as log:
        if args.action == 'apply':
            main_sha = subprocess.check_output(['git', '-C', str(SOURCE), 'ls-remote', 'origin', 'refs/heads/main'], text=True).split()[0]
            require(main_sha == REVISION, 'main advanced; this exact reviewed cutover needs revalidation')
            require(not platform.build_root(REVISION).exists(), 'build worktree already exists; inspect rather than reuse unknown work')
            candidate = platform.build(SOURCE, REVISION, platform_log(log))
            platform.verify_artifact(candidate, REVISION, platform_log(log))
            build = platform.build_root(REVISION)
            receipt.update(build=str(build), candidate=str(candidate))
            save(receipt_path, receipt)
            require(not (maintenance / 'active.json').exists(), 'another reinstall owns maintenance')
            require(not (platform.store / 'active.json').exists(), 'another replacement owns maintenance')
            stop(platform, log)
            receipt['phase'] = 'stopped'
            receipt['legacySSHPlist'] = ssh(platform.tron_home / 'mac-terminal', operation / 'legacy-ssh.plist', log)
            save(receipt_path, receipt)
            command([build / 'scripts/tron', 'mac', 'reinstall', '--app', candidate], log)
            active = read_json(maintenance / 'active.json')
            receipt['backupOperation'] = str(maintenance / active['id'])
            save(receipt_path, receipt)
            command([build / 'scripts/tron', 'mac', 'reinstall', '--confirm-offline'], log)
            command([build / 'scripts/tron', 'mac', 'reinstall', '--abandon'], log)
            with exclusive(maintenance):
                require(not (maintenance / 'active.json').exists(), 'another reinstall claimed maintenance')
                dry = migrate(build, '--dry-run', operation, log, platform.tron_home)
                require(not dry['errors'] and not dry['blockers'], 'dry-run refused; no apply is allowed')
                receipt['phase'] = 'migrating'
                save(receipt_path, receipt)
                applied = migrate(build, '--apply', operation, log, platform.tron_home)
                require(applied['state'] == 'applied' and not applied['errors'] and not applied['blockers'], 'migration did not complete; do not launch either build')
                receipt.update(migrationCompleted=True, phase='migrated')
                save(receipt_path, receipt)
                channel = platform.stable_channel()
                if channel.exists():
                    channel.rename(operation / 'retired-stable-channel')
                staging = platform.installed.with_name('Tron.2500.staged.app')
                require(not staging.exists(), 'staged app already exists; never overwrite uncertain state')
                platform.replace_app_bytes(candidate, staging, platform_log(log))
                platform.verify_artifact(staging, REVISION, platform_log(log))
                platform.installed.rename(operation / 'original.keptapp')
                staging.rename(platform.installed)
                receipt['phase'] = 'app-replaced'
                save(receipt_path, receipt)
        else:
            build = Path(receipt['build'])
            stop(platform, log)
            with exclusive(maintenance):
                require(not (maintenance / 'active.json').exists(), 'another reinstall owns maintenance')
                ssh(platform.tron_home / 'state/mac-terminal', operation / 'held-canonical-ssh.plist', log, hide=True)
                rolled = migrate(build, '--rollback', operation, log, platform.tron_home)
                require(rolled['state'] == 'rolled_back' and not rolled['errors'] and not rolled['blockers'], 'inverse refused; preserve all receipts and do not launch')
                old_channel = platform.tron_home / 'gateway/payloads/stable'
                if (operation / 'retired-stable-channel').exists():
                    if old_channel.exists():
                        old_channel.rename(operation / 'post-cutover-channel-kept')
                    old_channel.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                    (operation / 'retired-stable-channel').rename(old_channel)
                if (operation / 'original.keptapp').exists():
                    if platform.installed.exists():
                        platform.installed.rename(operation / 'post-cutover.keptapp')
                    (operation / 'original.keptapp').rename(platform.installed)
                original_plist = operation / 'legacy-ssh.plist'
                if original_plist.exists():
                    target = Path(receipt['legacySSHPlist'])
                    require(not target.exists(), 'legacy SSH intent already exists; inspect rather than overwrite')
                    command(['/bin/cp', '-p', original_plist, target], log)
                receipt['phase'] = 'rolled-back'
                save(receipt_path, receipt)
        platform.launch_app(platform_log(log))
        deadline = time.monotonic() + platform.start_timeout
        while platform.gateway_pid() is None or platform.port_listening() is False:
            require(time.monotonic() < deadline, 'Gateway did not start; preserve receipt and use rollback only after owner review')
            time.sleep(1)
        if args.action == 'apply':
            platform.refresh_guard(build, REVISION, platform_log(log))
            platform.verify_installed(REVISION, platform_log(log))
            info = platform.system_info()
            require(info.get('sourceRevision') == REVISION, 'running Gateway does not report the reviewed revision')
            receipt['phase'] = 'verified'
            save(receipt_path, receipt)
        print('Completed ' + args.action + '; receipt: ' + str(receipt_path))
        if args.action == 'rollback':
            print('Old app/channel restored and listener present. This is not new-source mac verify; keep tasks parked until old-build continuity is checked.')


if __name__ == '__main__':
    main()
