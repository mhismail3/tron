"""Approved one-shot Knowledge retirement inside the replacement's offline transaction.

The replacement owns Quit, the raw state snapshot, old app/payload and rollback.
The pinned converter owns archive, privacy fences, exports and Profile publication.
"""
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import stat
import sys

from tron_mac_replace_journal import write_json_atomic
from tron_mac_replace_platform import Failure, run

PENDING = 'knowledge-cutover-pending.json'
CONTINUITY = ('workspace/state/episodic', 'gateway/home', 'agent/sessions')
PATHS = ('workspace/state/knowledge', 'workspace/state/knowledge.retiring',
         'workspace/state/profile', 'workspace/state/profile.retirement-partial',
         'gateway/workspace-state/initialized.json', 'gateway/workspace-state/profile-initialized.json')


def inventory(path):
    """Exact bytes/modes/link text; refuse special entries in protected state."""
    if not path.exists() and not path.is_symlink():
        return None
    result = {}
    for item in [path, *sorted(path.rglob('*'))] if path.is_dir() and not path.is_symlink() else [path]:
        key = str(item.relative_to(path))
        info = item.lstat()
        if item.is_symlink():
            result[key] = {'link': os.readlink(item)}
        elif item.is_file():
            result[key] = {'sha256': hashlib.sha256(item.read_bytes()).hexdigest(), 'mode': stat.S_IMODE(info.st_mode)}
        elif item.is_dir():
            result[key] = {'directory': True, 'mode': stat.S_IMODE(info.st_mode)}
        else:
            raise Failure(f'unsupported cutover entry: {item}')
    return result


def approval(platform):
    path = platform.maintenance / PENDING
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    with os.fdopen(fd) as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077 or info.st_size > 4096:
            raise Failure('Knowledge cutover approval is not a private bounded owner file')
        value = json.load(stream)
    if set(value) != {'version', 'priorAppRevision', 'priorGatewayRevision', 'converterSHA256', 'artifactDirectory', 'artifactManifestSHA256'} or value['version'] != 1:
        raise Failure('Knowledge cutover approval has an unsupported format')
    return value


def required(platform):
    return any((platform.tron_home / rel).exists() or (platform.tron_home / rel).is_symlink() for rel in PATHS[:2])


def verified_artifacts(permit):
    artifacts = Path(permit['artifactDirectory'])
    if not artifacts.is_absolute() or artifacts.resolve() != artifacts:
        raise Failure('Knowledge cutover artifact directory is noncanonical; live data is unchanged')
    manifest = artifacts / 'ARTIFACTS-SHA256.json'
    if hashlib.sha256(manifest.read_bytes()).hexdigest() != permit['artifactManifestSHA256']:
        raise Failure('Knowledge cutover artifact manifest changed; live data is unchanged')
    hashes = json.loads(manifest.read_bytes())
    if set(hashes) != {'CUTOVER.md', 'cutover.py', 'restore-data.py', 'retire-knowledge.py'}:
        raise Failure('Knowledge cutover artifact manifest is incomplete; live data is unchanged')
    for name, expected in hashes.items():
        path = artifacts / name
        if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise Failure(f'Knowledge cutover artifact SHA-256 mismatch: {name}; live data is unchanged')
    return artifacts, hashes


def preflight(platform, journal, converter, reserve):
    """Read-only live inputs, before worker drain or Quit; offline recount follows."""
    if not required(platform):
        return
    permit = approval(platform)
    if permit is None:
        raise Failure('Knowledge retirement needs its approved pending cutover; live data and running build are unchanged')
    _, hashes = verified_artifacts(permit)
    if hashes['retire-knowledge.py'] != permit['converterSHA256'] or hashlib.sha256(converter.read_bytes()).hexdigest() != permit['converterSHA256']:
        raise Failure('Knowledge converter differs from approved artifact; live data is unchanged')
    if json.loads((platform.bundled_gateway(platform.installed) / 'manifest.json').read_bytes())['sourceRevision'] != permit['priorAppRevision'] or json.loads((platform.active_payload() / 'manifest.json').read_bytes())['sourceRevision'] != permit['priorGatewayRevision']:
        raise Failure('Prior app/Gateway changed since approval; live data is unchanged')
    def size(root):
        return sum(path.lstat().st_size for path in root.rglob('*') if path.is_file() and not path.is_symlink())
    # Budget full logical snapshot bytes even on APFS, plus archive and worst-case
    # ordinary export copies; the clone's space sharing is not a capacity promise.
    needed = reserve + size(platform.tron_home) + 4 * size(platform.tron_home / PATHS[0])
    free = shutil.disk_usage(platform.home).free
    if free < needed:
        raise Failure(f'Knowledge cutover needs {needed} free bytes for build/snapshot/archive/export; have {free}; live build and data are unchanged')
    tool = runpy.run_path(str(converter))
    db, _ = tool['database'](platform.tron_home / PATHS[0])
    try:
        db.execute('BEGIN')
        if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise Failure('Knowledge preflight catalog integrity failed; live data is unchanged')
        counts = tool['count_snapshot'](db)
    finally:
        db.close()
    write_json_atomic(journal.directory / 'knowledge-preflight.json', {'counts': counts, 'requiredBytes': needed, 'freeBytes': free,
        'artifactManifestSHA256': permit['artifactManifestSHA256'], 'priorAppRevision': permit['priorAppRevision'], 'priorGatewayRevision': permit['priorGatewayRevision']})


