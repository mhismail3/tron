#!/usr/bin/env python3
"""Run Gateway, Python, Node, iOS or whole-verifier jobs under the Mac mini lease and return their native results.

The test-host pool is {the mini, this Mac}: `choose_host` picks the mini when it is configured, reachable and idle,
and otherwise this Mac, always with its reason; `mini.py pool [vitest args]` runs one lane on the chosen host.
`mini.py python <command>` runs verify's per-file Python command in the mini checkout, its stderr merged into
stdout in order, since verify counts each file's unittest summary after that file's marker. `mini.py node <file>...`
runs the Gateway's `node --test` files on the mini's pinned Node, its TAP output streamed back for verify to count.
`mini.py ios` invokes the native iOS owner; `mini.py verify` invokes verification inside the lease. Both return
bounded digest-checked native artifact archives with commit, execution-host and raw-exit receipts.

Local side: refuse a dirty tree, push the exact HEAD commit to the mini's bare repository, run this same file there
(sent as source, so both halves are one version), stream its output live, and write the Vitest output files it
returns where the caller asked, with the mini's checkout path rewritten to this checkout. The exit code is the
mini's. No result, never a local fallback, exits EXIT_NO_RESULT with a last `mini: no result: <reason>` line on stderr;
`no_result_reason` reads it, so a lane that itself exits 75 stays its own exit.

Mini side (`remote`): one job at a time under ~/tron-ci/jobs/gateway.lock (a caller's TRON_MINI_JOB_WAIT_SECONDS
caps the wait for it, naming the holder; unset waits indefinitely), check out the commit in
~/tron-ci/jobs/gateway, refuse a Node or npm that differs from the commit's pins, `npm ci` only when the
commit's Gateway dependency inputs changed (Python tests import Gateway packages too), then run the commit's own
gateway.py, the Node test files on the pinned Node, or, once the pinned Dafny passes `proof doctor`, the Python command. Closing the ssh session
(the local side stopped) sends that lane SIGTERM. The mini host is `git config tron.verify.mini` (an ssh
destination) and `tron.verify.miniIdentity` (an optional key file). Runs on the mini's /usr/bin/python3.
"""
from __future__ import annotations

import argparse
import base64
from contextlib import closing
import fcntl
import hashlib
import json
from itertools import islice
import os
import platform
import re
import shlex
import shutil
import signal
import sqlite3
import subprocess
import sys
import tarfile
import threading
import time
import uuid
from pathlib import Path
from typing import Iterator, Sequence

ROOT = Path(__file__).resolve().parents[2] if '__file__' in globals() else None
BASE = 'tron-ci'
EXIT_NO_RESULT = 75
NO_RESULT_LINE = 'mini: no result: '
OUTPUT_OPTION = '--outputFile'
ARTIFACT_LIMIT = 2 * 1024 ** 3
RETAINED_LIMIT = 128 * 1024 ** 2
RETAINED_JOBS = 8
RETAINED_ENTRIES = 1024
RETAINED_MANIFEST_BYTES = 1024 ** 2
RETAINED_CASES = 4096
RETAINED_CASE_BYTES = 1024 ** 2
RETAINED_WALK_ENTRIES = 8192


def retained_sources(root: Path, state: dict) -> Iterator[Path]:
    pending = [(root, 0)]
    while pending:
        directory, depth = pending.pop()
        with os.scandir(directory) as entries:
            for entry in entries:
                if state['visitedEntries'] == RETAINED_WALK_ENTRIES:
                    state['limitsReached']['walk'] = True
                    return
                state['visitedEntries'] += 1
                path = Path(entry.path)
                if entry.is_symlink():
                    state['limitsReached']['links'] = True
                    continue
                if len(str(path.relative_to(root)).encode()) > 1015:
                    state['limitsReached']['paths'] = True
                    continue
                if entry.is_dir(follow_symlinks=False):
                    if path.name.endswith('.xcresult'):
                        continue
                    if depth == 32:
                        state['limitsReached']['depth'] = True
                    else:
                        pending.append((path, depth + 1))
                elif entry.is_file(follow_symlinks=False) and path.suffix in ('.json', '.log', '.txt'):
                    yield path


