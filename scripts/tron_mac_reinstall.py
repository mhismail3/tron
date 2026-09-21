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
MAX_ENTRIES = 1_000_000
MAX_JSON = 256 * 1024 * 1024
LIBC = ctypes.CDLL(None, use_errno=True)


class Stop(Exception):
    """Public messages are bounded categories, never raw subprocess/state output."""


def require(condition, message):
    if not condition:
        raise Stop(message)


def exists(path):
    # lexists() also hides permission/I/O errors as absence. Optional credentials
    # and browser state must never silently disappear from the backup inventory.
    try:
        os.lstat(path)
        return True
    except FileNotFoundError:
        return False


def safe_path(path):
    path = Path(os.path.abspath(path))
    # macOS publishes these two system aliases; user-owned symlink components
    # remain forbidden. This also makes receipts invariant to /tmp spelling.
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
        # Keep the inode stable: unlinking a held lock admits a second owner.
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
        # Darwin represents an existing item's absent extended ACL as ENOENT.
        path.lstat()  # A vanished item is not an empty ACL.
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
    # Python's os xattr API is Linux-only in some supported Python builds.
    LIBC.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    LIBC.listxattr.restype = ctypes.c_ssize_t
    LIBC.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                             ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    LIBC.getxattr.restype = ctypes.c_ssize_t
    encoded = os.fsencode(path)
    size = LIBC.listxattr(encoded, None, 0, 1)  # XATTR_NOFOLLOW
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


def tree_manifest(root):
    """No file contents in evidence; no symlink traversal, devices or sockets."""
    safe_path(root)
    result = {}
    def visit(path, depth):
        require(depth <= 128 and len(result) < MAX_ENTRIES,
                'inventory-limit: tree exceeds supported traversal bounds')
        info = path.lstat()
        require(stat.S_ISLNK(info.st_mode) or stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode),
                'special-file: sockets/devices/FIFOs need an owner decision before backup')
        require(info.st_uid in (os.getuid(), 0), 'foreign-owner: review tree ownership')
        require(not getattr(info, 'st_flags', 0) & (2 | 4 | 0x20000 | 0x40000),
                'immutable-file: flags prevent a verified portable backup')
        item = {'mode': stat.S_IMODE(info.st_mode), 'acl': acl_digest(path)}
        item['xattrs'] = xattr_digests(path)
        if stat.S_ISLNK(info.st_mode):
            target = os.readlink(path)
            # Preserve links as bytes. Copying never traverses them.
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
                visit(child, depth + 1)
    visit(root, 0)
    return result


def manifest_digest(manifest):
    return hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def copied_entry_matches(actual, expected):
    if sys.platform != 'darwin':
        return actual == expected
    # macOS assigns the copying process's provenance even when copyfile succeeds
    # at copying all xattrs. Do not forge/remove that OS-owned attribution.
    # Live source comparisons remain exact; retirement has its own root-only rule.
    def portable(entry):
        return {**entry, 'xattrs': {name: value for name, value in entry['xattrs'].items()
                                  if name != 'com.apple.provenance'}}
    return portable(actual) == portable(expected)


def copied_tree_matches(actual, expected):
    if actual is None or expected is None:
        return actual is expected
    return actual.keys() == expected.keys() and all(
        copied_entry_matches(actual[name], item) for name, item in expected.items())


def retired_channel_matches(actual, expected):
    # Darwin can reassign provenance on the directory passed to renamex_np.
    # Only that root attribution may differ; nested entries and all other
    # metadata remain exact. Keep the original source manifest unchanged.
    if actual is None or expected is None:
        return actual is expected
    return actual.keys() == expected.keys() and all(
        copied_entry_matches(actual[name], item)
        if name == '.' and item['type'] == actual[name]['type'] == 'dir'
        else actual[name] == item
        for name, item in expected.items())


