#!/usr/bin/env python3
"""Operator-run local reinstall preparation. Never replaces or launches an app."""
import argparse
import contextlib
import ctypes
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import uuid

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / 'tools/home-layout'))
import home_layout  # noqa: E402

STAGED_REGISTRY = Path(home_layout.REGISTRY).name
MAX_ENTRIES = 1_000_000
MAX_JSON = 256 * 1024 * 1024
LIBC = ctypes.CDLL(None, use_errno=True)


class Stop(Exception):
    """Public messages are bounded categories, never raw subprocess/state output."""


def require(condition, message):
    if not condition:
        raise Stop(message)


def exists(path):
    try:
        os.lstat(path)
        return True
    except FileNotFoundError:
        return False


def safe_path(path):
    path = Path(os.path.abspath(path))
    if sys.platform == 'darwin' and path.parts[1:2] in (('tmp',), ('var',)):
        path = Path('/private') / path.relative_to('/')
    for part in [*reversed(path.parents), path]:
        if exists(part):
            require(not part.is_symlink(), 'unsafe-path: symlinked path component; resolve ownership first')
    return path


def private_dir(path, create=False):
    path = safe_path(path)
    if create and not exists(path):
        path.mkdir(mode=0o700)
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
            and info.st_mode & 0o077 == 0,
            'unsafe-state-directory: expected an owner-only directory')
    return path


def owned_container(path):
    """A container may be readable; other users must not replace its children."""
    path = safe_path(path)
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
            and info.st_mode & 0o722 == 0o700,
            'unsafe-state-container: expected owned directory with owner rwx and no group/other write access')
    require(acl_digest(path) is None,
            'unsafe-state-container: ACL requires an explicit ownership review')
    return path


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_json(path, value):
    private_dir(path.parent)
    fd, temporary = tempfile.mkstemp(prefix='.receipt-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, sort_keys=True, separators=(',', ':'))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        sync_dir(path.parent)
    finally:
        if exists(temporary):
            os.unlink(temporary)


def read_json(path, limit=MAX_JSON):
    safe_path(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and info.st_mode & 0o077 == 0 and info.st_nlink == 1 and info.st_size <= limit,
                'unsafe-receipt: expected bounded owner-only regular file')
        return json.load(stream)


@contextlib.contextmanager
def exclusive(root):
    private_dir(root, create=True)
    require(acl_digest(root) is None, 'unsafe-state-directory: maintenance root must not grant access through an ACL')
    fd = os.open(root / 'lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and info.st_mode & 0o077 == 0 and info.st_nlink == 1,
                'unsafe-lock: expected private regular lock file')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Stop('busy: another reinstall or cutover command is running') from None
        yield
    finally:
        os.close(fd)


def digest_file(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode), 'unsupported-file: expected regular file')
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
        after = os.fstat(stream.fileno())
        require((before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                == (after.st_size, after.st_mtime_ns, after.st_ctime_ns),
                'source-changed: file changed while hashing; stop all writers')
        return digest.hexdigest()


def acl_digest(path):
    if sys.platform != 'darwin':
        return None
    LIBC.acl_get_link_np.argtypes = [ctypes.c_char_p, ctypes.c_int]
    LIBC.acl_get_link_np.restype = ctypes.c_void_p
    LIBC.acl_to_text.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ssize_t)]
    LIBC.acl_to_text.restype = ctypes.c_void_p
    LIBC.acl_free.argtypes = [ctypes.c_void_p]
    acl = LIBC.acl_get_link_np(os.fsencode(path), 0x100)
    if not acl and ctypes.get_errno() == errno.ENOENT:
        path.lstat()
        return None
    require(bool(acl), 'metadata-unreadable: cannot inspect ACL')
    text = None
    try:
        size = ctypes.c_ssize_t()
        text = LIBC.acl_to_text(acl, ctypes.byref(size))
        require(bool(text), 'metadata-unreadable: cannot serialize ACL')
        return hashlib.sha256(ctypes.string_at(text, size.value)).hexdigest()
    finally:
        if text:
            LIBC.acl_free(text)
        LIBC.acl_free(acl)


def xattr_digests(path):
    if sys.platform != 'darwin':
        return {name: hashlib.sha256(os.getxattr(path, name, follow_symlinks=False)).hexdigest()
                for name in sorted(os.listxattr(path, follow_symlinks=False))}
    LIBC.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    LIBC.listxattr.restype = ctypes.c_ssize_t
    LIBC.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                             ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    LIBC.getxattr.restype = ctypes.c_ssize_t
    encoded = os.fsencode(path)
    size = LIBC.listxattr(encoded, None, 0, 1)
    require(0 <= size <= 1024 * 1024, 'metadata-unreadable: invalid extended attribute inventory')
    if not size:
        return {}
    names = ctypes.create_string_buffer(size)
    require(LIBC.listxattr(encoded, names, size, 1) == size,
            'metadata-changed: extended attribute inventory changed')
    result = {}
    for name in sorted(names.raw.rstrip(b'\0').split(b'\0')):
        size = LIBC.getxattr(encoded, name, None, 0, 0, 1)
        require(0 <= size <= MAX_JSON, 'metadata-unreadable: extended attribute exceeds supported bounds')
        value = ctypes.create_string_buffer(max(1, size))
        require(LIBC.getxattr(encoded, name, value, size, 0, 1) == size,
                'metadata-changed: extended attribute changed while reading')
        result[os.fsdecode(name)] = hashlib.sha256(value.raw[:size]).hexdigest()
    return result


