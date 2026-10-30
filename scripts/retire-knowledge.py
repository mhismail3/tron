#!/usr/bin/env python3
"""Offline one-shot source export and observation retirement; never used by Gateway.

The maintainer stops the canonical Gateway first. --offline attests that exclusive
window; this command cannot stop, install, or restart it. Profile notes remain in
exactly their active store. An independently hashed archive precedes publication.
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
    conn, catalog = database(source)
    stage = backup.with_name(backup.name + '.partial')
    try:
        conn.execute('BEGIN')
        if count_snapshot(conn) != expected:
            raise ValueError(f'Count drift: actual {count_snapshot(conn)}, expected {expected}')
        before = rows(conn)
        control = conn.execute('SELECT value FROM control').fetchall()
        if stage.exists():
            safe_tree(stage)
            # Only this command's uncommitted staging directory is disposable.
            # A published backup is never replaced or repaired.
            shutil.rmtree(stage)
        stage.mkdir(mode=0o700, parents=False)
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
        proof = {'counts': expected, 'files': hashes(stage)}
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


def export_sources(archive, files, expected):
    conn, _ = database(archive)
    try:
        retired = {identity for identity, head in heads(conn).items() if head['kind'] != 'note'}
        for collection, key, value in rows(conn):
            if collection == 'suppressions' and json.loads(key) in retired:
                raise ValueError('Suppressed source/observation needs an explicit privacy disposition')
            if collection == 'scopeExclusions' and json.loads(value).get('excluded'):
                raise ValueError('Scope exclusions need explicit privacy disposition before plain-file export')
        files.mkdir(mode=0o700, parents=False, exist_ok=True)
        safe_tree(files)
        exported = []
        objects = set()
        revisions = 0
        for identity, head, revision, raw, record in record_payloads(archive, conn):
            if head['kind'] != 'source':
                continue
            revisions += 1
            base = Path('sources') / identity / revision
            put(files / base / 'original.json', raw)
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
            put(files / base / 'source.md', text.encode())
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
            put(files / 'attachments' / hash_value, raw)
        manifest = {'counts': {**expected, 'sourceRevisions': revisions}, 'sources': exported, 'files': hashes(files, ('MANIFEST.json',))}
        put(files / 'MANIFEST.json', encoded(manifest))
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


def projected_rows(archive_rows, retired):
    output = []
    for collection, key, value in archive_rows:
        if collection in ('coverage', 'sourceIdentities'):
            continue
        decoded = json.loads(value)
        if collection == 'records' and json.loads(key) in retired:
            continue
        if collection == 'receipts' and any(identity in retired for identity in decoded.get('recordIds', [])):
            if any(identity not in retired for identity in decoded.get('recordIds', [])):
                raise ValueError('Mixed note/retired receipt requires explicit preservation disposition')
            continue
        if collection == 'recordCleanup' and decoded.get('recordId') in retired:
            continue
        output.append((collection, key, value))
    return output


def archive_file_maps(archive, catalog_name, retired, original):
    proof = json.loads((archive / 'BACKUP.json').read_bytes())
    if hashes(archive, ('BACKUP.json',)) != proof['files']:
        raise ValueError('Archive no longer matches its backup proof')
    before = {name: value for name, value in proof['files'].items() if name != catalog_name}
    retained_objects = set()
    retired_objects = set()
    for identity, head in heads(original).items():
        (retired_objects if identity in retired else retained_objects).update(head.get('objectHashes', []))
    removable_objects = retired_objects - retained_objects
    after = {name: value for name, value in before.items()
             if not (name.startswith('records/') and name.split('/')[1] in retired)
             and not (name.startswith('objects/') and name.split('/')[1] in removable_objects)}
    return before, after, removable_objects


def verify_current_files(store, catalog_name, before, after, committed):
    safe_tree(store)
    actual = hashes(store, (catalog_name, catalog_name + '-journal', catalog_name + '-wal', catalog_name + '-shm'))
    if not committed and actual != before:
        raise ValueError('Current immutable payloads differ from the archive; refusing retirement')
    if committed:
        # A crash may have removed only part of the retiring immutable set. All
        # retained bytes and every still-present retiring byte must match backup.
        if any(actual.get(name) != value for name, value in after.items()) or any(before.get(name) != value for name, value in actual.items()):
            raise ValueError('Current immutable bytes changed after the catalog cut')


def retire(store, archive, retired):
    old, _ = database(archive)
    current, _ = database(store, readonly=False)
    try:
        before = rows(old)
        after = projected_rows(before, retired)
        old_owners = old.execute('SELECT revision,record FROM revision_owners ORDER BY revision').fetchall()
        next_owners = [row for row in old_owners if row[1] not in retired]
        catalog_name = database_name(archive)
        before_files, after_files, removable_objects = archive_file_maps(archive, catalog_name, retired, old)
        current.execute('BEGIN IMMEDIATE')
        actual = rows(current)
        actual_owners = current.execute('SELECT revision,record FROM revision_owners ORDER BY revision').fetchall()
        if current.execute('SELECT value FROM control').fetchall() != old.execute('SELECT value FROM control').fetchall():
            raise ValueError('Profile/control changed after backup; exclusive offline window lost')
        if actual == before and actual_owners == old_owners:
            verify_current_files(store, catalog_name, before_files, after_files, False)
            current.execute('DELETE FROM entries')
            current.executemany('INSERT INTO entries(collection,key,value) VALUES(?,?,?)', after)
            current.execute('DELETE FROM revision_owners')
            current.executemany('INSERT INTO revision_owners(revision,record) VALUES(?,?)', next_owners)
            current.commit()
        elif actual == after and actual_owners == next_owners:
            verify_current_files(store, catalog_name, before_files, after_files, True)
            current.rollback()  # committed cut: only immutable-file cleanup remains
        else:
            raise ValueError('Catalog differs from both the archive and its exact retirement projection')
        if current.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise ValueError('Converted SQLite integrity check failed')
        for identity in retired:
            path = store / 'records' / identifier(identity)
            if path.exists():
                shutil.rmtree(path)
        for path in (store / 'objects').iterdir():
            if path.name in removable_objects:
                path.unlink()
        sync_dir(store / 'records')
        sync_dir(store / 'objects')
    finally:
        current.close()
        old.close()


def verify_retained(store, archive):
    original, _ = database(archive)
    current, _ = database(store)
    try:
        retired = {identity for identity, head in heads(original).items() if head['kind'] != 'note'}
        _, remaining_files, _ = archive_file_maps(archive, database_name(archive), retired, original)
        if hashes(store, (database_name(store),)) != remaining_files:
            raise ValueError('Post-retirement files differ: retained bytes changed or retired bytes remain')
        if rows(current) != projected_rows(rows(original), retired):
            raise ValueError('Retained catalog is not the exact note-preserving projection')
        if current.execute('SELECT value FROM control').fetchall() != original.execute('SELECT value FROM control').fetchall():
            raise ValueError('Profile control changed')
        note_count = 0
        for identity, head, revision, raw, record in record_payloads(archive, original):
            if head['kind'] == 'note':
                if (store / 'records' / identity / (revision + '.json')).read_bytes() != raw:
                    raise ValueError('Retained note revision changed')
                note_count += 1
                for value in head.get('objectHashes', []):
                    if (store / 'objects' / value).read_bytes() != (archive / 'objects' / value).read_bytes():
                        raise ValueError('Retained note attachment changed')
        if any((store / 'records' / identity).exists() for identity in retired):
            raise ValueError('Retired record directory remains')
        if current.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise ValueError('Post-retirement integrity check failed')
        return note_count
    finally:
        original.close()
        current.close()


def database_name(store):
    return 'catalog-' + json.loads((store / 'state.json').read_bytes())['catalogID'] + '.sqlite'


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
    parser.add_argument('--verify', action='store_true', help='Read-only verification of an already completed conversion')
    args = parser.parse_args()
    paths = [args.store, args.files, args.backup]
    for path in paths:
        if not path.is_absolute() or path.is_symlink() or path.resolve() != path:
            raise ValueError('Use absolute canonical non-symlink paths')
    if any(a == b or a in b.parents or b in a.parents for i, a in enumerate(paths) for b in paths[i+1:]):
        raise ValueError('Store, archive and output must be disjoint')
    expected = {name: getattr(args, 'expected_' + name) for name in ('sources', 'observations', 'notes', 'coverage')}
    # One process owns archive staging, export and retirement through exit. A
    # crash releases flock; only its private unpublished stage may be rebuilt.
    lock = acquire_lock(args.backup, args.verify)
    if not args.verify:
        snapshot(args.store, args.backup, expected)
        retired = export_sources(args.backup, args.files, expected)
        # Point of no return: the first catalog commit below. Backup and complete
        # exported-byte verification have already succeeded; no runtime invokes it.
        retire(args.store, args.backup, retired)
    manifest = verify_export(args.files)
    revisions = verify_retained(args.store, args.backup)
    print(json.dumps({'verified': True, 'counts': manifest['counts'], 'noteRevisionsUnchanged': revisions, 'backupFiles': len(json.loads((args.backup / 'BACKUP.json').read_bytes())['files'])}, sort_keys=True))
    os.close(lock)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, sqlite3.Error) as error:
        print(f'Refused: {error}', file=sys.stderr)
        sys.exit(1)