def sync_tree(root, manifest):
    # Receipt durability must not get ahead of the copied file data/metadata.
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
            # COPYFILE_STAT does not preserve a link's own mode on macOS. Never
            # follow the target: it may be missing or outside the backed-up tree.
            os.chmod(destination, stat.S_IMODE(source.lstat().st_mode), follow_symlinks=False)
    else:
        if data:
            shutil.copyfile(source, destination, follow_symlinks=False)
        shutil.copystat(source, destination, follow_symlinks=False)


def copy_tree(source, destination, expected, scratch):
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
        # Temporary leaves live outside the copied tree. A crash cannot expose
        # partial bytes as a valid file or send the next copy through a symlink.
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
    require(tree_manifest(source) == expected, 'source-changed: backup source changed; do not proceed')
    require(copied_tree_matches(tree_manifest(destination), expected),
            'backup-mismatch: copied bytes or metadata differ')
    sync_tree(destination, expected)


def rename_exclusive(source, destination):
    """Atomic no-clobber rename; a pre-check plus ordinary rename is insufficient."""
    if sys.platform == 'darwin':
        function, flags = LIBC.renamex_np, 4  # RENAME_EXCL
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
    # Capture into an anonymous file, not unbounded RAM or user-facing logs.
    with tempfile.TemporaryFile() as output:
        child = subprocess.Popen([str(arg) for arg in argv], stdout=output, stderr=subprocess.STDOUT,
                                 env=env, start_new_session=True)
        try:
            code = child.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            # Only signal this command's owned process group, never a live app or
            # service. Do not escalate to SIGKILL when cooperative exit fails.
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
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
            command([REPO / 'packages/mac-app/scripts/test-signed-pi-payload-smoke.sh', app], 'signed-runtime-smoke')
        # Include CodeResources: the Mach-O cdhash alone does not identify resources.
        return {'team': team[1], 'cdhash': cdhash[1],
                'resources': digest_file(safe_path(app / 'Contents/_CodeSignature/CodeResources'))}

    def offline(self):
        for key in ('PI_CODING_AGENT_DIR', 'TRON_DATA_DIR', 'TRON_HOME_NAME', 'TRON_AGENT_DIR_NAME',
                    'PI_AGENT_BROWSER_CONFIG', 'PI_AGENT_BROWSER_GLOBAL_CONFIG'):
            require(not os.environ.get(key), 'custom-configuration: environment override requires a reviewed owner decision')
            value = command(['/bin/launchctl', 'getenv', key], 'environment-probe', timeout=15)
            require(not value.strip(), 'custom-configuration: launchd override requires a reviewed owner decision')
        command(['/bin/launchctl', 'print', f'gui/{os.getuid()}'], 'launchd-probe', timeout=15)
        for label in ('com.tron.server', 'com.tron.server.dev', 'com.tron.server.preview',
                      'com.tron.server.dev-takeover', 'com.tron.gateway.dev', 'com.tron.mac.native-host'):
            result = subprocess.run(['/bin/launchctl', 'print', f'gui/{os.getuid()}/{label}'],
                                    capture_output=True, timeout=15)
            if result.returncode == 0:
                raise Stop(f'service-loaded: {label}; finish retirement/Pause in the owning app')
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
                         r'agent-home-(?:preflight|migration)\.js|'
                         r'pi-coding-agent/.*/(cli|index)\.js|(?:^|/)(?:pi|npm|pnpm|yarn)(?: |$)', text):
                raise Stop('writer-present: stop standalone clients, workers and package operations before retry')

    def verify_installed(self, require_bundled=False):
        command([REPO / 'scripts/verify-mac-install.sh', *(['--require-bundled'] if require_bundled else [])], 'installed-verification',
                env=dict(os.environ, TRON_APP_PATH=str(self.installed)))
        loaded = command(['/bin/launchctl', 'print', f'gui/{os.getuid()}/com.tron.server'],
                         'agent-authority-verification', timeout=15).decode()
        # The canonical verifier pins the selected signed runtime. With no path
        # overrides in that job, its current config resolves the Stable default.
        for key in ('PI_CODING_AGENT_DIR', 'TRON_DATA_DIR', 'TRON_HOME_NAME', 'TRON_AGENT_DIR_NAME'):
            require(not re.search(r'^\s*' + key + r'\s*(?:=>|=)', loaded, re.M),
                    'custom-agent-authority: loaded job has a path override; verify its owner before proceeding')