def tree_manifest(root, share=None):
    """No file contents in evidence; no symlink traversal, devices or sockets.

    `share(path, is_directory)` narrows the inventory: 'none' leaves the path out, 'mixed' asks again
    for each child, 'all' takes the whole subtree."""
    safe_path(root)
    result = {}
    def visit(path, depth, whole):
        require(depth <= 128 and len(result) < MAX_ENTRIES,
                'inventory-limit: tree exceeds supported traversal bounds')
        info = path.lstat()
        held = 'all' if whole else share(path, stat.S_ISDIR(info.st_mode))
        if held == 'none':
            return
        require(stat.S_ISLNK(info.st_mode) or stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode),
                'special-file: sockets/devices/FIFOs need an owner decision before backup')
        require(info.st_uid in (os.getuid(), 0), 'foreign-owner: review tree ownership')
        require(not getattr(info, 'st_flags', 0) & (2 | 4 | 0x20000 | 0x40000),
                'immutable-file: flags prevent a verified portable backup')
        item = {'mode': stat.S_IMODE(info.st_mode), 'acl': acl_digest(path)}
        item['xattrs'] = xattr_digests(path)
        if stat.S_ISLNK(info.st_mode):
            target = os.readlink(path)
            item.update(type='link', target=target)
        elif stat.S_ISREG(info.st_mode):
            item.update(type='file', size=info.st_size, sha256=digest_file(path))
        elif stat.S_ISDIR(info.st_mode):
            item.update(type='dir')
        else:
            raise Stop('special-file: sockets/devices/FIFOs need an owner decision before backup')
        result[str(path.relative_to(root))] = item
        if item['type'] == 'dir':
            for child in sorted(path.iterdir()):
                visit(child, depth + 1, held == 'all')
    visit(root, 0, share is None)
    return result


def manifest_digest(manifest):
    return hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def copied_entry_matches(actual, expected):
    if sys.platform != 'darwin':
        return actual == expected
    def portable(entry):
        return {**entry, 'xattrs': {name: value for name, value in entry['xattrs'].items()
                                  if name not in ('com.apple.provenance', 'com.apple.quarantine')}}
    actual_quarantine = 'com.apple.quarantine' in actual['xattrs']
    expected_quarantine = 'com.apple.quarantine' in expected['xattrs']
    return actual_quarantine == expected_quarantine and portable(actual) == portable(expected)


def copied_tree_matches(actual, expected):
    if actual is None or expected is None:
        return actual is expected
    return actual.keys() == expected.keys() and all(
        copied_entry_matches(actual[name], item) for name, item in expected.items())


def retired_channel_matches(actual, expected):
    if actual is None or expected is None:
        return actual is expected
    if actual.keys() != expected.keys():
        return False
    for name, item in expected.items():
        current = actual[name]
        if name == '.' and item['type'] == current['type'] == 'dir':
            if not copied_entry_matches(current, item):
                return False
            if current['xattrs'].get('com.apple.quarantine') != item['xattrs'].get('com.apple.quarantine'):
                return False
        elif current != item:
            return False
    return True