def offline(platform):
    blocker = platform.offline_blocker()
    if blocker:
        raise Failure(f'Knowledge cutover is not offline: {blocker}')
    # These jobs are outside the Stable Quit owner and may write the same state.
    for label in ('com.tron.server.dev', 'com.tron.server.preview', 'com.tron.server.dev-takeover', 'com.tron.gateway.dev'):
        if platform.launchd_state(label) != 'absent':
            raise Failure(f'Knowledge cutover requires {label} unloaded')


def convert(platform, journal, converter, pass_fds=()):
    if not required(platform):
        return
    permit = approval(platform)
    if permit is None:
        raise Failure('Knowledge retirement needs its maintainer-approved pending cutover; new Gateway was not started')
    offline(platform)
    home = platform.tron_home
    store = home / PATHS[0]
    for rel in PATHS:
        path = home / rel
        if path.is_symlink() or path.resolve() != path:
            raise Failure(f'noncanonical Knowledge cutover path: {path}')
    if any((home / rel).exists() for rel in (PATHS[1], PATHS[2], PATHS[3], PATHS[5])):
        raise Failure('pre-existing Profile or partial Knowledge cutover needs review')
    if hashlib.sha256(converter.read_bytes()).hexdigest() != permit['converterSHA256']:
        raise Failure('Knowledge converter differs from the approved bytes')
    app = platform.bundled_gateway(platform.installed)
    if json.loads((app / 'manifest.json').read_bytes())['sourceRevision'] != permit['priorAppRevision'] or json.loads((platform.active_payload() / 'manifest.json').read_bytes())['sourceRevision'] != permit['priorGatewayRevision']:
        raise Failure('prior app or selected Gateway changed since cutover approval; not the candidate build identity')
    snapshot = Path(journal.data['swap']['snapshot'])
    before = {rel: inventory(home / rel) for rel in PATHS}
    if before != {rel: inventory(snapshot / rel) for rel in PATHS}:
        raise Failure('offline raw Knowledge snapshot differs from current state')
    operation = journal.directory / f'knowledge-cutover-{journal.data["attempt"]}'
    operation.mkdir(mode=0o700)
    artifacts, hashes = verified_artifacts(permit)
    tools = operation / 'recovery-tools'
    tools.mkdir(mode=0o700)
    for name, expected in {**hashes, 'ARTIFACTS-SHA256.json': permit['artifactManifestSHA256']}.items():
        target = tools / name
        shutil.copyfile(artifacts / name, target)
        target.chmod(0o600)
        if hashlib.sha256(target.read_bytes()).hexdigest() != expected:
            raise Failure('Prepared recovery artifact changed while preserving it; new runtime was not started')
    if hashes['retire-knowledge.py'] != permit['converterSHA256']:
        raise Failure('Preserved converter differs from approved bytes')
    converter = tools / 'retire-knowledge.py'
    tool = runpy.run_path(str(converter))
    db, catalog = tool['database'](store)
    try:
        if any(path.name != catalog.name for path in store.glob(catalog.name + '*')):
            raise Failure('Knowledge catalog sidecars remain; cannot prove offline snapshot')
        if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise Failure('Knowledge catalog integrity check failed')
        counts = tool['count_snapshot'](db)
    finally:
        db.close()
    exports = home / 'workspace/files' / f'knowledge-export-{journal.data["id"]}-{journal.data["attempt"]}'
    if exports.exists() or exports.resolve() != exports:
        raise Failure('Knowledge export destination exists or is noncanonical')
    exports.parent.mkdir(mode=0o700, exist_ok=True)
    prior = {'app': inventory(platform.installed), 'channel': inventory(platform.stable_channel())}
    if prior['channel'] != inventory(snapshot / 'gateway/payloads/stable'):
        raise Failure('prior selected payload snapshot differs from the stopped original')
    continuity = {rel: inventory(home / rel) for rel in CONTINUITY}
    if continuity != {rel: inventory(snapshot / rel) for rel in CONTINUITY}:
        raise Failure('Home memory/chats snapshot differs before conversion')
    write_json_atomic(operation / 'CONTINUITY.json', continuity)
    write_json_atomic(operation / 'COUNTS.json', counts)
    write_json_atomic(operation / 'PRIOR.json', permit)
    write_json_atomic(operation / 'BEFORE.json', before)
    write_json_atomic(operation / 'PRIOR-FILES.json', prior)
    # Keep large inventories out of the bounded Settings journal. Its digests
    # fence the private evidence files used during crash recovery.
    journal.data['swap']['knowledge'] = {'operation': str(operation), 'exports': str(exports),
        'beforeSHA256': hashlib.sha256((operation / 'BEFORE.json').read_bytes()).hexdigest(),
        'priorSHA256': hashlib.sha256((operation / 'PRIOR-FILES.json').read_bytes()).hexdigest()}
    # Durable recovery intent precedes the converter's first possible mutation.
    journal.save()
    args = [sys.executable, converter, '--store', store, '--backup', operation / 'archive', '--files', exports, '--offline']
    for name, count in counts.items():
        args += ['--expected-' + name, str(count)]
    write_json_atomic(operation / 'ARGS.json', [str(arg) for arg in args])
    for extra in ([], ['--verify']):
        offline(platform)
        run(args + extra, journal.step_log('swap-app'), timeout=1800, pass_fds=pass_fds)
    write_json_atomic(operation / 'CONVERTED.json', {rel: inventory(home / rel) for rel in PATHS})
    journal.data['swap']['knowledge']['convertedSHA256'] = hashlib.sha256((operation / 'CONVERTED.json').read_bytes()).hexdigest()
    journal.save()
    journal.note(f'Knowledge archived, exported and verified offline: {counts}; {operation}')
    # Decisive gate: candidate read owners only, still before any server starts.
    offline(platform)
    platform.verify_cutover(Path(journal.data['artifact']['path']), home, exports, counts, operation / 'read-only-gate.log', journal.step_log('swap-app'), pass_fds=pass_fds)
    offline(platform)
    if evidence(journal.data['swap']['knowledge'], 'CONVERTED.json', 'convertedSHA256') != {rel: inventory(home / rel) for rel in PATHS}:
        raise Failure('Candidate read-only gate changed protected state; new runtime was not started')
    if continuity != {rel: inventory(home / rel) for rel in CONTINUITY}:
        raise Failure('Home memory/chats/summary/chapter bytes changed during offline cutover')
    journal.data['swap']['knowledge']['gatePassed'] = True
    journal.save()