MAX_ARCHIVE_ENTRIES = 4_000_000
RECOVERY_SCHEMA = 1
RECOVERY_RELATIVE_ROOT = Path('pre-cutover')


def _archive_entry(path, root, relative):
    info = path.lstat()
    require(stat.S_ISLNK(info.st_mode) or stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode),
            'archive-special-file: sockets/devices/FIFOs are not supported')
    require(info.st_uid in (os.getuid(), 0), 'archive-foreign-owner: review recovery tree ownership')
    item = {'mode': stat.S_IMODE(info.st_mode), 'uid': info.st_uid, 'gid': info.st_gid,
            'acl': acl_digest(path), 'xattrs': xattr_digests(path)}
    if stat.S_ISLNK(info.st_mode):
        item.update(type='link', target=os.readlink(path))
    elif stat.S_ISREG(info.st_mode):
        item.update(type='file', size=info.st_size, sha256=digest_file(path))
    else:
        item.update(type='dir')
    digest_item = dict(item)
    if relative == '.':
        digest_item['xattrs'] = {k: v for k, v in item['xattrs'].items()
                                 if k != 'com.apple.provenance'}
    return item, digest_item


def archive_fingerprint(root, copy_provenance=False):
    """Stream a bounded archive closure digest without retaining its tree."""
    root = safe_path(root)
    root_info = root.lstat()
    require((stat.S_ISDIR(root_info.st_mode) or stat.S_ISREG(root_info.st_mode))
            and root_info.st_uid in (os.getuid(), 0),
            'archive-root: expected an owned regular file or directory')
    digest = hashlib.sha256()
    count = 0
    root_entry = None

    def visit(path, relative):
        nonlocal count, root_entry
        count += 1
        require(count <= MAX_ARCHIVE_ENTRIES, 'archive-inventory-limit: recovery tree exceeds bounds')
        item, digest_item = _archive_entry(path, root, relative)
        if copy_provenance:
            digest_item['xattrs'] = {k: v for k, v in item['xattrs'].items()
                                     if k != 'com.apple.provenance'}
        if relative == '.':
            root_entry = item
        digest.update(json.dumps({'path': relative, 'entry': digest_item}, sort_keys=True,
                                 separators=(',', ':')).encode())
        digest.update(b'\n')
        if item['type'] == 'dir':
            for child in sorted(path.iterdir(), key=lambda value: value.name):
                visit(child, relative + '/' + child.name if relative != '.' else child.name)

    visit(root, '.')
    return {'entries': count, 'sha256': digest.hexdigest(), 'rootXattrs': root_entry['xattrs']}


def _safe_relative(value):
    path = Path(value)
    require(not path.is_absolute() and str(path) not in ('', '.'), 'archive-path: expected relative path')
    require('..' not in path.parts and path.parts[0] not in ('', '.'), 'archive-path: traversal rejected')
    return path


def _archive_paths(root):
    stack = [(root, '.')]
    while stack:
        path, relative = stack.pop()
        yield path, relative
        if path.is_dir() and not path.is_symlink():
            children = sorted(path.iterdir(), key=lambda value: value.name, reverse=True)
            stack.extend((child, relative + '/' + child.name if relative != '.' else child.name)
                         for child in children)


def _safe_archive_child(root, relative):
    if relative == '.':
        return root
    relative_path = _safe_relative(relative)
    current = root
    for part in relative_path.parts[:-1]:
        current = current / part
        info = current.lstat()
        require(stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode),
                'archive-manifest: symlinked ancestor rejected')
    return root / relative_path