def retain_native(results: Path, retained: Path, receipt: dict) -> None:
    if len(json.dumps(receipt).encode()) > 4096:
        raise ValueError('native retention receipt exceeds 4096 bytes; originals preserved')
    published = retained
    retained = published.with_name(f'.{published.name}.building')
    if published.exists() or results.is_symlink() or not results.is_dir() or retained.is_symlink():
        raise ValueError('native snapshot source or construction destination is unsafe')
    if retained.exists():
        shutil.rmtree(retained)
    retained.mkdir(parents=True)
    entries, cases, total, manifest_bytes, case_bytes = [], [], 0, 0, 0
    state = {'visitedEntries': 0, 'limitsReached': dict.fromkeys(
        ('walk', 'depth', 'paths', 'links', 'entries', 'manifest', 'data', 'cases', 'caseBytes'), False)}
    limits = state['limitsReached']
    with closing(retained_sources(results, state)) as sources:
        for source in sources:
            if len(entries) == RETAINED_ENTRIES - 1:
                limits['entries'] = True
                break
            if total == RETAINED_LIMIT:
                limits['data'] = True
                break
            relative = Path('evidence') / source.relative_to(results)
            size = source.stat().st_size
            allowance = min(4 * 1024 ** 2, RETAINED_LIMIT - total)
            entry = {'path': str(relative), 'bytes': size, 'retained': min(size, allowance), 'sha256': '0' * 64}
            entry_size = len(json.dumps(entry).encode()) + 2
            if manifest_bytes + entry_size > RETAINED_MANIFEST_BYTES - 8192:
                limits['manifest'] = True
                break
            target = retained / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.open('rb') as stream:
                data = stream.read(allowance if size <= allowance else allowance // 2)
                if size > allowance:
                    stream.seek(-allowance // 2, os.SEEK_END)
                    data += stream.read(allowance // 2)
                    limits['data'] = True
            target.write_bytes(data)
            if not limits['cases'] and not limits['caseBytes'] and (source.name in ('test.log', 'first-failure.log')
                                                                  or relative.parts[1] == 'verify'):
                for match in re.finditer(r"Test Case '-\[(\w+)\.(\w+) (\w+)\]' (passed|failed|skipped) \(([\d.]+) seconds\)",
                                         data.decode(errors='replace')):
                    if len(cases) == RETAINED_CASES:
                        limits['cases'] = True
                        break
                    target_name, owner, method, outcome, seconds = match.groups()
                    case = {'log': str(relative), 'testId': f'{target_name}/{owner}/{method}',
                            'outcome': outcome, 'seconds': float(seconds)}
                    encoded = len(json.dumps(case).encode()) + 2
                    if case_bytes + encoded > RETAINED_CASE_BYTES - 256:
                        limits['caseBytes'] = True
                        break
                    cases.append(case)
                    case_bytes += encoded
            total += len(data)
            entry.update(retained=len(data), sha256=hashlib.sha256(data).hexdigest())
            entries.append(entry)
            manifest_bytes += entry_size
    partial = (json.dumps({'cases': cases, 'truncated': any(limits.values()),
                           'completeShard': False}) + '\n').encode()
    if len(partial) > RETAINED_CASE_BYTES:
        raise ValueError('partial timings exceeded retention bound; originals preserved')
    (retained / 'partial-timings.json').write_bytes(partial)
    entries.append({'path': 'partial-timings.json', 'bytes': len(partial), 'retained': len(partial),
                    'sha256': hashlib.sha256(partial).hexdigest()})
    manifest = (json.dumps({**receipt, **state, 'files': entries, 'bytes': total,
        'truncated': any(limits.values()), 'bundlesRetained': False,
        'reason': 'interrupted or unconfirmed native transport'}) + '\n').encode()
    if len(manifest) > RETAINED_MANIFEST_BYTES:
        raise ValueError('native manifest exceeded retention bound; originals preserved')
    (retained / 'retention.json').write_bytes(manifest)
    retained.rename(published)


def retained_json(path: Path, limit: int) -> tuple[dict, bytes]:
    with path.open('rb') as source:
        content = source.read(limit + 1)
    if len(content) > limit:
        raise ValueError('retained metadata exceeds its byte bound')
    return json.loads(content), content


def verify_retained(evidence: Path, nonce: str) -> str:
    if evidence.is_symlink() or (evidence / 'retention.json').is_symlink():
        raise ValueError('unsafe retained manifest')
    receipt, content = retained_json(evidence / 'retention.json', RETAINED_MANIFEST_BYTES)
    if len(receipt['files']) > RETAINED_ENTRIES:
        raise ValueError('retained manifest exceeds its entry bound')
    if receipt['nonce'] != nonce:
        raise ValueError('retained native receipt nonce mismatch')
    for entry in receipt['files']:
        file = evidence / entry['path']
        if not file.resolve().is_relative_to(evidence.resolve()) or file.is_symlink():
            raise ValueError('unsafe retained receipt path')
        if not 0 <= entry['retained'] <= 4 * 1024 ** 2 or file.stat().st_size != entry['retained']:
            raise ValueError('retained file exceeds its byte bound')
        if hashlib.sha256(file.read_bytes()).hexdigest() != entry['sha256']:
            raise ValueError('retained native file digest mismatch')
    return hashlib.sha256(content).hexdigest()


def retained_main(nonce: str, action: str = 'retrieve', digest: str | None = None) -> int:
    if len(nonce) != 32 or any(character not in '0123456789abcdef' for character in nonce):
        raise ValueError('invalid retained native nonce')
    if action not in ('retrieve', 'recover'):
        retained = Path.home() / BASE / 'retained-native' / nonce
        originals = Path.home() / BASE / 'results' / f'gateway-{nonce}'
        building = retained.with_name(f'.{nonce}.building')
        if any(path.is_symlink() for path in (retained, originals, building)):
            raise ValueError('unsafe native recovery path')
        if action == 'recover-retained':
            if not retained.exists():
                receipt_path = originals / 'receipt.json'
                if receipt_path.is_symlink():
                    raise ValueError('unsafe original native receipt')
                source_receipt = retained_json(receipt_path, RETAINED_MANIFEST_BYTES)[0] if receipt_path.is_file() else {'nonce': nonce}
                receipt = {key: source_receipt[key] for key in ('nonce', 'commit', 'lane', 'host', 'exit', 'interrupted')
                           if key in source_receipt}
                if receipt.get('nonce') != nonce:
                    raise ValueError('native recovery receipt nonce mismatch')
                retain_native(originals, retained, receipt)
            verify_retained(retained, nonce)
            if building.exists():
                shutil.rmtree(building)
            if originals.exists():
                shutil.rmtree(originals)
            originals.with_suffix('.tar.gz').unlink(missing_ok=True)
            print(f'mini: native snapshot ready: {nonce}')
            return 0
        if action == 'ack-retained':
            if digest is None or len(digest) != 64 or any(character not in '0123456789abcdef' for character in digest):
                raise ValueError('invalid retained acknowledgement digest')
            acknowledged = retained.with_name(f'.{nonce}.ack-{digest}')
            if originals.exists() or building.exists():
                raise ValueError('native recovery cleanup is incomplete; finish recover before acknowledgement')
            if retained.exists():
                _, manifest = retained_json(retained / 'retention.json', RETAINED_MANIFEST_BYTES)
                if hashlib.sha256(manifest).hexdigest() != digest:
                    raise ValueError('retained receipt changed; evidence was not removed')
                try:
                    retained.rename(acknowledged)
                except FileNotFoundError:
                    pass
            if acknowledged.is_symlink():
                raise ValueError('unsafe acknowledged snapshot')
            if acknowledged.exists():
                shutil.rmtree(acknowledged, ignore_errors=False)
            elif building.exists() or originals.exists():
                raise ValueError('native construction is incomplete; recover it before acknowledgement')
            return 0
        if retained.is_symlink() or not retained.is_dir():
            raise ValueError('retained native evidence is unavailable; use recover for incomplete construction')
        with tarfile.open(fileobj=sys.stdout.buffer, mode='w|gz') as bundle:
            for path in sorted(retained.rglob('*')):
                if path.is_symlink() or not (path.is_file() or path.is_dir()):
                    raise ValueError('unsafe retained native evidence')
                bundle.add(path, arcname=str(path.relative_to(retained)), recursive=False)
        return 0
    ssh = ssh_command()
    source = Path(__file__).read_text()
    if action == 'recover':
        return subprocess.run([*ssh, shlex.join(['/usr/bin/python3', '-c', source, 'recover-retained', nonce])],
                              stdin=subprocess.DEVNULL).returncode
    target = ROOT / 'test-results/mini' / f'retained-{nonce}'
    staging = target.with_name(f'.{target.name}.partial')
    archive = target.with_suffix('.tar.gz')
    if any(path.is_symlink() for path in (target, staging, archive)):
        raise ValueError('unsafe local retained destination')
    if not target.exists():
        if staging.exists():
            shutil.rmtree(staging)
        archive.parent.mkdir(parents=True, exist_ok=True)
        command = shlex.join(['/usr/bin/python3', '-c', source, 'remote-retained', nonce])
        with subprocess.Popen([*ssh, command], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE) as child:
            total = 0
            with archive.open('wb') as output:
                while chunk := child.stdout.read(64 * 1024):
                    total += len(chunk)
                    if total > ARTIFACT_LIMIT:
                        child.terminate()
                        raise ValueError('retained native archive exceeds transport bound')
                    output.write(chunk)
            if child.wait():
                raise ValueError('retained native transfer failed; remote evidence remains')
        unpack_artifacts(archive, staging)
    evidence = target if target.exists() else staging
    digest = verify_retained(evidence, nonce)
    if evidence == staging:
        staging.rename(target)
    confirmed = subprocess.run([*ssh, shlex.join(['/usr/bin/python3', '-c', source, 'ack-retained', nonce, digest])],
                               stdin=subprocess.DEVNULL)
    if confirmed.returncode:
        raise ValueError(f'retained native cleanup unconfirmed; local evidence: {target}')
    archive.unlink(missing_ok=True)
    print(f'mini: retained native evidence: {target}')
    return 0


def unpack_artifacts(archive: Path, target: Path) -> None:
    total = 0
    with tarfile.open(archive, 'r|gz') as bundle:
        for member in bundle:
            name = Path(member.name)
            if name.is_absolute() or '..' in name.parts or not (member.isfile() or member.isdir()):
                raise ValueError('unsafe mini artifact member')
            total += member.size
            if total > ARTIFACT_LIMIT:
                raise ValueError('mini artifacts exceed the 2 GiB transport limit')
            destination = target / name
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                with bundle.extractfile(member) as source, destination.open('wb') as output:
                    shutil.copyfileobj(source, output)


def no_result(reason: str) -> int:
    print(NO_RESULT_LINE + ' | '.join(line.strip() for line in reason.strip().splitlines() if line.strip()), file=sys.stderr, flush=True)
    return EXIT_NO_RESULT


def no_result_reason(code: int, output: str) -> str | None:
    """Why a mini lane produced no result, read from its exit and output; None for a lane result, whatever its exit."""
    said = [line for line in output.splitlines() if line.startswith('mini: ')]
    return said[-1][len(NO_RESULT_LINE):] if code == EXIT_NO_RESULT and said and said[-1].startswith(NO_RESULT_LINE) else None


def frame(nonce: str) -> bytes:
    return f'@@tron-mini {nonce} '.encode()


def git(*args: str) -> str:
    return subprocess.run(['git', '-C', str(ROOT), *args], check=True, capture_output=True, text=True).stdout.strip()


def config(key: str) -> str:
    return subprocess.run(['git', '-C', str(ROOT), 'config', '--get', key], capture_output=True, text=True).stdout.strip()


def ssh_command() -> list[str]:
    destination = config('tron.verify.mini')
    if not destination:
        raise SystemExit('mini: no test host configured; set `git config tron.verify.mini <user@host>` '
                         '(and tron.verify.miniIdentity <key>), or run the Gateway lanes here with --gateway-host local')
    identity = config('tron.verify.miniIdentity')
    return ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4',
            *(['-i', os.path.expanduser(identity)] if identity else []), destination]


def outside_paths(args: Sequence[str]) -> list[str]:
    """Arguments naming a path outside this checkout (output files aside): the mini cannot read them. A relative
    word resolves against the Gateway package, the lane's working directory."""
    words = [word.split('=', 1)[1] if word.startswith('--') and '=' in word else word for word in args if not word.startswith(OUTPUT_OPTION)]
    package, root = ROOT / 'packages/gateway', ROOT.resolve()
    return [word for word in words if not word.startswith('-') and not (package / word).resolve().is_relative_to(root)]


def choose_host(args: Sequence[str] = ()) -> tuple[str, str]:
    """('mini' or 'local', why). The mini is the default; this Mac runs the lane only when the mini cannot."""
    if os.environ.get('TRON_UPDATE_LOCKS'):
        return 'local', 'recording goldens writes this checkout'
    if outside := outside_paths(args):
        return 'local', f'an argument names {outside[0]}, outside this checkout'
    if not config('tron.verify.mini'):
        return 'local', 'no mini is configured'
    if git('status', '--porcelain', '--untracked-files=normal'):
        return 'local', 'uncommitted changes; the mini runs a commit'
    ssh = ssh_command()
    ssh[ssh.index('ConnectTimeout=10')] = 'ConnectTimeout=5'
    try:
        probe = subprocess.run([*ssh, shlex.join(['/usr/bin/python3', '-c', Path(__file__).read_text(), 'status'])],
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return 'local', f'the mini {ssh[-1]} is unreachable: no answer within 30 s'
    try:
        status = json.loads(probe.stdout.strip().splitlines()[-1]) if probe.returncode == 0 else None
        busy, ready, load = bool(status['busy']), bool(status['ready']), float(status['load'])
    except (ValueError, IndexError, KeyError, TypeError):
        detail = ((probe.stderr if probe.returncode else probe.stdout).strip().splitlines() or ['no output'])[-1]
        return 'local', f'the mini {ssh[-1]} is unreachable: {detail}' if probe.returncode else f'the mini {ssh[-1]} answered no status: {detail}'
    if not ready:
        return 'local', f'the mini is not set up: no ~/{BASE}/tron.git'
    if busy:
        return 'local', 'the mini is busy with another job'
    return 'mini', f'reachable and idle, load {load:.1f}'


def pool_main(args: list[str]) -> int:
    host, reason = choose_host(args)
    destination = config('tron.verify.mini')
    print(f'gateway lane: on the Mac mini {destination} ({reason})' if host == 'mini' else f'gateway lane: on this Mac ({reason})',
          file=sys.stderr, flush=True)
    if host == 'mini':
        return local_main(args)
    os.execvp('python3', ['python3', str(ROOT / 'tools/verify/gateway.py'), *args])


def outputs(args: list[str]) -> tuple[list[str], list[str]]:
    """The Vitest arguments with each --outputFile path replaced by an index the mini resolves, and the local paths."""
    mapped, paths, pending = [], [], False
    for word in args:
        if pending:
            paths.append(word)
            mapped.append(f'@output:{len(paths) - 1}')
            pending = False
        elif word.startswith(OUTPUT_OPTION) and '=' in word:
            option, path = word.split('=', 1)
            paths.append(path)
            mapped.append(f'{option}=@output:{len(paths) - 1}')
        else:
            pending = word == OUTPUT_OPTION or (word.startswith(OUTPUT_OPTION + '.') and '=' not in word)
            mapped.append(word)
    return mapped, [str(ROOT / 'packages/gateway' / path) for path in paths]


def release_submission(ssh: list[str], reference: str, sha: str) -> None:
    code = f'''import subprocess, sys
command = ['git', '--git-dir={BASE}/tron.git']
status = subprocess.run([*command, 'for-each-ref', '--format=%(objectname)', sys.argv[1]], capture_output=True, text=True, check=True)
if status.stdout.strip():
    subprocess.run([*command, 'update-ref', '-d', sys.argv[1], sys.argv[2]], check=True)
'''
    result = subprocess.run([*ssh, shlex.join(['/usr/bin/python3', '-c', code, reference, sha])],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if result.returncode:
        print(f'mini: submission ref cleanup unresolved: {reference}: {result.stdout.strip()}', file=sys.stderr)


def local_main(args: list[str], lane: str = 'gateway') -> int:
    if os.environ.get('TRON_UPDATE_LOCKS'):
        return no_result('TRON_UPDATE_LOCKS would rewrite goldens in the mini checkout, not here; record locks locally')
    if lane == 'verify' and any(word == '--batch' or word == '--update-locks' or word.startswith('--update-locks=') for word in args):
        return no_result('mini verification accepts synchronous checks, not batch dispatch or golden recording')
    if lane == 'verify' and 'TRON_VERIFY_IOS_PLAN' not in os.environ:
        return no_result('whole verification requires the caller selector contract; use scripts/tron verify --ios-host mini')
    if git('status', '--porcelain', '--untracked-files=normal'):
        return no_result('the worktree has uncommitted or untracked changes; the mini runs a commit, commit first')
    try:
        ssh = ssh_command()
    except SystemExit as error:
        return no_result(str(error).removeprefix('mini: '))
    sha, destination = git('rev-parse', 'HEAD'), ssh[-1]
    expected = os.environ.get('TRON_VERIFY_COMMIT')
    if expected and expected != sha:
        return no_result(f'HEAD is {sha[:12]}, not the commit under verification {expected[:12]}')
    main = git('merge-base', 'origin/main', 'HEAD') if lane == 'verify' else None
    mapped, paths = outputs(args) if lane == 'gateway' else (args, [])
    nonce = uuid.uuid4().hex
    incoming = f'refs/tron-jobs/submissions/{nonce}'
    artifacts = ROOT / 'test-results/mini' / f'{sha[:12]}-{nonce}'
    archive = artifacts.with_suffix('.tar.gz')
    artifact_bytes, artifacts_received = 0, False
    started = time.time()
    print(f'mini: {lane} lane for {sha[:12]} on {destination}; pushing the commit', flush=True)
    push = subprocess.run(['git', '-C', str(ROOT), 'push', '--no-verify', '--quiet', f'{destination}:{BASE}/tron.git',
                           f'{sha}:{incoming}'], env={**os.environ, 'GIT_SSH_COMMAND': shlex.join(ssh[:-1])},
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if push.returncode:
        release_submission(ssh, incoming, sha)
        return no_result(f'could not push {sha[:12]} to {destination}:{BASE}/tron.git; the mini is unreachable or not set up '
                         f'(pass --gateway-host local to run here): {push.stdout.strip()}')
    print(f'mini: pushed in {time.time() - started:.1f}s', flush=True)
    wait = os.environ.get('TRON_MINI_JOB_WAIT_SECONDS')
    job = json.dumps({'sha': sha, 'main': main, 'lane': lane, 'args': mapped, 'outputs': len(paths), 'nonce': nonce, 'localRoot': str(ROOT),
                      'lockWaitSeconds': float(wait) if wait else None, 'contended': os.environ.get('TRON_TEST_CONTENDED', '0'),
                      'iosPlan': json.loads(os.environ['TRON_VERIFY_IOS_PLAN']) if lane == 'verify' and 'TRON_VERIFY_IOS_PLAN' in os.environ else None,
                      'requester': {'host': platform.node(), 'worktree': str(ROOT), 'pid': os.getpid()}})
    source = Path(__file__).read_text()
    remote = shlex.join(['/usr/bin/python3', '-c', source, 'remote', job])
    marker, code, refused, received, stopped = frame(nonce), None, None, set(), []
    environment = {key: value for key, value in os.environ.items() if key != 'TRON_VERIFY_IOS_PLAN'}
    with subprocess.Popen([*ssh, remote], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=environment) as child:
        def stop(signum, _frame):
            stopped.append(signum)
            if child.stdin and not child.stdin.closed:
                child.stdin.close()
        previous = {sig: signal.signal(sig, stop) for sig in (signal.SIGTERM, signal.SIGINT)}
        try:
            for line in child.stdout:
                if not line.startswith(marker):
                    sys.stdout.buffer.write(line)
                    sys.stdout.buffer.flush()
                    continue
                kind, _, value = line[len(marker):].strip().decode().partition(' ')
                if kind == 'output':
                    index, _, payload = value.partition(' ')
                    target = Path(paths[int(index)])
                    target.parent.mkdir(parents=True, exist_ok=True)
                    temporary = target.with_name(target.name + '.mini-tmp')
                    temporary.write_bytes(base64.b64decode(payload))
                    os.replace(temporary, target)
                    received.add(int(index))
                elif kind == 'ledger':
                    import ledger
                    ledger.append_rows(json.loads(base64.b64decode(value)))
                elif kind == 'artifact':
                    payload = base64.b64decode(value, validate=True)
                    artifact_bytes += len(payload)
                    if artifact_bytes > ARTIFACT_LIMIT:
                        raise ValueError('mini artifact archive exceeds the 2 GiB transport limit')
                    archive.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open('ab') as stream:
                        stream.write(payload)
                elif kind == 'artifact-end':
                    digest = hashlib.sha256()
                    with archive.open('rb') as stream:
                        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                            digest.update(chunk)
                    if digest.hexdigest() != value:
                        raise ValueError('mini artifact archive digest mismatch')
                    unpack_artifacts(archive, artifacts)
                    receipt = json.loads((artifacts / 'receipt.json').read_text())
                    if receipt['commit'] != sha or receipt['lane'] != lane or receipt['nonce'] != nonce:
                        raise ValueError('mini artifact receipt does not match this submission')
                    artifacts_received = True
                    if child.stdin and not child.stdin.closed:
                        child.stdin.write(f'ack {value}\n'.encode())
                        child.stdin.flush()
                    archive.unlink()
                elif kind == 'refused':
                    refused = json.loads(value)
                elif kind == 'exit':
                    code = int(value)
            child.wait()
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
            if code is None:
                release_submission(ssh, incoming, sha)
    if stopped:
        print(f'mini: stopped; the mini job was ended (lane exit {code}); not a test result', file=sys.stderr)
        return 128 + stopped[0]
    if code is None:
        return no_result(f'the session with {destination} ended (ssh exit {child.returncode}) without a result')
    if refused is not None:
        return no_result(refused)
    if lane in ('ios', 'verify'):
        if not artifacts_received:
            return no_result('the mini returned a lane exit without its artifact receipt')
        print(f'mini: artifacts: {artifacts}', flush=True)
    missing = [paths[index] for index in range(len(paths)) if index not in received]
    print(f'mini: lane exit {code} after {time.time() - started:.1f}s' + (f'; it wrote no {", ".join(missing)}' if missing else ''), flush=True)
    return code


def remote_status() -> int:
    """Whether the mini is set up, whether a job holds its job lock, and its load: the pool's availability probe."""
    lock_path = Path.home() / BASE / 'jobs/gateway.lock'
    busy = False
    if lock_path.is_file():
        with open(lock_path, 'a+') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(lock, fcntl.LOCK_UN)
            except BlockingIOError:
                busy = True
    print(json.dumps({'busy': busy, 'ready': (Path.home() / BASE / 'tron.git/HEAD').is_file(), 'load': os.getloadavg()[0]}), flush=True)
    return 0


def signal_group(pgid: int, signum: int) -> bool:
    """Signal a process group; False once it has no live member (macOS answers EPERM for an exited, unreaped one)."""
    try:
        os.killpg(pgid, signum)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def remote_main(job: dict) -> int:
    nonce, sha = job['nonce'], job['sha']
    home = Path.home()
    base = home / BASE
    repository, checkout = base / 'tron.git', base / 'jobs/gateway'
    results = base / 'results' / f'gateway-{nonce}'
    say = lambda text: print(f'mini: {text}', flush=True)  # noqa: E731
    out = sys.stdout.buffer
    cancelled = threading.Event()
    running: list[subprocess.Popen] = []
    native_confirmed = False
    preserve_results = False
    acknowledged = threading.Event()
    acknowledgement: list[str] = []

    def watch() -> None:
        for line in sys.stdin.buffer:
            if line.startswith(b'ack '):
                acknowledgement.append(line.decode().strip()[4:])
                acknowledged.set()
        cancelled.set()
        for child in running:
            if child.poll() is None:
                signal_group(child.pid, signal.SIGTERM)
    threading.Thread(target=watch, daemon=True).start()

    def finish(code: int) -> int:
        ledger_path = results / 'ledger.sqlite3'
        if any((results / name).is_symlink() for name in ('ledger.sqlite3', 'ledger.sqlite3-wal', 'ledger.sqlite3-shm')):
            out.write(b'\n' + frame(nonce) + b'refused "unsafe mini ledger spool"\n')
            code = EXIT_NO_RESULT
        elif ledger_path.is_file():
            with closing(sqlite3.connect(ledger_path.as_uri() + '?mode=ro', uri=True)) as connection:
                rows = [list(row) for row in connection.execute('SELECT * FROM results')]
            out.write(b'\n' + frame(nonce) + b'ledger ' + base64.b64encode(json.dumps(rows).encode()) + b'\n')
        out.write(b'\n' + frame(nonce) + f'exit {code}\n'.encode())
        out.flush()
        return code

    def refuse(text: str) -> int:
        """No result: the reason in its own frame, so a lane that itself exits 75 is never read as one."""
        out.write(b'\n' + frame(nonce) + f'refused {json.dumps(text)}\n'.encode())
        return finish(EXIT_NO_RESULT)

    clean = {'HOME': str(home), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin', 'PYTHONDONTWRITEBYTECODE': '1',
             'LANG': os.environ.get('LANG', 'en_US.UTF-8'), **{key: os.environ[key] for key in ('USER', 'LOGNAME', 'SHELL') if key in os.environ}}

    def run(*command: str, cwd: Path | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(command, cwd=cwd, env=clean, stdin=subprocess.DEVNULL, text=True, capture_output=True)

    def stream(*command: str, cwd: Path, env: dict | None = None) -> int:
        """Run a long child in its own process group with its output streamed; a cancel stops the whole group, as
        verify stops a local step. Whatever is left of the group is killed before the job lock is released, so
        nothing still runs in the checkout the next job cleans. A signal exit is 128+n."""
        with subprocess.Popen(command, cwd=cwd, env=env or clean, stdin=subprocess.DEVNULL, start_new_session=True) as child:
            running.append(child)
            try:
                if cancelled.is_set():
                    signal_group(child.pid, signal.SIGTERM)
                code = child.wait()
            finally:
                running.remove(child)
                signal_group(child.pid, signal.SIGKILL)
                for _ in range(100):
                    if not signal_group(child.pid, 0):
                        break
                    time.sleep(0.1)
        return 128 - code if code < 0 else code

    if not (repository / 'HEAD').is_file():
        return refuse(f'{repository} is not a bare repository; set it up with `git init --bare {repository}`')
    try:
        (base / 'jobs').mkdir(exist_ok=True)
        with open(base / 'jobs/gateway.lock', 'a+') as lock:
            announced, waiting, cap = 0.0, time.monotonic(), job.get('lockWaitSeconds')
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if cancelled.is_set():
                        return refuse('stopped while waiting for the mini job lock')
                    lock.seek(0)
                    holder = lock.read().strip() or 'an unrecorded job'
                    if cap is not None and time.monotonic() - waiting >= cap:
                        return refuse(f'waited {round(time.monotonic() - waiting)}s for the mini job lock, held by {holder}; '
                                      'the caller caps that wait, no result')
                    if time.time() - announced >= 60:
                        say(f'waiting for the mini job lock, held by {holder}')
                        announced = time.time()
                    time.sleep(min(2, cap) if cap else 2)
            if cancelled.is_set():
                return refuse('stopped before preparing the mini checkout')
            lock.seek(0)
            lock.truncate()
            lock.write(json.dumps({**job['requester'], 'sha': sha}))
            lock.flush()

            retained_root = base / 'retained-native'
            if job['lane'] in ('ios', 'verify') and retained_root.exists():
                with os.scandir(retained_root) as pending:
                    if sum(1 for _ in islice(pending, RETAINED_JOBS)) == RETAINED_JOBS:
                        return refuse('native evidence retention is full; recover/retrieve pending evidence before another native job')
            prepared = time.time()
            if (checkout / '.git').exists():
                steps = [('git', '-C', str(checkout), 'checkout', '--quiet', '--detach', '--force', sha),
                         ('git', '-C', str(checkout), 'clean', '-ffdxq', '-e', '/packages/gateway/node_modules',
                          '-e', '/packages/ios-app/TronMobile.xcodeproj')]
            else:
                steps = [('git', '-C', str(repository), 'worktree', 'prune'),
                         ('git', '-C', str(repository), 'worktree', 'add', '--quiet', '--detach', str(checkout), sha)]
            for command in steps:
                result = run(*command)
                if result.returncode:
                    return refuse(f'{shlex.join(command)} failed: {(result.stdout + result.stderr).strip()}')
            checkout = checkout.resolve()
            head = run('git', '-C', str(checkout), 'rev-parse', 'HEAD').stdout.strip()
            dirty = run('git', '-C', str(checkout), 'status', '--porcelain', '--untracked-files=normal').stdout.strip()
            if head != sha or dirty:
                return refuse(f'the mini checkout is not exactly {sha} (HEAD {head or "unknown"}; changes: {dirty or "none"})')
            run('git', '-C', str(repository), 'update-ref', 'refs/tron-jobs/gateway', sha)
            if job['lane'] == 'verify':
                bound = run('git', '-C', str(repository), 'update-ref', 'refs/remotes/origin/main', job['main'])
                if bound.returncode:
                    return refuse(f'cannot bind the caller main baseline: {bound.stderr.strip()}')

            pins = dict(line.split('=', 1) for line in (checkout / 'config/ci-toolchain.env').read_text().splitlines()
                        if '=' in line and not line.lstrip().startswith('#'))
            resolved = run(str(checkout / 'scripts/tron-node'))
            node = Path(resolved.stdout.strip()) if resolved.returncode == 0 else None
            if node is None:
                return refuse(f'no pinned Node on the mini: {resolved.stderr.strip()}\n'
                              f'    install it there with: cd {checkout} && scripts/tron-node install')
            architecture = {'arm64': 'ARM64', 'aarch64': 'ARM64', 'x86_64': 'X64'}.get(platform.machine(), platform.machine().upper())
            digest = hashlib.sha256(node.read_bytes()).hexdigest()
            npm = run(str(checkout / 'scripts/tron-node'), 'exec', 'npm', '--version').stdout.strip()
            expected = {'node digest': (digest, pins.get(f'TRON_NODE_{architecture}_RUNTIME_SHA256')),
                        'npm': (npm, pins.get('TRON_NODE_NPM_VERSION'))}
            differing = [f'{name} {actual or "missing"}, pinned {pin}' for name, (actual, pin) in expected.items() if actual != pin]
            if differing:
                return refuse(f'the mini toolchain differs from the pins at {sha[:12]}: {"; ".join(differing)} ({node})\n'
                              f'    reinstall it there with: cd {checkout} && scripts/tron-node install')
            version = (checkout / '.node-version').read_text().strip()
            say(f'checkout {sha[:12]} ready; Node v{version} ({digest[:12]}) npm {npm}, macOS {platform.mac_ver()[0]}, '
                f'Python {platform.python_version()}')

            inputs = run('git', '-C', str(checkout), 'rev-parse', *(f'HEAD:packages/gateway/{path}' for path in
                                                                   ('package.json', 'package-lock.json', 'third_party'))).stdout
            install = hashlib.sha256(f'{inputs}{digest}'.encode()).hexdigest()
            stamp = checkout / 'packages/gateway/node_modules/.tron-mini-install'
            if not stamp.is_file() or stamp.read_text() != install:
                say('Gateway dependencies changed; npm ci')
                installed = stream(str(checkout / 'scripts/tron-node'), 'exec', 'npm', '--prefix', 'packages/gateway', 'ci', '--include=dev',
                                   cwd=checkout)
                if installed:
                    return refuse(f'npm ci failed (exit {installed})')
                stamp.parent.mkdir(exist_ok=True)
                stamp.write_text(install)
            say(f'prepared in {time.time() - prepared:.1f}s; running the lane, load {os.getloadavg()[0]:.1f}')
            if cancelled.is_set():
                return refuse('stopped before the lane started')

            results.mkdir(parents=True, exist_ok=True)
            clean['TRON_TEST_LEDGER'] = str(results / 'ledger.sqlite3')
            clean['TRON_TEST_CONTENDED'] = job.get('contended', '0')
            if job['lane'] in ('ios', 'verify'):
                results.mkdir(parents=True, exist_ok=True)
                archive = results.with_suffix('.tar.gz')
                try:
                    command = ([str(checkout / 'scripts/tron-ios-test'), *job['args']] if job['lane'] == 'ios'
                               else ['/usr/bin/python3', str(checkout / 'tools/verify/verify.py'), *job['args']])
                    env = {**clean, 'PATH': f'{node.parent}:{clean["PATH"]}',
                           'TRON_VERIFY_EXECUTION_HOST': 'mini',
                           'TRON_CI_TOOLS_DIR': str(base / '.ci-tools'),
                           'TRON_IOS_TEST_RESULTS_DIR': str(results / 'ios'),
                           'TRON_PROFILE_RESULTS_DIR': str(results / 'profiles'),
                           'TRON_IOS_E2E_STATE_DIR': str(checkout / '.scratch/mini-e2e')}
                    if job.get('iosPlan') is not None:
                        env['TRON_VERIFY_IOS_PLAN'] = json.dumps(job['iosPlan'])
                        (results / 'execution-plan.json').write_text(env['TRON_VERIFY_IOS_PLAN'] + '\n')
                    code = stream(*command, cwd=checkout, env=env)
                    if job['lane'] == 'verify':
                        report = checkout / 'test-results/verify' / f'{sha}.json'
                        if report.is_file():
                            shutil.copy2(report, results / 'verify.json', follow_symlinks=False)
                        logs = checkout / 'test-results/verify' / sha
                        if logs.is_dir():
                            shutil.copytree(logs, results / 'verify', symlinks=True)
                    e2e = checkout / '.scratch/mini-e2e'
                    if e2e.is_dir():
                        for source in [e2e / 'results', e2e / 'attempts', *sorted(e2e.glob('lane*/results'))]:
                            if source.is_dir():
                                target = results / 'e2e' / source.relative_to(e2e)
                                shutil.copytree(source, target, symlinks=True, ignore=shutil.ignore_patterns('latest', 'latest-ui'))
                    receipt = {'commit': sha, 'nonce': nonce, 'lane': job['lane'], 'exit': code,
                               'interrupted': cancelled.is_set() or code >= 128,
                               'host': platform.node(), 'args': job['args'], 'completedAt': time.time()}
                    (results / 'receipt.json').write_text(json.dumps(receipt))
                    total = 0
                    with tarfile.open(archive, 'w:gz', dereference=True) as bundle:
                        for path in sorted(results.rglob('*')):
                            if path.is_symlink() or not (path.is_file() or path.is_dir()):
                                raise ValueError('unsafe mini artifact source')
                            if path.parent == results and path.name in ('ledger.sqlite3', 'ledger.sqlite3-wal', 'ledger.sqlite3-shm'):
                                continue
                            total += path.stat().st_size if path.is_file() else 0
                            if total > ARTIFACT_LIMIT:
                                raise ValueError('mini artifacts exceed the 2 GiB transport limit')
                            bundle.add(path, arcname=str(path.relative_to(results)), recursive=False)
                    digest = hashlib.sha256()
                    with archive.open('rb') as payload_stream:
                        for chunk in iter(lambda: payload_stream.read(64 * 1024), b''):
                            digest.update(chunk)
                            out.write(b'\n' + frame(nonce) + b'artifact ' + base64.b64encode(chunk) + b'\n')
                    out.write(frame(nonce) + f'artifact-end {digest.hexdigest()}\n'.encode())
                    out.flush()
                    if not cancelled.is_set():
                        acknowledged.wait(10)
                    native_confirmed = acknowledgement == [digest.hexdigest()] and not receipt['interrupted']
                    return finish(code)
                except (OSError, ValueError, tarfile.TarError) as error:
                    return refuse(f'{job["lane"]} invocation/artifacts failed: {error}')
                finally:
                    if not native_confirmed and results.exists():
                        preserve_results = True
                        retain_native(results, base / 'retained-native' / nonce,
                                      {'commit': sha, 'nonce': nonce, 'lane': job['lane'], 'host': platform.node(),
                                       'interrupted': cancelled.is_set()})
                        preserve_results = False
                    archive.unlink(missing_ok=True)
                    shutil.rmtree(results, ignore_errors=True)
            if job['lane'] == 'node':
                root_node = job['args'][:1] == ['--root']
                arguments = job['args'][1:] if root_node else job['args']
                return finish(stream('/usr/bin/python3', str(checkout / 'tools/verify/ledger.py'), 'exec', 'node',
                                     str(checkout / 'scripts/tron-node'), 'exec', 'node', '--test', '--test-concurrency=1',
                                     '--test-reporter=' + str(checkout / 'tools/verify/ledger-node.mjs'), *arguments,
                                     cwd=checkout if root_node else checkout / 'packages/gateway'))
            if job['lane'] == 'python':
                doctor = (run('/bin/bash', str(checkout / 'tools/proof/bootstrap.sh'), 'doctor', cwd=checkout)
                          if (checkout / 'tools/proof/dafny.pin').is_file() else None)
                if doctor and doctor.returncode != 0:
                    return refuse(f'no pinned Dafny on the mini: {(doctor.stderr or doctor.stdout).strip()}\n'
                                  f'    install it there with: cd {checkout} && scripts/tron proof bootstrap')
                env = {**clean, 'PATH': f'{node.parent}:{clean["PATH"]}'}
                return finish(stream('/bin/bash', '-c', 'exec 2>&1\n' + job['args'][0], cwd=checkout, env=env))
            results.mkdir(parents=True, exist_ok=True)
            try:
                files = [results / f'output-{index}' for index in range(job['outputs'])]
                args = []
                for word in job['args']:
                    for index, path in enumerate(files):
                        word = word.replace(f'@output:{index}', str(path))
                    args.append(word.replace(job['localRoot'], str(checkout)))
                code = stream('/usr/bin/python3', str(checkout / 'tools/verify/gateway.py'), *args, cwd=checkout / 'packages/gateway')
                for index, path in enumerate(files):
                    if path.is_file():
                        content = path.read_text(errors='replace').replace(str(checkout), job['localRoot'])
                        out.write(b'\n' + frame(nonce) + f'output {index} '.encode() + base64.b64encode(content.encode()) + b'\n')
                return finish(code)
            finally:
                shutil.rmtree(results, ignore_errors=True)
    finally:
        if not preserve_results:
            shutil.rmtree(results, ignore_errors=True)
        run('git', '-C', str(repository), 'update-ref', '-d', f'refs/tron-jobs/submissions/{nonce}', sha)


if __name__ == '__main__':
    if sys.argv[1:2] in (['retrieve'], ['recover'], ['recover-retained'], ['remote-retained'], ['ack-retained']):
        sys.exit(retained_main(sys.argv[2], sys.argv[1], sys.argv[3] if len(sys.argv) > 3 else None))
    if sys.argv[1:2] == ['remote']:
        sys.exit(remote_main(json.loads(sys.argv[2])))
    if sys.argv[1:2] == ['status']:
        sys.exit(remote_status())
    try:
        if sys.argv[1:2] == ['python'] and len(sys.argv) != 3:
            sys.exit('usage: mini.py python <command>')
        if sys.argv[1:2] == ['pool']:
            sys.exit(pool_main(sys.argv[2:]))
        if sys.argv[1:2] == ['ios']:
            parser = argparse.ArgumentParser(add_help=False)
            parser.add_argument('--ios-host', choices=('mini', 'local'), default='mini')
            option, args = parser.parse_known_args(sys.argv[2:])
            if option.ios_host == 'local':
                script = str(ROOT / 'scripts/tron-ios-test')
                os.execv(script, [script, *args])
            sys.exit(local_main(args, 'ios'))
        sys.exit(local_main(sys.argv[2:], sys.argv[1]) if sys.argv[1:2] in (['python'], ['node'], ['verify']) else local_main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(no_result(str(error)))