def evidence(state, name, key):
    raw = (Path(state['operation']) / name).read_bytes()
    if hashlib.sha256(raw).hexdigest() != state[key]:
        raise Failure('Knowledge recovery evidence changed; keeping offline')
    return json.loads(raw)


def restore(platform, journal):
    state = journal.data['swap'].get('knowledge')
    if not state or state.get('restored'):
        return
    offline(platform)
    home = platform.tron_home
    snapshot = Path(journal.data['swap']['snapshot'])
    before = evidence(state, 'BEFORE.json', 'beforeSHA256')
    if before != {rel: inventory(snapshot / rel) for rel in PATHS}:
        raise Failure('Knowledge rollback snapshot integrity failed; keeping offline')
    recovery = Path(state['operation']) / 'recovery'
    if journal.data['swap'].get('candidateStartRequested'):
        raise Failure('Cutover committed at candidate start; automatic data restoration is forbidden')
    recovery.mkdir(mode=0o700, exist_ok=True)
    for rel in PATHS:
        current, original = home / rel, snapshot / rel
        failed, stage = recovery / 'failed' / rel, recovery / 'staged' / rel
        expected = before[rel]
        if inventory(current) == expected:
            continue
        if failed.exists() or failed.is_symlink():
            if current.exists() or current.is_symlink():
                raise Failure('ambiguous interrupted Knowledge restore; keeping offline')
        elif current.exists() or current.is_symlink():
            failed.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            os.rename(current, failed)
        if expected is not None:
            if not stage.exists():
                stage.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                run(['/usr/bin/ditto', original, stage], journal.step_log('rollback'), timeout=900)
            if inventory(stage) != expected:
                raise Failure('staged Knowledge recovery differs from raw snapshot; keeping offline')
            current.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            os.rename(stage, current)
    if before != {rel: inventory(home / rel) for rel in PATHS}:
        raise Failure('Knowledge restoration failed verification; keeping offline')
    state['restored'] = True
    journal.save()


def verify_prior(platform, journal):
    state = journal.data['swap'].get('knowledge')
    if state:
        prior = evidence(state, 'PRIOR-FILES.json', 'priorSHA256')
        if prior != {'app': inventory(platform.installed), 'channel': inventory(platform.stable_channel())}:
            raise Failure('restored prior app or selected payload differs; keeping offline')


def post_start(platform, journal):
    if not journal.data['swap'].get('knowledge'):
        return
    platform.rpc('home.profileList')
    status = platform.rpc('home.status')
    if status.get('homeId'):
        platform.rpc('home.chapterList')
        if status.get('memory', {}).get('configured'):
            platform.rpc('home.memory.view', {'limit': 1})
    platform.rpc('session.list', {'scope': 'user', 'limit': 1})
    journal.note('Post-start Profile, Home and chat-catalog reads passed; conversion remains committed')


def finish(platform, journal):
    if journal.data['swap'].get('knowledge'):
        (platform.maintenance / PENDING).unlink(missing_ok=True)