def _verify_recorded_manifest(manifest_path, backup_path):
    raw = read_json(manifest_path)
    if raw is None:
        require(not exists(backup_path), 'archive-manifest: absent source was copied')
        return {'entries': 0, 'absent': True}
    require(isinstance(raw, dict) and isinstance(raw.get('tree'), dict)
            and isinstance(raw.get('owners'), dict), 'archive-manifest: invalid manifest')
    expected = raw['tree']
    owners = raw['owners']
    require(exists(backup_path), 'archive-manifest: recorded backup is absent')
    backup_path = safe_path(backup_path)
    backup_info = backup_path.lstat()
    require((stat.S_ISDIR(backup_info.st_mode) or stat.S_ISREG(backup_info.st_mode))
            and backup_info.st_uid in (os.getuid(), 0),
            'archive-manifest: unsafe backup component')
    for relative, expected_entry in expected.items():
        actual_path = _safe_archive_child(backup_path, relative)
        require(exists(actual_path), 'archive-manifest: recorded entry is absent')
        actual, _ = _archive_entry(actual_path, backup_path, relative)
        actual = {key: value for key, value in actual.items() if key not in ('uid', 'gid')}
        require(copied_entry_matches(actual, expected_entry),
                'archive-manifest: recorded entry differs')
        owner = owners.get(relative)
        require(isinstance(owner, dict) and actual_path.lstat().st_uid == owner.get('uid')
                and actual_path.lstat().st_gid == owner.get('gid'),
                'archive-manifest: recorded owner differs')
    actual_count = 0
    expected_names = set(expected)
    for _, relative in _archive_paths(backup_path):
        actual_count += 1
        require(relative in expected_names, 'archive-manifest: unexpected entry present')
    require(actual_count == len(expected), 'archive-manifest: entry count differs')
    return {'entries': actual_count, 'absent': False}


def _verify_recorded_components(root):
    pre = root / 'pre-migration'
    names = ('delegated-project', 'machine-id-legacy', 'stable', 'debug',
             'delegated-temp', 'old-app', 'browser-project-config', 'browser-global-config')
    result = {}
    for name in names:
        result[name] = _verify_recorded_manifest(pre / 'manifests' / (name + '.json'),
                                                  pre / 'backups' / name)
    return result


def _verify_restore_fixture(root):
    pre = root / 'pre-migration'
    result = {}
    for name in ('delegated-project', 'machine-id-legacy', 'stable', 'debug',
                 'delegated-temp', 'old-app', 'browser-project-config', 'browser-global-config'):
        backup = pre / 'backups' / name
        restored = pre / 'restore-fixture' / name
        if not exists(backup) or not exists(restored):
            require(not exists(backup) and not exists(restored),
                    'archive-restore: backup/restore component presence differs')
            result[name] = None
            continue
        expected = archive_fingerprint(backup, copy_provenance=True)
        actual = archive_fingerprint(restored, copy_provenance=True)
        require(expected['entries'] == actual['entries'] and expected['sha256'] == actual['sha256'],
                'archive-restore: isolated fixture differs from backup')
        result[name] = {'entries': expected['entries'], 'sha256': expected['sha256']}
    return result


def _verify_post_components(operation, receipt):
    result = {}
    for name, expected_digest in receipt.get('components', {}).items():
        path = operation / 'backups' / name
        manifest = None if not exists(path) else tree_manifest(path)
        require(manifest_digest(manifest) == expected_digest,
                'archive-post: recorded component digest mismatch')
        closure = None if manifest is None else archive_fingerprint(path)
        result[name] = {'receiptDigest': expected_digest, 'closure': closure}
    selection = receipt.get('bundledSelection')
    retired = operation / 'retired-stable-payloads'
    if selection is not None:
        require(isinstance(selection, dict) and isinstance(selection.get('manifestDigest'), str),
                'archive-post: invalid bundled selection evidence')
        require(exists(retired), 'archive-post: retired payload store is absent')
        result['retired-stable-payloads'] = archive_fingerprint(retired)
    return result