def sync_tree(root, manifest):
    for name, item in manifest.items():
        if item['type'] == 'file':
            fd = os.open(root / name, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
    for name, item in reversed(list(manifest.items())):
        if item['type'] == 'dir':
            sync_dir(root / name)


def copy_metadata(source, destination, data=False):
    if sys.platform == 'darwin':
        LIBC.copyfile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
        flags = 7 | (8 if data else 0) | (1 << 18) | (1 << 19)
        if LIBC.copyfile(os.fsencode(source), os.fsencode(destination), None, flags):
            raise OSError(ctypes.get_errno(), 'copyfile failed')
        if source.is_symlink():
            os.chmod(destination, stat.S_IMODE(source.lstat().st_mode), follow_symlinks=False)
    else:
        if data:
            shutil.copyfile(source, destination, follow_symlinks=False)
        shutil.copystat(source, destination, follow_symlinks=False)


def copy_tree(source, destination, expected, scratch, share=None):
    """Resume only the recorded copy, publishing each leaf after its data is synced."""
    if exists(destination):
        actual = tree_manifest(destination)
        for name, item in actual.items():
            require(name in expected and item['type'] == expected[name]['type'],
                    'backup-collision: unexpected entry in partial backup; preserve for review')
            if item['type'] != 'dir':
                require(copied_entry_matches(item, expected[name]),
                        'backup-corrupt: partial backup entry differs; preserve for review')
    else:
        actual = {}
    for name, item in expected.items():
        src, dst = source / name, destination / name
        if item['type'] == 'dir':
            if not exists(dst):
                dst.mkdir(mode=0o700)
            continue
        if name in actual:
            continue
        fd, temporary = tempfile.mkstemp(dir=scratch, prefix='.copy-')
        os.close(fd)
        temporary = Path(temporary)
        try:
            if item['type'] == 'link':
                temporary.unlink()
                temporary.symlink_to(item['target'])
                copy_metadata(src, temporary)
            else:
                copy_metadata(src, temporary, data=True)
                with temporary.open('rb') as stream:
                    os.fsync(stream.fileno())
            rename_exclusive(temporary, dst)
            sync_dir(dst.parent)
        finally:
            if exists(temporary):
                temporary.unlink()
    for name, item in reversed(list(expected.items())):
        if item['type'] == 'dir':
            copy_metadata(source / name, destination / name)
    require(tree_manifest(source, share) == expected, 'source-changed: backup source changed; do not proceed')
    require(copied_tree_matches(tree_manifest(destination), expected),
            'backup-mismatch: copied bytes or metadata differ')
    sync_tree(destination, expected)


def rename_exclusive(source, destination):
    """Atomic no-clobber rename; a pre-check plus ordinary rename is insufficient."""
    if sys.platform == 'darwin':
        function, flags = LIBC.renamex_np, 4
        function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        result = function(os.fsencode(source), os.fsencode(destination), flags)
    else:
        function = LIBC.renameat2
        function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = function(-100, os.fsencode(source), -100, os.fsencode(destination), 1)
    if result:
        raise OSError(ctypes.get_errno(), 'exclusive rename failed')
    sync_dir(source.parent)
    if source.parent != destination.parent:
        sync_dir(destination.parent)


def command(argv, category, timeout=1200, env=None, accepted=(0,)):
    with tempfile.TemporaryFile() as output:
        child = subprocess.Popen([str(arg) for arg in argv], stdout=output, stderr=subprocess.STDOUT,
                                 env=env, start_new_session=True)
        try:
            code = child.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                raise Stop(f'{category}: owned command did not stop; do not retry until its owner resolves it') from None
            raise Stop(f'{category}: command interrupted or timed out; checkpoint not accepted; inspect before retry') from None
        require(code in accepted,
                f'{category}: command exited {code}; no checkpoint accepted; consult the owning runbook check')
        require(output.tell() <= MAX_JSON, f'{category}: output exceeded bounds')
        output.seek(0)
        return output.read()


def stopped_launchd_job(output):
    """True only for a top-level job that reports no process at all."""
    lines = output.decode(errors='replace').splitlines()
    states = [line for line in lines if re.fullmatch(r'\tstate = .+', line)]
    return states == ['\tstate = not running'] and not any(re.fullmatch(r'\tpid = \d+', line) for line in lines)


class MacPlatform:
    def __init__(self, home, installed=Path('/Applications/Tron.app')):
        self.home, self.installed = home, installed

    def validate_app(self, app, current_contract=True):
        safe_path(app)
        require(app.is_dir(), 'app-missing: provide the prepared signed Release Tron.app')
        command(['/usr/bin/codesign', '--verify', '--deep', '--strict', app], 'app-signature')
        info_path = safe_path(app / 'Contents/Info.plist')
        require(info_path.stat().st_size <= 1024 * 1024, 'app-metadata: Info.plist exceeds bounds')
        with info_path.open('rb') as stream:
            info = plistlib.load(stream)
        require(info.get('CFBundleIdentifier') == 'com.tron.mac', 'wrong-app: expected Release com.tron.mac')
        signed = command(['/usr/bin/codesign', '-d', '--verbose=4', app], 'app-identity').decode()
        team = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', signed, re.M)
        cdhash = re.search(r'^CDHash=([a-f0-9]+)$', signed, re.M)
        require(team and cdhash, 'app-identity: team-signed app required')
        if current_contract:
            env = dict(os.environ, TRON_APP_PATH=str(app))
            command(['/bin/bash', REPO / 'scripts/verify-mac-install.sh', '--artifact-only'],
                    'artifact-validation', env=env)
            command([REPO / 'packages/mac-app/scripts/verify-signed-pi-payload.sh', app], 'signed-runtime-smoke')
        return {'team': team[1], 'cdhash': cdhash[1],
                'resources': digest_file(safe_path(app / 'Contents/_CodeSignature/CodeResources'))}

    def offline(self):
        for key in ('PI_CODING_AGENT_DIR', 'TRON_DATA_DIR', 'TRON_HOME_NAME',
                    'PI_AGENT_BROWSER_CONFIG', 'PI_AGENT_BROWSER_GLOBAL_CONFIG'):
            require(not os.environ.get(key), 'custom-configuration: environment override requires a reviewed owner decision')
            value = command(['/bin/launchctl', 'getenv', key], 'environment-probe', timeout=15)
            require(not value.strip(), 'custom-configuration: launchd override requires a reviewed owner decision')
        command(['/bin/launchctl', 'print', f'gui/{os.getuid()}'], 'launchd-probe', timeout=15)
        for label in ('com.tron.server', 'com.tron.server.dev', 'com.tron.gateway.dev', 'com.tron.mac.native-host'):
            result = subprocess.run(['/bin/launchctl', 'print', f'gui/{os.getuid()}/{label}'],
                                    capture_output=True, timeout=15)
            if result.returncode == 0:
                if label in ('com.tron.server', 'com.tron.mac.native-host') and stopped_launchd_job(result.stdout):
                    continue
                raise Stop(f'service-loaded: {label}; choose Quit Tron in the menu bar and wait for it to finish')
            require(b'Could not find service' in result.stderr,
                    'launchd-probe: could not distinguish absent service from inspection failure')
        for port in (9847, 9848):
            result = subprocess.run(['/usr/sbin/lsof', '-nP', f'-iTCP:{port}', '-sTCP:LISTEN', '-t'],
                                    capture_output=True, timeout=15)
            require(result.returncode == 1 and not result.stdout and not result.stderr,
                    f'port-busy-or-unreadable: {port}; stop its owner through normal controls')
        processes = command(['/bin/ps', '-axo', 'pid=,command='], 'process-probe', timeout=15).decode()
        for line in processes.splitlines():
            pid, _, text = line.strip().partition(' ')
            if pid == str(os.getpid()):
                continue
            if re.search(r'Tron\.app/Contents/MacOS|Tron Native Host\.app|Tron Agent\.app|'
                         r'Gateway/app/dist/index\.js|gateway/dist/index\.js|tron-dev.*__|'
                         r'gateway-payload-deploy\.mjs|async-runner\.(?:ts|js)|'
                         r'pi-coding-agent/.*/(cli|index)\.js|(?:^|/)(?:pi|npm|pnpm|yarn)(?: |$)', text):
                raise Stop('writer-present: stop standalone clients, workers and package operations before retry')

    def verify_installed(self, require_bundled=False):
        command([REPO / 'scripts/verify-mac-install.sh', *(['--require-bundled'] if require_bundled else [])], 'installed-verification',
                env=dict(os.environ, TRON_APP_PATH=str(self.installed)))
        command(['/usr/bin/python3', REPO / 'scripts/tron-fsevents-guard', 'install'],
                'fsevents-guard-install', timeout=180)
        loaded = command(['/bin/launchctl', 'print', f'gui/{os.getuid()}/com.tron.server'],
                         'agent-authority-verification', timeout=15).decode()
        for key in ('PI_CODING_AGENT_DIR', 'TRON_DATA_DIR', 'TRON_HOME_NAME'):
            require(not re.search(r'^\s*' + key + r'\s*(?:=>|=)', loaded, re.M),
                    'custom-agent-authority: loaded job has a path override; verify its owner before proceeding')


class Reinstall:
    kind = 'reinstall'
    phases = ('awaiting-offline', 'backing-up', 'awaiting-replacement', 'awaiting-resume', 'verified')
    confirmation_options = {'confirm_offline': 'attest successful old-helper retirement and all writers stopped'}

    def __init__(self, home, platform):
        self.home, self.platform = safe_path(home), platform
        self.store = self.home / '.tron-maintenance'
        self.receipt = None
        self.layout_paths = None
        self.operation = None

    def source_agent(self):
        return self.home / '.tron/agent'

    def layout(self):
        owned_container(self.home / '.tron')
        private_dir(self.source_agent())

    def excluded_state_entries(self):
        return {'agent'}

    def save(self, phase=None):
        if phase:
            self.receipt['phase'] = phase
        write_json(self.operation / 'receipt.json', self.receipt)

    def begin(self, app, predecessor=None, bundled_selection=None):
        self.layout()
        require(app != self.platform.installed, 'app-path: prepared app must be separate from installed app')
        candidate = self.platform.validate_app(app)
        original = self.platform.validate_app(self.platform.installed, current_contract=False)
        require(candidate['team'] == original['team'], 'signer-mismatch: replacement and installed app have different teams')
        identifier = str(uuid.uuid4())
        revision = command(['/usr/bin/git', '-C', REPO, 'rev-parse', 'HEAD'], 'source-revision', timeout=15).decode().strip()
        require(re.fullmatch(r'[0-9a-f]{40,64}', revision), 'source-revision: expected immutable commit identity')
        try:
            registry = home_layout.load(REPO)
        except home_layout.LayoutError:
            registry = None
        require(registry is not None and not home_layout.shape(registry),
                'layout-registry: the Tron-home registry is unreadable or invalid; run scripts/tron home-layout check')
        self.operation = private_dir(self.store / identifier, create=True)
        write_json(self.operation / STAGED_REGISTRY, registry)
        self.layout_paths = None
        self.receipt = {'schema': 1, 'id': identifier, 'kind': self.kind, 'home': str(self.home),
                        'app': str(app), 'candidate': candidate, 'original': original,
                        'sourceRevision': revision,
                        'layoutRegistrySha256': hashlib.sha256((self.operation / STAGED_REGISTRY).read_bytes()).hexdigest(),
                        'phase': 'awaiting-offline', 'components': {}, 'sourcePaths': {}}
        if predecessor is not None:
            self.receipt['predecessorOperationId'] = predecessor['id']
        if bundled_selection is not None:
            self.receipt['bundledSelection'] = bundled_selection
        self.save()
        write_json(self.store / 'active.json', {'schema': 1, 'id': identifier})

    def load(self):
        active = read_json(self.store / 'active.json', 4096)
        require(isinstance(active, dict) and set(active) == {'schema', 'id'} and active['schema'] == 1
                and isinstance(active['id'], str) and str(uuid.UUID(active['id'])) == active['id'],
                'invalid-active-receipt: preserve maintenance directory for review')
        self.operation = private_dir(self.store / active['id'])
        receipt = read_json(self.operation / 'receipt.json', 65536)
        require(isinstance(receipt, dict) and receipt.get('schema') == 1 and receipt.get('id') == active['id']
                and receipt.get('home') == str(self.home) and receipt.get('kind') == self.kind
                and receipt.get('phase') in self.phases and isinstance(receipt.get('components'), dict)
                and isinstance(receipt.get('sourcePaths'), dict)
                and isinstance(receipt.get('app'), str) and Path(receipt['app']).is_absolute(),
                'invalid-operation: wrong workflow, home, schema or phase; inspect the active receipt')
        self.receipt = receipt
        safe_path(Path(receipt['app']))

    @property
    def stable_channel(self):
        return safe_path(self.home / '.tron/state/payloads/stable')

    def selection_evidence(self):
        selection = self.receipt.get('bundledSelection')
        require(isinstance(selection, dict) and selection.get('phase') in ('retiring', 'selected')
                and isinstance(selection.get('manifestDigest'), str),
                'selection-journal: preserve the operation for review')
        owner = self.operation
        if 'operationId' in selection:
            operation_id = selection['operationId']
            require(isinstance(operation_id, str) and str(uuid.UUID(operation_id)) == operation_id,
                    'selection-journal: invalid evidence owner')
            owner = private_dir(self.store / operation_id)
        proof = read_json(owner / 'stable-selection.json')
        require(manifest_digest(proof) == selection['manifestDigest'],
                'selection-journal: retired payload inventory changed')
        return selection, proof, owner

    def verify_bundled_selection(self, before_activation=True):
        if 'bundledSelection' not in self.receipt:
            return
        selection, proof, owner = self.selection_evidence()
        require(selection['phase'] == 'selected',
                'selection-incomplete: rerun --select-bundled-offline before the snapshot')
        retired = owner / 'retired-stable-payloads'
        require(retired_channel_matches(tree_manifest(retired) if exists(retired) else None, proof),
                'selection-backup-changed: preserve the retired payload store for review')
        if before_activation:
            require(not exists(self.stable_channel),
                    'selection-changed: Stable payload store reappeared; do not activate')

    def select_bundled_offline(self):
        """Retire the whole channel atomically, never individual pointers.

        The launcher already selects the signed bundle when the channel is
        absent. Keeping current/previous/pending and their payloads together
        outside the live store also prevents pending-attempt rollback from
        starting pre-migration code. Recovery only finishes this retirement;
        restoring old selection is a separate version-specific rollback.
        """
        require(self.kind == 'reinstall' and self.receipt['phase'] == 'awaiting-offline'
                and not self.receipt['components'],
                'selection-order: select bundled before --confirm-offline, using mac reinstall')
        self.platform.offline()
        require(self.platform.validate_app(Path(self.receipt['app'])) == self.receipt['candidate'],
                'artifact-changed: prepared app differs from recorded artifact')
        require(self.platform.validate_app(self.platform.installed, False) == self.receipt['original'],
                'old-app-changed: retire selection before replacing the app')
        source = self.stable_channel
        for container in (source.parent.parent, source.parent):
            if exists(container):
                owned_container(container)
        retired = self.operation / 'retired-stable-payloads'
        if 'bundledSelection' not in self.receipt:
            require(not exists(retired), 'selection-collision: preserve existing retirement evidence')
            if exists(source):
                owned_container(source)
                require(source.stat().st_dev == self.operation.stat().st_dev,
                        'cross-filesystem: selection retirement must be atomic')
            proof = tree_manifest(source) if exists(source) else None
            write_json(self.operation / 'stable-selection.json', proof)
            self.receipt['bundledSelection'] = {'phase': 'retiring', 'manifestDigest': manifest_digest(proof)}
            self.save()
        selection, proof, _ = self.selection_evidence()
        if selection['phase'] == 'retiring':
            if exists(source):
                require(proof is not None and not exists(retired) and tree_manifest(source) == proof,
                        'selection-source-changed: do not choose between competing stores')
                self.platform.offline()
                rename_exclusive(source, retired)
            require(retired_channel_matches(tree_manifest(retired) if exists(retired) else None, proof),
                    'selection-retirement-incomplete: preserve the operation and retry after inspection')
            require(not exists(source), 'selection-changed: another writer recreated the channel')
            self.receipt['bundledSelection']['phase'] = 'selected'
            self.save()
        self.verify_bundled_selection()
        print('Bundled Gateway selected for the next installed-app launch. Retired channel retained; no process started.\n'
              'Finish every offline migration, then run --confirm-offline. Never resume the old app against migrated state.')

    def share(self, source):
        """The Tron-home registry's verdict for a `~/.tron` source: what it does not back up stays out of the inventory."""
        tron = self.home / '.tron'
        if tron not in source.parents:
            return None
        if self.layout_paths is None:
            try:
                registry = read_json(self.operation / STAGED_REGISTRY)
            except (OSError, ValueError, Stop):
                registry = None
            require(registry is not None and not home_layout.shape(registry),
                    'layout-registry: this operation has no valid staged Tron-home registry; begin again with --restart')
            require(hashlib.sha256((self.operation / STAGED_REGISTRY).read_bytes()).hexdigest()
                    == self.receipt.get('layoutRegistrySha256'),
                    'layout-registry-digest: staged registry differs from the operation receipt; preserve it and begin again with --restart')
            self.layout_paths = registry['paths']
        return lambda path, directory: home_layout.backup_decision(self.layout_paths, str(path.relative_to(tron)), directory)

    def inventory(self, source):
        return tree_manifest(source, self.share(source)) if exists(source) else None

    def sources(self):
        sources = {'agent': self.source_agent(), 'old-app': self.platform.installed,
                   'browser-config': self.home / '.pi/config/pi-agent-browser-native/config.json',
                   'machine-group': self.home / '.tron/state/machine-group-id'}
        for path in sorted((self.home / '.tron').iterdir()):
            if path.name not in self.excluded_state_entries() \
                    and self.share(path)(path, path.is_dir() and not path.is_symlink()) != 'none':
                name = 'tron-' + hashlib.sha256(os.fsencode(path.name)).hexdigest()[:16]
                require(name not in sources, 'inventory-collision: state component labels collide')
                sources[name] = path
        return sources

    def verify_backups(self):
        sources = self.sources()
        require(set(sources) == set(self.receipt['components']), 'state-inventory-changed: state roots changed since backup')
        require(self.receipt['sourcePaths'] == {name: str(path) for name, path in sources.items()},
                'source-map-changed: backup ownership mapping changed')
        for name in sources:
            expected = read_json(self.operation / f'{name}.json')
            require(manifest_digest(expected) == self.receipt['components'][name], 'manifest-corrupt: evidence changed')
            backup = self.operation / 'backups' / name
            require(copied_tree_matches(tree_manifest(backup) if exists(backup) else None, expected),
                    f'backup-mismatch: {name}; preserve operation and repair backup before proceeding')

    def restart(self):
        previous = self.receipt
        require(previous['phase'] != 'verified', 'restart-verified: use --finish')
        installed = self.platform.validate_app(self.platform.installed, current_contract=False)
        require(installed in (previous['original'], previous['candidate']),
                'restart-installed-app: installed app is neither the recorded original nor candidate')
        require(self.platform.validate_app(Path(previous['app'])) == previous['candidate'],
                'artifact-changed: prepared app differs from recorded artifact')
        selection = previous.get('bundledSelection')
        carried_selection = None
        if selection is not None:
            require(selection.get('phase') == 'selected',
                    'restart-incomplete-step: finish --select-bundled-offline first')
            _, proof, owner = self.selection_evidence()
            require(retired_channel_matches(tree_manifest(owner / 'retired-stable-payloads')
                                            if exists(owner / 'retired-stable-payloads') else None, proof),
                    'restart-selection-evidence: selected payload evidence is incomplete')
            carried_selection = {**selection, 'operationId': owner.name}
        components = previous['components']
        if previous['phase'] == 'awaiting-offline':
            require(not components, 'restart-incomplete-step: unexpected partial backup inventory')
        elif previous['phase'] not in ('backing-up', 'awaiting-replacement', 'awaiting-resume'):
            raise Stop('restart-incomplete-step: operation phase cannot be restarted')
        self.begin(Path(previous['app']), predecessor=previous, bundled_selection=carried_selection)

    def abandon(self):
        """Archive a superseded active operation without touching its evidence or services.

        Refused after an irreversible step (Stable-channel retirement, or a replacement
        already recorded as awaiting-resume) unless the installed app is this operation's
        candidate. The artifact path is not consulted: a superseded candidate may be gone.
        """
        require(self.receipt['phase'] != 'verified', 'abandon-verified: use --finish to archive a verified operation')
        installed = self.platform.validate_app(self.platform.installed, current_contract=False)
        require(installed in (self.receipt['original'], self.receipt['candidate']),
                'abandon-installed-app: installed app is neither the recorded original nor candidate; preserve operation for review')
        candidate_installed = installed == self.receipt['candidate']
        irreversible = 'bundledSelection' in self.receipt or self.receipt['phase'] == 'awaiting-resume'
        require(candidate_installed or not irreversible,
                'abandon-irreversible: an irreversible step has passed; resume or roll back this operation instead')
        self.receipt['abandonment'] = {'installedApp': 'candidate' if candidate_installed else 'original'}
        self.save()
        rename_exclusive(self.store / 'active.json', self.operation / 'abandoned-active.json')
        print(f'Abandoned operation {self.operation.name} at phase {self.receipt["phase"]}. Its receipt, backups and retired '
              'payloads are retained; no app or service changed. Begin the replacement with --app <Release.app>.')

    def backup(self):
        sources = self.sources()
        backups = private_dir(self.operation / 'backups', create=True)
        scratch = private_dir(self.operation / 'scratch', create=True)
        components = self.receipt['components']
        if not components:
            sizes = {}
            self.receipt['sourcePaths'] = {name: str(path) for name, path in sources.items()}
            for name, source in sources.items():
                print(f'Inventorying {name}…', flush=True)
                manifest = self.inventory(source)
                require(manifest is not None or name not in ('agent', 'old-app'),
                        f'missing-source: required {name} is absent')
                write_json(self.operation / f'{name}.json', manifest)
                components[name] = manifest_digest(manifest)
                sizes[name] = sum(item.get('size', 0) for item in (manifest or {}).values())
            require(shutil.disk_usage(self.store).free > self.required_copy_bytes(sizes) + 512 * 1024 * 1024,
                    'disk-space: insufficient room for verified backups plus 512 MiB reserve')
            self.save('backing-up')
        require(set(components) == set(sources), 'invalid-receipt: backup inventory is incomplete')
        for name, source in sources.items():
            expected = read_json(self.operation / f'{name}.json')
            require(manifest_digest(expected) == components[name], 'manifest-corrupt: backup evidence changed')
            require(self.inventory(source) == expected,
                    f'source-changed: {name} differs from the frozen backup inventory')
            if expected is None:
                continue
            print(f'Checking/copying {name} backup…', flush=True)
            copy_tree(source, backups / name, expected, scratch, self.share(source))
        self.platform.offline()

    def required_copy_bytes(self, sizes):
        return sum(sizes.values())

    def prepare(self):
        self.verify_bundled_selection()
        self.backup()
        self.save('awaiting-replacement')

    def before_activation(self, app_replaced=False):
        self.verify_bundled_selection()
        self.layout()
        self.verify_backups()
        for name, source in self.sources().items():
            if name == 'old-app' and app_replaced:
                continue
            expected = read_json(self.operation / f'{name}.json')
            require(manifest_digest(expected) == self.receipt['components'][name], 'manifest-corrupt: evidence changed')
            require(self.inventory(source) == expected,
                    f'source-changed: {name}; do not replace from an outdated backup')

    def verify(self):
        identity = self.platform.validate_app(self.platform.installed)
        require(identity == self.receipt['candidate'], 'wrong-installed-app: Finder replacement does not match prepared artifact')
        self.layout()
        self.verify_bundled_selection(before_activation=False)
        if 'bundledSelection' in self.receipt:
            self.platform.verify_installed(require_bundled=True)
        else:
            self.platform.verify_installed()
        self.save('verified')

    def run(self, args):
        actions = [args.status, args.verify, args.finish, getattr(args, 'restart', False),
                   getattr(args, 'select_bundled_offline', False), getattr(args, 'abandon', False)]
        actions.extend(getattr(args, name, False) for name in self.confirmation_options)
        require(sum(bool(value) for value in actions) <= 1,
                'arguments: choose exactly one action or offline confirmation')
        with exclusive(self.store):
            if getattr(args, 'abandon', False):
                require(exists(self.store / 'active.json'), 'abandon-absent: no active maintenance operation')
                self.load()
                require(not args.app, 'arguments: --abandon cannot be combined with --app; begin the new operation afterwards')
                self.abandon()
                return
            if exists(self.store / 'active.json'):
                self.load()
                if args.app:
                    require(str(safe_path(args.app)) == self.receipt['app'], 'different-artifact: finish active operation first')
            else:
                require(args.app is not None and not args.status and not args.verify,
                        'artifact-required: begin with --app <path>/Tron.app')
                self.begin(safe_path(args.app))
            print(f'Operation: {self.operation}\nPhase: {self.receipt["phase"]}', flush=True)
            if args.status:
                return
            if getattr(args, 'restart', False):
                require(not args.app, 'arguments: --restart cannot be combined with --app')
                self.restart()
                print('Restarted with a fresh inventory. Prior operation evidence retained; run --confirm-offline after stopping writers.')
                return
            if getattr(args, 'select_bundled_offline', False):
                self.select_bundled_offline()
                return
            if args.verify:
                require(self.receipt['phase'] in ('awaiting-replacement', 'awaiting-resume', 'verified'),
                        'not-prepared: complete offline preparation before verification')
                self.verify()
                print('Installed app and supervised Gateway verified. Complete the continuity checks in the runbook; backups retained.')
                return
            if self.receipt['phase'] == 'verified':
                print('This operation is verified. Use --finish to archive its receipt before a future reinstall.')
                if args.finish:
                    (self.store / 'active.json').unlink()
                    sync_dir(self.store)
                return
            require(not args.finish, 'not-verified: cannot archive an unfinished operation')
            if not self.offline_confirmation(args):
                return
            self.platform.offline()
            require(self.platform.validate_app(Path(self.receipt['app'])) == self.receipt['candidate'],
                    'artifact-changed: prepared app differs from recorded artifact')
            if self.receipt['phase'] in ('awaiting-offline', 'backing-up'):
                require(self.platform.validate_app(self.platform.installed, False) == self.receipt['original'],
                        'old-app-changed: installed app changed before retirement/backup')
                self.layout()
                self.prepare()
            self.continue_offline(args)

    def offline_confirmation(self, args):
        if args.confirm_offline:
            return True
        print('NEXT: In the old app, use Quit Tron and wait for its successful Gateway and native-helper retirement.\n'
              'Stop Debug, standalone clients, workers and package operations. Re-run with --confirm-offline.\n'
              'This flag attests to successful retirement and writer quiescence; process absence alone is insufficient.')
        return False

    def continue_offline(self, args):
        installed = self.platform.validate_app(self.platform.installed, False)
        app_replaced = installed == self.receipt['candidate']
        require(app_replaced or installed == self.receipt['original'],
                'unexpected-installed-app: preserve operation for review')
        self.before_activation(app_replaced=app_replaced)
        if app_replaced:
            self.save('awaiting-resume')
            print('NEXT: Launch /Applications/Tron.app, approve any required Login Item prompts, then run with --verify.')
            return
        print(f'NEXT: In Finder replace /Applications/Tron.app with {self.receipt["app"]}.\n'
              'Launch the replacement and approve any required Login Item prompts. Then re-run with --verify.\n'
              f'Rollback app and verified data backups: {self.operation / "backups"}')


def parser(description=__doc__, confirmation_options=None):
    result = argparse.ArgumentParser(description=description)
    result.add_argument('--app', type=Path, help='prepared signed Release artifact (first invocation only)')
    for name, help_text in (confirmation_options or Reinstall.confirmation_options).items():
        result.add_argument('--' + name.replace('_', '-'), action='store_true', help=help_text)
    result.add_argument('--select-bundled-offline', action='store_true',
                        help='attest all writers stopped; retire Stable external selection before the offline snapshot (reinstall only)')
    result.add_argument('--status', action='store_true', help='show the saved checkpoint')
    result.add_argument('--verify', action='store_true', help='verify user-installed and resumed app')
    result.add_argument('--finish', action='store_true', help='archive verified operation; retain all backups')
    result.add_argument('--restart', action='store_true', help='start a fresh operation when no incomplete step or irreversible transition remains')
    result.add_argument('--abandon', action='store_true',
                        help='archive a superseded active operation before an irreversible step, or when its candidate is installed; keeps all evidence')
    return result


def main(workflow=Reinstall, arguments=None):
    args = parser(workflow.__doc__ or __doc__, workflow.confirmation_options).parse_args(arguments)
    try:
        require(sys.platform == 'darwin' and os.getuid() != 0, 'platform: run as the logged-in macOS user, without sudo')
        home = safe_path(pwd.getpwuid(os.getuid()).pw_dir)
        require(safe_path(Path.home()) == home, 'home-override: run from the logged-in user environment; no state changed')
        workflow(home, MacPlatform(home)).run(args)
        return 0
    except (Stop, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        if isinstance(error, Stop):
            message = str(error)
        elif isinstance(error, OSError):
            message = f'filesystem-or-tool-failure: errno={error.errno}; operation preserved; resolve access/space then retry'
        elif isinstance(error, subprocess.TimeoutExpired):
            message = 'probe-timeout: system inspection did not finish; no checkpoint accepted; retry after inspection'
        else:
            message = 'invalid-state: malformed receipt or metadata; operation preserved for review'
        print(f'STOP: {message}', file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print('Interrupted; operation preserved. Re-run the same command after confirming writers remain offline.',
              file=sys.stderr)
        return 130


if __name__ == '__main__':
    sys.exit(main())
