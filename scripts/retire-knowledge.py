#!/usr/bin/env python3
"""Offline one-shot source export and observation retirement; never used by Gateway.

The maintainer stops the canonical Gateway first. --offline attests that exclusive
window; this command cannot stop, install, or restart it. An independently hashed
archive precedes source-file and current-format Profile publication. Only then is
the retired namespace removed; no Gateway runtime reads an old Knowledge format.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import sys
import tempfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def put(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.exists():
        if path.read_bytes() != data:
            raise ValueError(f'Existing output differs: {path.name}')
        return
    fd, name = tempfile.mkstemp(prefix='.retirement-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
        sync_dir(path.parent)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def safe_tree(root):
    if root.is_symlink() or not root.is_dir() or root.stat().st_mode & 0o077:
        raise ValueError('Expected a real, owner-only directory')
    for path in [root, *root.rglob('*')]:
        info = path.lstat()
        if path.is_symlink() or info.st_uid != os.getuid() or not (path.is_dir() or path.is_file()):
            raise ValueError('Unsafe file type, symlink or foreign owner')
        if path.is_file() and info.st_nlink != 1:
            raise ValueError('Hard-linked input is not an independent archive')


def hashes(root, omit=()):
    return {str(p.relative_to(root)): digest(p.read_bytes()) for p in sorted(root.rglob('*'))
            if p.is_file() and str(p.relative_to(root)) not in omit}


def database(store, readonly=True):
    manifest = json.loads((store / 'state.json').read_bytes())
    if manifest.get('storageVersion') != 4 or manifest.get('schemaVersion') != 1:
        raise ValueError('Only the active storage-4/schema-1 snapshot is accepted')
    identity = manifest.get('catalogID', '')
    if not identity or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-' for c in identity):
        raise ValueError('Unsafe catalog identity')
    path = store / f'catalog-{identity}.sqlite'
    conn = sqlite3.connect(path.as_uri() + ('?mode=ro' if readonly else '?mode=rw'), uri=True)
    conn.execute('PRAGMA trusted_schema=OFF')
    if readonly:
        conn.execute('PRAGMA query_only=ON')
    else:
        conn.execute('PRAGMA synchronous=EXTRA')
        conn.execute('PRAGMA secure_delete=ON')
    if conn.execute('PRAGMA user_version').fetchone()[0] != 1:
        conn.close()
        raise ValueError('Unsupported catalog layout')
    return conn, path


def rows(conn):
    return [(collection, key, value) for collection, key, value in conn.execute('SELECT collection,key,value FROM entries ORDER BY collection,key')]


def heads(conn):
    return {json.loads(key): json.loads(value) for collection, key, value in rows(conn) if collection == 'records'}


def identifier(value):
    if not isinstance(value, str) or not value or len(value) > 200 or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in value):
        raise ValueError('Unsafe record or revision ID')
    return value


def count_snapshot(conn):
    records = list(heads(conn).values())
    return {'sources': sum(h['kind'] == 'source' for h in records),
            'observations': sum(h['kind'] == 'observation' for h in records),
            'notes': sum(h['kind'] == 'note' for h in records),
            'coverage': conn.execute("SELECT count(*) FROM entries WHERE collection='coverage'").fetchone()[0]}


def snapshot(source, backup, expected):
    if backup.exists():
        safe_tree(backup)
        proof = json.loads((backup / 'BACKUP.json').read_bytes())
        if hashes(backup, ('BACKUP.json',)) != proof['files']:
            raise ValueError('Backup hash verification failed')
        if proof['counts'] != expected:
            raise ValueError('Backup count mismatch')
        return
    safe_tree(source)
    _, marker = locations(source)
    initialization = secure_file(marker)
    parsed = json.loads(initialization)
    if not isinstance(parsed, dict) or parsed.get('version') != 1 or set(parsed) - {'version', 'knowledgeInitialized'} or ('knowledgeInitialized' in parsed and not isinstance(parsed['knowledgeInitialized'], bool)):
        raise ValueError('Unsupported workspace initialization record')
    if any((source / name).exists() for name in ('BACKUP.json', 'WORKSPACE.json', 'STAGING.json')):
        raise ValueError('Reserved archive metadata exists in the input namespace')
    original_files = hashes(source)
    conn, catalog = database(source)
    stage = backup.with_name(backup.name + '.partial')
    try:
        conn.execute('BEGIN')
        if count_snapshot(conn) != expected:
            raise ValueError(f'Count drift: actual {count_snapshot(conn)}, expected {expected}')
        before = rows(conn)
        control = conn.execute('SELECT value FROM control').fetchall()
        owner = encoded({'version': 1, 'source': str(source), 'counts': expected})
        if stage.exists():
            safe_tree(stage)
            if list(stage.iterdir()) and secure_file(stage / 'STAGING.json') != owner:
                raise ValueError('Unowned archive staging directory')
            shutil.rmtree(stage)
        stage.mkdir(mode=0o700, parents=False)
        put(stage / 'STAGING.json', owner)
        put(stage / 'WORKSPACE.json', initialization)
        for path in source.iterdir():
            if path.name.startswith(catalog.name):
                continue
            if path.is_dir():
                shutil.copytree(path, stage / path.name)
            else:
                shutil.copy2(path, stage / path.name)
        target = sqlite3.connect(stage / catalog.name)
        try:
            conn.backup(target)
            if target.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                raise ValueError('Backup SQLite integrity check failed')
        finally:
            target.close()
        conn.rollback()
        # The exclusive offline window is mandatory: reject a writer rather than
        # presenting an inconsistent immutable-file/catalog combination as backup.
        if rows(conn) != before or conn.execute('SELECT value FROM control').fetchall() != control:
            raise ValueError('Canonical owner changed during backup; stop it first')
        for path in stage.rglob('*'):
            if path.is_file():
                with path.open('rb') as handle:
                    os.fsync(handle.fileno())
        if hashes(source) != original_files or secure_file(marker) != initialization:
            raise ValueError('Current immutable/catalog bytes changed during backup')
        copied = hashes(stage, ('STAGING.json', 'WORKSPACE.json', catalog.name))
        if copied != {name: value for name, value in original_files.items() if name != catalog.name}:
            raise ValueError('Backup immutable payloads differ from the exact input snapshot')
        proof = {'counts': expected, 'files': hashes(stage), 'originalFiles': original_files}
        put(stage / 'BACKUP.json', encoded(proof))
        for path in sorted((p for p in stage.rglob('*') if p.is_dir()), reverse=True):
            sync_dir(path)
        sync_dir(stage)
        os.rename(stage, backup)
        sync_dir(backup.parent)
    finally:
        conn.close()


def record_payloads(archive, conn):
    for identity, head in heads(conn).items():
        identifier(identity)
        if head['kind'] not in ('source', 'observation', 'note'):
            raise ValueError('Unexpected record kind')
        for revision in head['revisionIds']:
            identifier(revision)
            raw = (archive / 'records' / identity / (revision + '.json')).read_bytes()
            record = json.loads(raw)
            if record['id'] != identity or record['revisionId'] != revision or record['kind'] != head['kind']:
                raise ValueError('Mixed-kind history or payload identity mismatch')
            owner = conn.execute('SELECT record FROM revision_owners WHERE revision=?', (revision,)).fetchone()
            if owner != (identity,):
                raise ValueError('Revision ownership mismatch')
            yield identity, head, revision, raw, record


def export_sources(archive, files, expected, verify_only=False):
    conn, _ = database(archive)
    try:
        retired = {identity for identity, head in heads(conn).items() if head['kind'] != 'note'}
        for collection, key, value in rows(conn):
            if collection == 'suppressions' and json.loads(key) in retired:
                raise ValueError('Suppressed source/observation needs an explicit privacy disposition')
            if collection == 'scopeExclusions' and json.loads(value).get('excluded'):
                raise ValueError('Scope exclusions need explicit privacy disposition before plain-file export')
        if not verify_only:
            files.mkdir(mode=0o700, parents=False, exist_ok=True)
        safe_tree(files)
        def publish(path, raw):
            if verify_only:
                if path.read_bytes() != raw:
                    raise ValueError('Sealed export differs from its archival source')
            else:
                put(path, raw)
        exported = []
        objects = set()
        revisions = 0
        for identity, head, revision, raw, record in record_payloads(archive, conn):
            if head['kind'] != 'source':
                continue
            revisions += 1
            base = Path('sources') / identity / revision
            publish(files / base / 'original.json', raw)
            # Plain Markdown is readable directly; exact payload bytes remain a
            # normal JSON attachment, not an executable format or a runtime API.
            content = record['content']
            text = f'# {content.get("title", identity)}\n\n'
            text += f'Original ID: `{identity}`\n\nRevision: `{revision}`\n\n'
            text += f'Source: {content.get("uri", "")}\n\n'
            body = content.get('body', content.get('text', ''))
            if isinstance(body, str) and body:
                text += body + '\n\n'
            text += '## Original metadata and provenance\n\n```json\n' + json.dumps(record, ensure_ascii=False, sort_keys=True, indent=2) + '\n```\n'
            publish(files / base / 'source.md', text.encode())
            exported.append({'id': identity, 'revision': revision, 'latest': revision == head['latestRevisionId'],
                             'payload': str(base / 'original.json'), 'payloadSHA256': digest(raw),
                             'markdown': str(base / 'source.md'), 'markdownSHA256': digest(text.encode())})
            # Head objectHashes is the store's union across committed history.
            objects.update(head.get('objectHashes', []))
        for hash_value in sorted(objects):
            if len(hash_value) != 64 or any(c not in '0123456789abcdef' for c in hash_value):
                raise ValueError('Invalid object hash')
            raw = (archive / 'objects' / hash_value).read_bytes()
            if digest(raw) != hash_value:
                raise ValueError('Original object digest mismatch')
            publish(files / 'attachments' / hash_value, raw)
        manifest = {'counts': {**expected, 'sourceRevisions': revisions}, 'sources': exported, 'files': hashes(files, ('MANIFEST.json',))}
        publish(files / 'MANIFEST.json', encoded(manifest))
        verify_export(files)
        return retired
    finally:
        conn.close()


def verify_export(files):
    safe_tree(files)
    manifest = json.loads((files / 'MANIFEST.json').read_bytes())
    if hashes(files, ('MANIFEST.json',)) != manifest['files']:
        raise ValueError('Export byte/hash verification failed')
    if len(manifest['sources']) != manifest['counts']['sourceRevisions']:
        raise ValueError('Source revision count mismatch')
    if len({item['id'] for item in manifest['sources']}) != manifest['counts']['sources']:
        raise ValueError('Source head count mismatch')
    for item in manifest['sources']:
        original = (files / item['payload']).read_bytes()
        if digest(original) != item['payloadSHA256']:
            raise ValueError('Canonical original payload mismatch')
        # An independent textual inclusion check prevents a faithful original.json
        # from concealing a dropped body in the human-readable Markdown wrapper.
        record = json.loads(original)
        content = record['content']
        body = content.get('body', content.get('text', ''))
        text = (files / item['markdown']).read_text()
        if isinstance(body, str) and body and body not in text:
            raise ValueError('Markdown body fidelity failed')
    return manifest


def locations(store):
    if store.name != 'knowledge' or store.parent.name != 'state' or store.parent.parent.name != 'workspace':
        raise ValueError('Store must be the canonical workspace/state/knowledge namespace')
    home = store.parents[2]
    return store.with_name('profile'), home / 'gateway' / 'workspace-state' / 'initialized.json'


def secure_file(path):
    info = path.lstat()
    if path.is_symlink() or not path.is_file() or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
        raise ValueError('Expected an owner-only, unlinked regular file')
    return path.read_bytes()


def verify_archive(archive, expected):
    safe_tree(archive)
    proof = json.loads((archive / 'BACKUP.json').read_bytes())
    if proof['counts'] != expected or hashes(archive, ('BACKUP.json',)) != proof['files']:
        raise ValueError('Backup count/hash verification failed')
    return proof


def profile_projection(archive, profile):
    old, _ = database(archive)
    try:
        all_heads = heads(old)
        notes = {identity: head for identity, head in all_heads.items() if head['kind'] == 'note'}
        retired = set(all_heads) - set(notes)
        bodies = {(identity, revision): (raw, record) for identity, head, revision, raw, record in record_payloads(archive, old) if head['kind'] == 'note'}
        projected = []
        for collection, key, raw in rows(old):
            value = json.loads(raw)
            if collection == 'records':
                identity = json.loads(key)
                if identity not in notes:
                    continue
                record = bodies[(identity, value['latestRevisionId'])][1]
                value.pop('searchFields', None)
                content = record['content']
                value['profileRow'] = None
                if record['scope'] == 'personal' and 'home-profile' in content.get('tags', []):
                    value['profileRow'] = {'title': content['title'], 'confirmed': content['confirmed'], 'tags': content['tags'], 'retired': content.get('retired') is True,
                                           'supersedes': [relation['recordId'] for relation in record['relations'] if relation['type'] == 'supersedes']}
                    if 'profile' in content:
                        value['profileRow']['profile'] = content['profile']
            elif collection == 'receipts':
                allowed = {'knowledge.note.create', 'knowledge.note.update', 'knowledge.profile.partition', 'knowledge.profile.defer', 'knowledge.correction', 'knowledge.forget', 'knowledge.exclusion', 'knowledge.scope-exclusion'}
                if value['operation'] not in allowed:
                    continue
                if any(identity in retired for identity in value.get('recordIds', [])):
                    if any(identity not in retired for identity in value.get('recordIds', [])):
                        raise ValueError('Mixed note/retired receipt requires explicit disposition')
                    continue
                result = value.get('result', {})
                payload = result.get('value') if result.get('kind') == 'value' else None
                if isinstance(payload, dict) and 'backup' in payload:
                    name = Path(payload['backup']).name
                    if len(name) != 69 or not name.endswith('.json') or any(c not in '0123456789abcdef' for c in name[:-5]) or not (archive / 'profile-backups' / name).is_file():
                        raise ValueError('Profile receipt backup is unavailable or unsafe')
                    payload['backup'] = str(profile / 'profile-backups' / name)
            elif collection == 'suppressions':
                if json.loads(key) in retired:
                    continue
            elif collection == 'recordCleanup':
                if value['recordId'] in retired:
                    continue
            elif collection not in ('scopeExclusions', 'cleanup'):
                continue
            projected.append((collection, key, json.dumps(value, ensure_ascii=False, separators=(',', ':'))))
        control = json.loads(old.execute('SELECT value FROM control WHERE id=1').fetchone()[0])
        config = control['config']
        control = {key: control[key] for key in ('schemaVersion', 'stateRevision', 'catalogID', 'profileSorting') if key in control}
        control['config'] = {key: config[key] for key in ('schemaVersion', 'revision', 'eligibility', 'maximumSearchResults')}
        owners = [(revision, identity) for revision, identity in old.execute('SELECT revision,record FROM revision_owners ORDER BY revision') if identity in notes]
        files = {'initialized.json': encoded({'version': 1}), 'state.json': encoded({'schemaVersion': 1, 'storageVersion': 1, 'catalogID': control['catalogID']}),
                 'retirement.json': encoded({'version': 1, 'archiveProofSHA256': digest((archive / 'BACKUP.json').read_bytes())})}
        for (identity, revision), (raw, _) in bodies.items():
            files[f'records/{identity}/{revision}.json'] = raw
        for hash_value in {value for head in notes.values() for value in head.get('objectHashes', [])}:
            if len(hash_value) != 64 or any(c not in '0123456789abcdef' for c in hash_value):
                raise ValueError('Invalid retained Profile object identity')
            raw = (archive / 'objects' / hash_value).read_bytes()
            if digest(raw) != hash_value:
                raise ValueError('Retained Profile object digest mismatch')
            files['objects/' + hash_value] = raw
        backups = archive / 'profile-backups'
        if backups.exists():
            for path in backups.rglob('*'):
                if path.is_file():
                    files[str(path.relative_to(archive))] = path.read_bytes()
        return projected, control, owners, files, len(bodies)
    finally:
        old.close()


def create_profile_database(path, projected, control, owners):
    conn = sqlite3.connect(path)
    os.chmod(path, 0o600)
    try:
        conn.executescript('''PRAGMA journal_mode=DELETE; PRAGMA synchronous=EXTRA; PRAGMA secure_delete=ON; PRAGMA user_version=1;
          CREATE TABLE control (id INTEGER PRIMARY KEY CHECK(id = 1), value TEXT NOT NULL CHECK(json_valid(value)));
          CREATE TABLE entries (collection TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL CHECK(json_valid(value)), PRIMARY KEY(collection,key)) WITHOUT ROWID;
          CREATE INDEX records_date ON entries(collection,json_extract(value,'$.sortAt') DESC,key) WHERE collection='records';
          CREATE INDEX records_kind_date ON entries(collection,json_extract(value,'$.kind'),json_extract(value,'$.sortAt') DESC,key) WHERE collection='records';
          CREATE INDEX records_scope_date ON entries(collection,json_extract(value,'$.scope'),json_extract(value,'$.sortAt') DESC,key) WHERE collection='records';
          CREATE INDEX records_kind_scope_date ON entries(collection,json_extract(value,'$.kind'),json_extract(value,'$.scope'),json_extract(value,'$.sortAt') DESC,key) WHERE collection='records';
          CREATE TABLE revision_owners (revision TEXT PRIMARY KEY, record TEXT NOT NULL); CREATE INDEX revision_record ON revision_owners(record);''')
        conn.executemany('INSERT INTO entries(collection,key,value) VALUES(?,?,?)', projected)
        conn.executemany('INSERT INTO revision_owners(revision,record) VALUES(?,?)', owners)
        conn.execute('INSERT INTO control(id,value) VALUES(1,?)', (json.dumps(control, ensure_ascii=False, separators=(',', ':')),))
        conn.commit()
        if conn.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise ValueError('Profile integrity check failed')
    finally:
        conn.close()


def verify_profile(profile, archive, destination=None):
    safe_tree(profile)
    projected, control, owners, expected_files, revisions = profile_projection(archive, destination or profile)
    catalog_name = 'catalog-' + control['catalogID'] + '.sqlite'
    if hashes(profile, (catalog_name,)) != {name: digest(raw) for name, raw in expected_files.items()}:
        raise ValueError('Profile bytes differ from their exact archival projection')
    conn = sqlite3.connect((profile / catalog_name).as_uri() + '?mode=ro', uri=True)
    try:
        if conn.execute('PRAGMA user_version').fetchone()[0] != 1 or conn.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise ValueError('Profile database layout/integrity mismatch')
        actual = [(c, k, json.loads(v)) for c, k, v in rows(conn)]
        if actual != [(c, k, json.loads(v)) for c, k, v in sorted(projected)]:
            raise ValueError('Profile catalog differs from its exact projection')
        if json.loads(conn.execute('SELECT value FROM control WHERE id=1').fetchone()[0]) != control or conn.execute('SELECT revision,record FROM revision_owners ORDER BY revision').fetchall() != owners:
            raise ValueError('Profile controls or immutable revision ownership changed')
        return revisions
    finally:
        conn.close()


def publish_profile(store, archive, profile):
    if profile.exists():
        return verify_profile(profile, archive)
    if not store.exists():
        raise ValueError('Profile publication is missing; an archive is never an automatic restore')
    stage = profile.with_name(profile.name + '.retirement-partial')
    owner = encoded({'version': 1, 'archiveProofSHA256': digest((archive / 'BACKUP.json').read_bytes())})
    if stage.exists():
        safe_tree(stage)
        if list(stage.iterdir()) and secure_file(stage / 'retirement.json') != owner:
            raise ValueError('Unowned Profile staging directory')
        shutil.rmtree(stage)
    stage.mkdir(mode=0o700)
    put(stage / 'retirement.json', owner)
    projected, control, owners, expected_files, revisions = profile_projection(archive, profile)
    for directory in ('records', 'objects'):
        (stage / directory).mkdir(mode=0o700)
    for name, raw in expected_files.items():
        put(stage / name, raw)
    create_profile_database(stage / ('catalog-' + control['catalogID'] + '.sqlite'), projected, control, owners)
    verify_profile(stage, archive, profile)
    # Verify with the final receipt destinations before publishing its namespace.
    for path in stage.rglob('*'):
        if path.is_file():
            with path.open('rb') as handle:
                os.fsync(handle.fileno())
    for directory in sorted((path for path in stage.rglob('*') if path.is_dir()), reverse=True):
        sync_dir(directory)
    sync_dir(stage)
    os.rename(stage, profile)
    sync_dir(profile.parent)
    return verify_profile(profile, archive)


def publish_initialization(marker, archive):
    before = (archive / 'WORKSPACE.json').read_bytes()
    after = encoded({'version': 1})
    current = secure_file(marker)
    if current not in (before, after):
        raise ValueError('Workspace initialization changed since backup')
    if current != after:
        fd, name = tempfile.mkstemp(prefix='.retirement-', dir=marker.parent)
        try:
            with os.fdopen(fd, 'wb') as handle:
                handle.write(after); handle.flush(); os.fsync(handle.fileno())
            os.replace(name, marker)
            sync_dir(marker.parent)
        finally:
            if os.path.exists(name):
                os.unlink(name)
    put(marker.with_name('profile-initialized.json'), after)


def retire_namespace(store, archive, profile, marker):
    proof = json.loads((archive / 'BACKUP.json').read_bytes())
    retiring = store.with_name('knowledge.retiring')
    if store.exists():
        safe_tree(store)
        if retiring.exists() or hashes(store) != proof['originalFiles']:
            raise ValueError('Current immutable/catalog bytes changed after backup; refusing retirement')
        verify_profile(profile, archive)
        publish_initialization(marker, archive)
        os.rename(store, retiring)
        sync_dir(store.parent)
    elif secure_file(marker) != encoded({'version': 1}):
        raise ValueError('Workspace cutover is incomplete')
    if retiring.exists():
        safe_tree(retiring)
        if any(proof['originalFiles'].get(name) != value for name, value in hashes(retiring).items()):
            raise ValueError('Retiring namespace contains changed or unknown bytes')
        for path in sorted(retiring.rglob('*'), key=lambda item: len(item.parts), reverse=True):
            if path.is_dir():
                path.rmdir()
            else:
                path.unlink()
        retiring.rmdir()
        sync_dir(store.parent)
    if secure_file(marker.with_name('profile-initialized.json')) != encoded({'version': 1}):
        raise ValueError('Profile initialization evidence is missing')


def acquire_lock(backup, readonly):
    lock = backup.with_name(backup.name + '.lock')
    flags = os.O_NOFOLLOW | (os.O_RDONLY if readonly else os.O_RDWR | os.O_CREAT)
    fd = os.open(lock, flags, 0o600)
    info = os.fstat(fd)
    if info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
        os.close(fd)
        raise ValueError('Unsafe offline converter lock')
    try:
        fcntl.flock(fd, (fcntl.LOCK_SH if readonly else fcntl.LOCK_EX) | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        raise ValueError('Another converter owns this archive; no work performed')
    return fd


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('store', 'files', 'backup'):
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ('sources', 'observations', 'notes', 'coverage'):
        parser.add_argument('--expected-' + name, type=int, required=True)
    parser.add_argument('--offline', action='store_true', required=True, help='Attest the maintainer has stopped the canonical owner; never run against an active Gateway')
    parser.add_argument('--verify', action='store_true', help='Read-only verification before the new runtime opens Profile')
    args = parser.parse_args()
    profile, marker = locations(args.store)
    paths = [args.store, profile, args.files, args.backup, marker, marker.with_name('profile-initialized.json')]
    for path in paths:
        if not path.is_absolute() or path.is_symlink() or path.resolve() != path:
            raise ValueError('Use absolute canonical non-symlink paths')
    if any(a == b or a in b.parents or b in a.parents for i, a in enumerate(paths) for b in paths[i + 1:]):
        raise ValueError('Input, Profile, archive and output must be disjoint')
    expected = {name: getattr(args, 'expected_' + name) for name in ('sources', 'observations', 'notes', 'coverage')}
    lock = acquire_lock(args.backup, args.verify)
    try:
        if not args.verify:
            snapshot(args.store, args.backup, expected)
        verify_archive(args.backup, expected)
        if args.store.exists() and hashes(args.store) != json.loads((args.backup / 'BACKUP.json').read_bytes())['originalFiles']:
            raise ValueError('Current immutable/catalog bytes changed after backup; refusing retirement')
        sealed = args.verify or (args.files / 'MANIFEST.json').exists()
        export_sources(args.backup, args.files, expected, verify_only=sealed)
        if not args.verify:
            publish_profile(args.store, args.backup, profile)
            # Point of no return: only a complete, verified Profile and source
            # export may precede the namespace rename and bounded cleanup.
            retire_namespace(args.store, args.backup, profile, marker)
        if args.store.exists() or args.store.with_name('knowledge.retiring').exists():
            raise ValueError('Retired namespace or interrupted cleanup remains')
        if secure_file(marker) != encoded({'version': 1}) or secure_file(marker.with_name('profile-initialized.json')) != encoded({'version': 1}):
            raise ValueError('Initialization cutover is incomplete')
        revisions = verify_profile(profile, args.backup)
        manifest = verify_export(args.files)
        print(json.dumps({'verified': True, 'counts': manifest['counts'], 'noteRevisionsUnchanged': revisions, 'knowledgeNamespaceAbsent': True,
                          'backupFiles': len(json.loads((args.backup / 'BACKUP.json').read_bytes())['files'])}, sort_keys=True))
    finally:
        os.close(lock)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, sqlite3.Error) as error:
        print(f'Refused: {error}', file=sys.stderr)
        sys.exit(1)