def _verify_checkpoint_evidence(root):
    pre = root / 'pre-migration'
    verified = read_json(pre / 'verified.json')
    require(isinstance(verified, dict), 'archive-checkpoint: invalid verification evidence')
    require(verified.get('isolatedRestoreMatches') is True,
            'archive-checkpoint: isolated restore evidence is not accepted')
    for relative in ('backups', 'restore-fixture', 'manifests'):
        private_dir(pre / relative)
    evidence = pre / 'data-verified-pending-groups.json'
    expected = verified.get('dataEvidenceSha256')
    require(isinstance(expected, str) and re.fullmatch(r'[0-9a-f]{64}', expected),
            'archive-checkpoint: evidence digest missing')
    require(digest_file(evidence) == expected, 'archive-checkpoint: evidence digest mismatch')
    return {'verified': True, 'dataEvidence': str(evidence.relative_to(root)),
            'dataEvidenceSha256': expected, 'components': _verify_recorded_components(root),
            'restoreFixture': _verify_restore_fixture(root)}


class RecoveryArchive:
    """Archive-only registration for a completed maintenance operation."""
    def __init__(self, home, operation_id):
        require(re.fullmatch(r'[0-9a-fA-F-]{36}', operation_id), 'archive-operation: invalid operation id')
        self.home = safe_path(home)
        self.store = private_dir(self.home / '.tron-maintenance')
        self.operation = private_dir(self.store / operation_id)
        self.operation_id = operation_id
        self.receipt = read_json(self.operation / 'receipt.json')
        components = self.receipt.get('components')
        require(self.receipt.get('schema') == 1 and self.receipt.get('kind') == 'reinstall'
                and self.receipt.get('id') == operation_id
                and self.receipt.get('phase') == 'verified'
                and self.receipt.get('home') == str(self.home)
                and isinstance(self.receipt.get('sourceRevision'), str)
                and isinstance(components, dict)
                and all(isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9._-]{1,128}', name)
                        and isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value)
                        for name, value in components.items()),
                'archive-operation: expected completed verified operation')
        require(not exists(self.store / 'active.json'),
                'archive-operation: active maintenance operation exists')
        self.descriptor_path = self.operation / 'recovery.json'
        self.destination = self.operation / RECOVERY_RELATIVE_ROOT

    def _descriptor(self):
        if not exists(self.descriptor_path):
            return None
        descriptor = read_json(self.descriptor_path)
        require(descriptor.get('schema') == RECOVERY_SCHEMA and
                descriptor.get('kind') == 'tron-recovery-bundle' and
                descriptor.get('operationId') == self.operation_id,
                'archive-descriptor: invalid or mismatched descriptor')
        require(descriptor.get('destination') == str(RECOVERY_RELATIVE_ROOT),
                'archive-descriptor: unexpected destination')
        require(descriptor.get('phase') in ('prepared', 'verified') and
                isinstance(descriptor.get('historicalSource'), str) and
                Path(descriptor['historicalSource']).is_absolute() and
                isinstance(descriptor.get('sourceDevice'), int) and
                isinstance(descriptor.get('sourceInode'), int) and
                isinstance(descriptor.get('entries'), int) and
                1 <= descriptor['entries'] <= MAX_ARCHIVE_ENTRIES and
                re.fullmatch(r'[0-9a-f]{64}', str(descriptor.get('archiveDigest', ''))) and
                isinstance(descriptor.get('sourceRootXattrs'), dict) and
                isinstance(descriptor.get('checkpoint'), dict) and
                isinstance(descriptor.get('post'), dict) and
                isinstance(descriptor.get('sourceRevision'), str),
                'archive-descriptor: incomplete integrity fields')
        return descriptor

    def verify(self):
        descriptor = self._descriptor()
        require(descriptor is not None, 'archive-descriptor: relocation has not been registered')
        require(exists(self.destination), 'archive-checkpoint: destination is absent')
        fingerprint = archive_fingerprint(self.destination)
        require(fingerprint['entries'] == descriptor['entries'] and
                fingerprint['sha256'] == descriptor['archiveDigest'],
                'archive-checkpoint: archive closure digest mismatch')
        source_xattrs = descriptor.get('sourceRootXattrs', {})
        current_xattrs = fingerprint['rootXattrs']
        changed_xattrs = set(source_xattrs) ^ set(current_xattrs)
        require(changed_xattrs <= {'com.apple.provenance'},
                'archive-checkpoint: root metadata changed outside provenance')
        for name in set(source_xattrs) & set(current_xattrs) - {'com.apple.provenance'}:
            require(source_xattrs[name] == current_xattrs[name],
                    'archive-checkpoint: root metadata changed')
        checkpoint = _verify_checkpoint_evidence(self.destination)
        require(descriptor.get('checkpoint') == checkpoint,
                'archive-checkpoint: checkpoint evidence changed')
        post = _verify_post_components(self.operation, self.receipt)
        require(descriptor.get('post') == post, 'archive-post: retained snapshot changed')
        return {'operationId': self.operation_id, 'phase': 'verified',
                'destination': str(self.destination), 'entries': fingerprint['entries'],
                'archiveDigest': fingerprint['sha256'], 'checkpoint': checkpoint}

    def relocate(self, source):
        source = safe_path(source)
        require(source != self.destination and source.name != '.tron-maintenance',
                'archive-source: invalid source')
        descriptor = self._descriptor()
        if descriptor is None:
            require(exists(source), 'archive-source: source is absent')
            source = private_dir(source)
            require(source.stat().st_dev == self.operation.stat().st_dev,
                    'archive-source: source and destination must share a filesystem')
            require(not exists(self.destination), 'archive-collision: destination already exists')
            checkpoint = _verify_checkpoint_evidence(source)
            fingerprint = archive_fingerprint(source)
            post = _verify_post_components(self.operation, self.receipt)
            descriptor = {
                'schema': RECOVERY_SCHEMA, 'kind': 'tron-recovery-bundle',
                'operationId': self.operation_id, 'phase': 'prepared',
                'destination': str(RECOVERY_RELATIVE_ROOT),
                'historicalSource': str(source), 'sourceDevice': source.stat().st_dev,
                'sourceInode': source.stat().st_ino,
                'entries': fingerprint['entries'], 'archiveDigest': fingerprint['sha256'],
                'sourceRootXattrs': fingerprint['rootXattrs'], 'checkpoint': checkpoint,
                'post': post, 'sourceRevision': self.receipt.get('sourceRevision'),
            }
            write_json(self.descriptor_path, descriptor)
        else:
            require(str(source) == descriptor['historicalSource'],
                    'archive-source: resume source differs from recorded source')
            if exists(source):
                source_info = source.lstat()
                require(source_info.st_dev == descriptor['sourceDevice'] and
                        source_info.st_ino == descriptor['sourceInode'],
                        'archive-source: resume source identity changed')
        if exists(source) and exists(self.destination):
            raise Stop('archive-collision: source and destination both exist; inspect without merging')
        if descriptor['phase'] == 'verified':
            require(not exists(source), 'archive-collision: verified destination has a source present')
            return self.verify()
        if exists(source):
            source = private_dir(source)
            fingerprint = archive_fingerprint(source)
            require(fingerprint['entries'] == descriptor['entries'] and
                    fingerprint['sha256'] == descriptor['archiveDigest'],
                    'archive-source: source changed after intent was recorded')
            rename_exclusive(source, self.destination)
        else:
            require(exists(self.destination), 'archive-resume: source and destination are both absent')
        result = self.verify()
        descriptor['phase'] = 'verified'
        descriptor['verified'] = result
        write_json(self.descriptor_path, descriptor)
        return result


class Reinstall:
    kind = 'reinstall'
    phases = ('awaiting-offline', 'backing-up', 'awaiting-replacement', 'awaiting-resume', 'verified')
    confirmation_options = {'confirm_offline': 'attest successful old-helper retirement and all writers stopped'}

    def __init__(self, home, platform):
        self.home, self.platform = safe_path(home), platform
        self.store = self.home / '.tron-maintenance'
        self.receipt = None

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

    def begin(self, app):
        self.layout()
        require(app != self.platform.installed, 'app-path: prepared app must be separate from installed app')
        candidate = self.platform.validate_app(app)
        original = self.platform.validate_app(self.platform.installed, current_contract=False)
        require(candidate['team'] == original['team'], 'signer-mismatch: replacement and installed app have different teams')
        identifier = str(uuid.uuid4())
        revision = command(['/usr/bin/git', '-C', REPO, 'rev-parse', 'HEAD'], 'source-revision', timeout=15).decode().strip()
        require(re.fullmatch(r'[0-9a-f]{40,64}', revision), 'source-revision: expected immutable commit identity')
        self.operation = private_dir(self.store / identifier, create=True)
        self.receipt = {'schema': 1, 'id': identifier, 'kind': self.kind, 'home': str(self.home),
                        'app': str(app), 'candidate': candidate, 'original': original,
                        'sourceRevision': revision,
                        'phase': 'awaiting-offline', 'components': {}, 'sourcePaths': {}}
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
        return safe_path(self.home / '.tron/gateway/payloads/stable')

    def selection_evidence(self):
        selection = self.receipt.get('bundledSelection')
        require(isinstance(selection, dict) and set(selection) == {'phase', 'manifestDigest'}
                and selection['phase'] in ('retiring', 'selected'),
                'selection-journal: preserve the operation for review')
        proof = read_json(self.operation / 'stable-selection.json')
        require(manifest_digest(proof) == selection['manifestDigest'],
                'selection-journal: retired payload inventory changed')
        return selection, proof

    def verify_bundled_selection(self, before_activation=True):
        if 'bundledSelection' not in self.receipt:
            return
        selection, proof = self.selection_evidence()
        require(selection['phase'] == 'selected',
                'selection-incomplete: rerun --select-bundled-offline before the snapshot')
        retired = self.operation / 'retired-stable-payloads'
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
        selection, proof = self.selection_evidence()
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

    def sources(self):
        sources = {'agent': self.source_agent(), 'old-app': self.platform.installed,
                   'browser-config': self.home / '.pi/config/pi-agent-browser-native/config.json',
                   # Stable and Debug share this exact machine identity. It is
                   # backed up as its own component so a cutover cannot create
                   # or retire a second authority by accident.
                   'machine-group': self.home / '.tron/internal/machine-group-id'}
        for path in sorted((self.home / '.tron').iterdir()):
            if path.name not in self.excluded_state_entries():
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

    def backup(self):
        sources = self.sources()
        backups = private_dir(self.operation / 'backups', create=True)
        scratch = private_dir(self.operation / 'scratch', create=True)
        components = self.receipt['components']
        if not components:
            # Freeze every source before copying anything; absence is recorded too.
            sizes = {}
            self.receipt['sourcePaths'] = {name: str(path) for name, path in sources.items()}
            for name, source in sources.items():
                print(f'Inventorying {name}…', flush=True)
                manifest = tree_manifest(source) if exists(source) else None
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
            require((tree_manifest(source) if exists(source) else None) == expected,
                    f'source-changed: {name} differs from the frozen backup inventory')
            if expected is None:
                continue
            print(f'Checking/copying {name} backup…', flush=True)
            copy_tree(source, backups / name, expected, scratch)
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
        # Reject data changes during an interrupted offline window.
        for name, source in self.sources().items():
            # The installed app is the sole intentional change in this window;
            # its replacement identity was checked by continue_offline.
            if name == 'old-app' and app_replaced:
                continue
            expected = read_json(self.operation / f'{name}.json')
            require(manifest_digest(expected) == self.receipt['components'][name], 'manifest-corrupt: evidence changed')
            require((tree_manifest(source) if exists(source) else None) == expected,
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
        actions = [args.status, args.verify, args.finish, getattr(args, 'select_bundled_offline', False)]
        actions.extend(getattr(args, name, False) for name in self.confirmation_options)
        require(sum(bool(value) for value in actions) <= 1,
                'arguments: choose exactly one action or offline confirmation')
        with exclusive(self.store):
            if exists(self.store / 'active.json'):
                self.load()
                if args.app:
                    require(str(safe_path(args.app)) == self.receipt['app'], 'different-artifact: finish active operation first')
            else:
                require(args.app is not None and not args.status and not args.verify,
                        'artifact-required: begin with --app /absolute/path/Tron.app')
                self.begin(safe_path(args.app))
            print(f'Operation: {self.operation}\nPhase: {self.receipt["phase"]}', flush=True)
            if args.status:
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
        print('NEXT: In the old app, successfully Disable Helper for Update, Pause Tron, then quit.\n'
              'Stop Debug, standalone clients, workers and package operations. Re-run with --confirm-offline.\n'
              'This flag attests to successful retirement and writer quiescence; process absence alone is insufficient.')
        return False

    def continue_offline(self, args):
        installed = self.platform.validate_app(self.platform.installed, False)
        app_replaced = installed == self.receipt['candidate']
        require(app_replaced or installed == self.receipt['original'],
                'unexpected-installed-app: preserve operation for review')
        # Replacing the app never waives the backup/data gate. Run it before
        # publishing either next action, including repeated awaiting-resume calls.
        self.before_activation(app_replaced=app_replaced)
        if app_replaced:
            self.save('awaiting-resume')
            print('NEXT: Launch /Applications/Tron.app, choose Resume Tron, approve macOS prompts, then run with --verify.')
            return
        print(f'NEXT: In Finder replace /Applications/Tron.app with {self.receipt["app"]}.\n'
              'Launch the replacement, choose Resume Tron and approve required prompts. Then re-run with --verify.\n'
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
    result.add_argument('--recovery-verify', action='store_true',
                        help='read-only verify a registered completed recovery archive')
    result.add_argument('--recovery-relocate', action='store_true',
                        help='register and exclusively relocate a completed recovery archive')
    result.add_argument('--operation-id', help='completed maintenance operation id for archive commands')
    result.add_argument('--source', type=Path, help='existing recovery archive root for --recovery-relocate')
    return result


def main(workflow=Reinstall, arguments=None):
    args = parser(workflow.__doc__ or __doc__, workflow.confirmation_options).parse_args(arguments)
    try:
        require(sys.platform == 'darwin' and os.getuid() != 0, 'platform: run as the logged-in macOS user, without sudo')
        home = safe_path(pwd.getpwuid(os.getuid()).pw_dir)
        require(safe_path(Path.home()) == home, 'home-override: run from the logged-in user environment; no state changed')
        recovery_action = args.recovery_verify or args.recovery_relocate
        require(not (args.recovery_verify and args.recovery_relocate),
                'arguments: choose one recovery archive action')
        if recovery_action:
            require(not any((args.app, args.confirm_offline, args.select_bundled_offline,
                             args.status, args.verify, args.finish)),
                    'arguments: recovery action cannot be combined with reinstall options')
            require(args.operation_id is not None, 'arguments: recovery archive requires --operation-id')
            store = private_dir(home / '.tron-maintenance')
            with exclusive(store):
                archive = RecoveryArchive(home, args.operation_id)
                if args.recovery_verify:
                    require(args.source is None, 'arguments: --source is only valid with --recovery-relocate')
                    print(json.dumps(archive.verify(), indent=2, sort_keys=True))
                else:
                    require(args.source is not None, 'arguments: --recovery-relocate requires --source')
                    print(json.dumps(archive.relocate(args.source), indent=2, sort_keys=True))
            return 0
        require(args.operation_id is None and args.source is None,
                'arguments: archive options require a recovery action')
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
        print('Interrupted; operation preserved. Re-run the same command after confirming writers remain offline.', file=sys.stderr)
        return 130


if __name__ == '__main__':
    sys.exit(main())
