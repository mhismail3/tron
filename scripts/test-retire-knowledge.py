"""Real CLI and current-Profile-boundary oracles for the offline retirement."""
import hashlib
import json
import pathlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import uuid

SCRIPT = pathlib.Path(__file__).with_name('retire-knowledge.py').resolve()
REPO = SCRIPT.parent.parent


class Retirement(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='knowledge-retirement-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name).resolve()
        self.home = self.root / 'tron'
        for directory in (self.home, self.home / 'workspace', self.home / 'workspace/state', self.home / 'gateway', self.home / 'gateway/workspace-state'):
            directory.mkdir(mode=0o700)
        self.store = self.home / 'workspace/state/knowledge'
        self.store.mkdir(mode=0o700)
        self.profile = self.store.with_name('profile')
        self.marker = self.home / 'gateway/workspace-state/initialized.json'
        self.write(self.marker, json.dumps({'version': 1, 'knowledgeInitialized': True}).encode())
        self.files, self.backup = self.root / 'research', self.root / 'backup'
        self.catalog_id = '7138d908-5bb5-49a3-8f38-3bd5d7b33a1d'
        self.catalog = self.store / f'catalog-{self.catalog_id}.sqlite'
        self.write(self.store / 'state.json', json.dumps({'storageVersion': 4, 'schemaVersion': 1, 'catalogID': self.catalog_id}).encode())
        self.write(self.store / 'initialized.json', b'{"version":1}')
        self.config = {'schemaVersion': 1, 'revision': 7, 'eligibility': {'excludedSessionIds': [], 'excludedProjectIds': []}, 'maximumSearchResults': 50}
        self.control = {'stateRevision': 12, 'schemaVersion': 1, 'catalogID': self.catalog_id, 'profileSorting': hashlib.sha256(b'unchanged').hexdigest(), 'config': {**self.config, 'retiredSourceSetting': True}}
        self.db = sqlite3.connect(self.catalog)
        self.db.executescript('CREATE TABLE control(id INTEGER PRIMARY KEY,value TEXT); CREATE TABLE entries(collection TEXT,key TEXT,value TEXT,PRIMARY KEY(collection,key)); CREATE TABLE revision_owners(revision TEXT PRIMARY KEY,record TEXT); PRAGMA user_version=1;')
        self.db.execute('INSERT INTO control VALUES(1,?)', (json.dumps(self.control),))
        self.payloads = {}
        self.note_object, self.source_object = b'profile attachment unchanged', b'original source\x00bytes\xff'
        (self.store / 'objects').mkdir(mode=0o700)
        for data in (self.note_object, self.source_object):
            self.write(self.store / 'objects' / hashlib.sha256(data).hexdigest(), data)
        for kind, identity, scope, count in [('note', 'profile', 'personal', 2), ('source', 'source', 'research', 2), ('observation', 'observation', 'personal', 1)]:
            revisions = []
            for index in range(count):
                revision = self.revision(identity, index)
                revisions.append(revision)
                obj = self.note_object if kind == 'note' else self.source_object
                content = {'title': 'Faithful source', 'body': 'Café\nsecond line', 'uri': 'https://example.com/source', 'objects': [{'hash': hashlib.sha256(obj).hexdigest(), 'bytes': len(obj), 'mediaType': 'application/octet-stream'}]}
                if kind == 'note':
                    content = {'title': 'Profile preference', 'body': f'Exact Profile edition {index}.', 'role': 'preference', 'confirmed': False, 'tags': ['home-profile', 'kind-preference'], 'profile': {'version': 2, 'path': ['inferred', 'review']}}
                record = {'schemaVersion': 1, 'id': identity, 'revisionId': revision, 'kind': kind, 'scope': scope, 'createdAt': '2026-01-01T00:00:00.000Z', 'updatedAt': '2026-01-02T00:00:00.000Z', 'provenance': {'actor': 'user', 'source': 'fixture', 'evidence': [{'recordId': 'source', 'revisionId': self.revision('source', 0), 'objectHash': hashlib.sha256(obj).hexdigest()}]}, 'relations': [], 'content': content}
                raw = (json.dumps(record, ensure_ascii=False) + '\n').encode()
                self.payloads[(identity, revision)] = raw
                folder = self.store / 'records' / identity
                folder.mkdir(parents=True, exist_ok=True, mode=0o700)
                self.write(folder / (revision + '.json'), raw)
                self.db.execute('INSERT INTO revision_owners VALUES(?,?)', (revision, identity))
            self.entry('records', identity, {'kind': kind, 'scope': scope, 'latestRevisionId': revisions[-1], 'revisionIds': revisions, 'objectHashes': [hashlib.sha256(obj).hexdigest()], 'recordRefs': [], 'sortAt': 1767312000000, 'createdAt': record['createdAt'], 'updatedAt': record['updatedAt'], 'searchFields': [['body', content['body']]]})
        self.entry('coverage', 'coverage', {'disposition': 'observed'})
        initial = json.loads(self.payloads[('profile', self.revision('profile', 0))])
        target = json.loads(self.payloads[('profile', self.revision('profile', 1))])
        self.update = {'commandId': 'profile-update-0001', 'recordId': 'profile', 'expectedRevision': initial['revisionId'], 'record': {**initial, 'content': target['content']}}
        operation = 'knowledge.note.update'
        request_hash = hashlib.sha256((operation + '\0' + json.dumps(self.update, ensure_ascii=False, separators=(',', ':'))).encode()).hexdigest()
        self.entry('receipts', operation + '\0' + self.update['commandId'], {'operation': operation, 'requestHash': request_hash, 'recordIds': ['profile'], 'createdAt': target['updatedAt'], 'result': {'kind': 'record', 'recordId': 'profile', 'revisionId': target['revisionId'], 'stateRevision': 2}})
        self.entry('receipts', 'source-write', {'operation': 'knowledge.source.capture', 'recordIds': ['source'], 'result': {}})
        self.entry('sourceIdentities', 'source-key', 'source')
        self.db.commit()
        self.db.close()
        self.catalog.chmod(0o600)

    @staticmethod
    def revision(identity, index):
        return str(uuid.uuid5(uuid.NAMESPACE_URL, f'tron-fixture/{identity}/{index}'))

    @staticmethod
    def write(path, data):
        path.write_bytes(data)
        path.chmod(0o600)

    def entry(self, collection, key, value):
        self.db.execute('INSERT INTO entries VALUES(?,?,?)', (collection, json.dumps(key), json.dumps(value)))

    def command(self, *extra):
        return [sys.executable, str(SCRIPT), '--store', str(self.store), '--files', str(self.files), '--backup', str(self.backup), '--expected-sources', '1', '--expected-observations', '1', '--expected-notes', '1', '--expected-coverage', '1', '--offline', *extra]

    def run_command(self, *extra, ok=True):
        result = subprocess.run(self.command(*extra), capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, ok, result.stderr + result.stdout)
        return result

    def cut(self, boundary, occurrence=1):
        wrapper = "import sys,os,runpy; from pathlib import Path\np=Path(sys.argv[1]); target=" + repr(boundary) + "; wanted=" + str(occurrence) + "\nline=next(i for i,s in enumerate(p.read_text().splitlines(),1) if s.strip()==target)\nhits=0\ndef trace(frame,event,arg):\n global hits\n if event=='line' and frame.f_code.co_filename==str(p) and frame.f_lineno==line:\n  hits+=1\n  if hits==wanted: os._exit(97)\n return trace\nsys.argv=sys.argv[1:];sys.settrace(trace);runpy.run_path(str(p),run_name='__main__')\n"
        result = subprocess.run([sys.executable, '-c', wrapper, *self.command()[1:]], capture_output=True, text=True)
        self.assertEqual(result.returncode, 97, result.stderr)

    def replacement(self, resume=False):
        """Real filesystem/clone/converter and child-process boundary; no host app or job."""
        import tron_mac_replace as replace
        from tron_mac_replace_platform import MacPlatform
        from tron_mac_replace_journal import Journal

        fixture = self

        class CopyPlatform(MacPlatform):
            start_timeout = 3

            def __init__(self):
                super().__init__(fixture.root / 'account')
                self.installed = fixture.root / 'Tron.app'
                self.process = None
                self.launches = []
                self.fail_start = False

            @property
            def tron_home(self):
                return fixture.home

            def app_running(self):
                return self.process is not None and self.process.poll() is None

            def offline_blocker(self):
                return 'fixture process still running' if self.app_running() else None

            def launchd_state(self, label):
                return 'absent'  # This fixture owns child processes, not host jobs.

            def quit_app(self, log):
                if self.process is not None:
                    if self.app_running():
                        self.process.terminate()
                    self.process.wait(timeout=5)
                    self.process.stdout.close()
                    self.process.stderr.close()
                    self.process = None

            def launch_app(self, log):
                revision = json.loads((self.bundled_gateway(self.installed) / 'manifest.json').read_text())['sourceRevision']
                self.launches.append(revision)
                program = ('import json,sys,time; from pathlib import Path; '
                           'home=Path(sys.argv[1]); revision=sys.argv[2]; '
                           'assert revision=="old-app" or not (home/"workspace/state/knowledge").exists(), "unconverted data"; '
                           'print(json.dumps({"sourceRevision": "old-runtime" if revision=="old-app" else revision,"protocolVersion":1}),flush=True); time.sleep(60)')
                if self.fail_start and revision == 'new':
                    program = 'raise SystemExit(42)'
                self.process = subprocess.Popen([sys.executable, '-u', '-c', program, str(self.tron_home), revision], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                line = self.process.stdout.readline()
                if not line:
                    self.quit_app(None)
                    raise replace.Failure('fixture candidate process failed before readiness')
                self.info = json.loads(line)

            def system_info(self):
                if not self.app_running():
                    raise replace.RpcError('unreachable', 'fixture process stopped')
                return self.info

            def mutation(self, *args, **kwargs):
                return {}

        platform = CopyPlatform()
        self.addCleanup(lambda: platform.quit_app(None))
        if resume:
            journal = Journal(platform.store / 'copy-operation').load()
            return replace.Runner(platform, journal), platform, platform.maintenance / 'knowledge-cutover-pending.json'
        for root, revision in ((platform.bundled_gateway(platform.installed), 'old-app'), (platform.stable_channel() / 'versions/old', 'old-runtime')):
            root.mkdir(mode=0o700, parents=True)
            self.write(root / 'manifest.json', json.dumps({'sourceRevision': revision}).encode())
        self.write(platform.stable_channel() / 'current.json', b'{"version":"old"}')
        candidate = self.root / 'candidate.app'
        platform.bundled_gateway(candidate).mkdir(parents=True)
        self.write(platform.bundled_gateway(candidate) / 'manifest.json', b'{"sourceRevision":"new"}')
        platform.maintenance.mkdir(mode=0o700, parents=True)
        pending = platform.maintenance / 'knowledge-cutover-pending.json'
        self.write(pending, json.dumps({'version': 1, 'priorAppRevision': 'old-app', 'priorGatewayRevision': 'old-runtime', 'converterSHA256': hashlib.sha256(SCRIPT.read_bytes()).hexdigest()}).encode())
        journal = Journal.create(platform.store / 'copy-operation', 'copy-operation', 'full', 'copy hook test', {'root': str(REPO), 'revision': 'new', 'fromRevision': 'old-runtime'})
        journal.data['artifact'] = {'path': str(candidate), 'cdhash': 'fixture'}
        # Exercise the complete production hook, start and exception/recovery loop.
        # Build/drain are covered by mac-replace's separate actual-Gateway E2E.
        journal.data['steps'] = [step for step in journal.data['steps'] if step['name'] in ('swap-app', 'start')]
        journal.save()
        return replace.Runner(platform, journal), platform, pending

    def test_replace_converts_only_offline_before_candidate_start(self):
        runner, platform, pending = self.replacement()
        platform.launch_app(None)
        self.assertEqual(runner.run(), 1)
        self.assertTrue(self.store.exists())
        self.assertEqual(platform.launches, ['old-app'])
        platform.quit_app(None)
        self.assertEqual(runner.run(), 0, runner.data.get('error'))
        self.assertEqual(platform.launches, ['old-app', 'new'])
        self.assertFalse(self.store.exists())
        self.assertTrue(self.profile.exists())
        self.assertFalse(pending.exists())
        self.assertEqual(json.loads(self.marker.read_text()), {'version': 1})

    def test_replace_privacy_refusal_restores_data_and_never_starts_candidate(self):
        runner, platform, pending = self.replacement()
        with sqlite3.connect(self.catalog) as db:
            db.execute('INSERT INTO entries VALUES(?,?,?)', ('scopeExclusions', json.dumps('private'), json.dumps({'excluded': True})))
        original = {str(path.relative_to(self.store)): path.read_bytes() for path in self.store.rglob('*') if path.is_file()}
        marker = self.marker.read_bytes()
        self.assertEqual(runner.run(), 1)
        self.assertEqual(runner.data['state'], 'rolled-back', runner.data.get('error'))
        self.assertEqual(platform.launches, ['old-app'])
        self.assertTrue(pending.exists())
        self.assertEqual(original, {str(path.relative_to(self.store)): path.read_bytes() for path in self.store.rglob('*') if path.is_file()})
        self.assertEqual(self.marker.read_bytes(), marker)
        self.assertFalse(self.profile.exists())
        self.assertEqual(json.loads((platform.stable_channel() / 'current.json').read_text()), {'version': 'old'})

    def test_replace_copy_failure_after_conversion_restores_exact_prior_namespaces(self):
        runner, platform, pending = self.replacement()
        original = {str(path.relative_to(self.store)): path.read_bytes() for path in self.store.rglob('*') if path.is_file()}
        marker = self.marker.read_bytes()
        # An invalid artifact is an actual failed ditto input, after conversion.
        shutil.rmtree(pathlib.Path(runner.data['artifact']['path']))
        self.assertEqual(runner.run(), 1)
        self.assertEqual(runner.data['state'], 'rolled-back', runner.data.get('error'))
        self.assertEqual(platform.launches, ['old-app'])
        self.assertTrue(pending.exists())
        self.assertEqual(original, {str(path.relative_to(self.store)): path.read_bytes() for path in self.store.rglob('*') if path.is_file()})
        self.assertEqual(self.marker.read_bytes(), marker)
        self.assertFalse(self.profile.exists())
        self.assertFalse(self.marker.with_name('profile-initialized.json').exists())
        self.assertTrue(list(runner.journal.directory.glob('knowledge-cutover-*/archive/BACKUP.json')))

    def test_replace_candidate_start_failure_restores_old_app_payload_and_data(self):
        runner, platform, pending = self.replacement()
        original = self.catalog.read_bytes()
        platform.fail_start = True
        self.assertEqual(runner.run(), 1)
        self.assertEqual(runner.data['state'], 'rolled-back', runner.data.get('error'))
        self.assertEqual(platform.launches, ['new', 'old-app'])
        self.assertEqual(self.catalog.read_bytes(), original)
        self.assertTrue(pending.exists())
        self.assertFalse(self.profile.exists())
        self.assertTrue(list(runner.journal.directory.glob('knowledge-cutover-*/archive/BACKUP.json')))

    def test_replace_process_crash_after_conversion_recovers_before_any_candidate_start(self):
        import tron_mac_replace as replace
        from tron_mac_replace_journal import Journal
        runner, platform, pending = self.replacement()
        original = self.catalog.read_bytes()
        # exec a fresh interpreter: macOS system frameworks are not fork-safe.
        program = "import sys,os,runpy; from pathlib import Path; sys.path.insert(0,sys.argv[1]); m=runpy.run_path(sys.argv[1]+'/test-retire-knowledge.py'); f=m['Retirement']('test_plain_files_and_new_profile_preserve_every_committed_revision'); f.root=Path(sys.argv[2]); f.home=f.root/'tron'; r,p,_=f.replacement(resume=True); r.journal.begin_attempt({'pid':os.getpid()}); r.step_swap_app(); os._exit(97)"
        child = subprocess.run([sys.executable, '-c', program, str(SCRIPT.parent), str(self.root)], capture_output=True, text=True)
        self.assertEqual(child.returncode, 97, child.stderr)
        recovered = replace.Runner(platform, Journal(runner.journal.directory).load())
        # run() must recover the interrupted transaction before attempting steps;
        # the fixture deliberately has no stop step for the newly restored app.
        self.assertEqual(recovered.run(), 1)
        self.assertEqual(platform.launches, ['old-app'])
        self.assertEqual(self.catalog.read_bytes(), original)
        self.assertTrue(pending.exists())
        self.assertFalse(self.profile.exists())

    def test_replace_without_knowledge_is_noop_without_pending_approval(self):
        runner, platform, pending = self.replacement()
        shutil.rmtree(self.store)
        pending.unlink()
        self.assertEqual(runner.run(), 0, runner.data.get('error'))
        self.assertEqual(platform.launches, ['new'])
        self.assertFalse(list(runner.journal.directory.glob('knowledge-cutover-*')))

    def test_replace_missing_approval_never_starts_candidate(self):
        runner, platform, pending = self.replacement()
        pending.unlink()
        before = self.catalog.read_bytes()
        self.assertEqual(runner.run(), 1)
        self.assertEqual(platform.launches, ['old-app'])
        self.assertEqual(self.catalog.read_bytes(), before)
        self.assertFalse(self.profile.exists())

    def test_plain_files_and_new_profile_preserve_every_committed_revision(self):
        result = self.run_command()
        self.assertTrue(json.loads(result.stdout)['knowledgeNamespaceAbsent'])
        self.run_command('--verify')
        self.assertFalse(self.store.exists())
        manifest = json.loads((self.files / 'MANIFEST.json').read_text())
        self.assertEqual(manifest['counts'], {'sources': 1, 'sourceRevisions': 2, 'notes': 1, 'observations': 1, 'coverage': 1})
        for (identity, revision), raw in self.payloads.items():
            if identity == 'source':
                self.assertEqual((self.files / 'sources' / identity / revision / 'original.json').read_bytes(), raw)
                text = (self.files / 'sources' / identity / revision / 'source.md').read_text()
                for value in ('Café\nsecond line', 'https://example.com/source', identity, revision):
                    self.assertIn(value, text)
            elif identity == 'profile':
                self.assertEqual((self.profile / 'records' / identity / (revision + '.json')).read_bytes(), raw)
        for data, directory in ((self.source_object, self.files / 'attachments'), (self.note_object, self.profile / 'objects')):
            self.assertEqual((directory / hashlib.sha256(data).hexdigest()).read_bytes(), data)
        with sqlite3.connect(self.profile / self.catalog.name) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM entries WHERE collection='records'").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT count(*) FROM entries WHERE collection='coverage'").fetchone()[0], 0)
            self.assertEqual(json.loads(db.execute('SELECT value FROM control').fetchone()[0]), {**self.control, 'config': self.config})
        self.assertEqual(json.loads(self.marker.read_text()), {'version': 1})
        self.assertEqual(json.loads((self.profile / 'state.json').read_text())['storageVersion'], 1)

    def test_real_current_owner_reads_history_and_replays_the_accepted_profile_receipt(self):
        self.run_command()
        hook, program, request, target = [self.root / name for name in ('resolve.mjs', 'read-profile.mjs', 'request.json', 'target.json')]
        hook.write_text("import {registerHooks} from 'node:module'; registerHooks({resolve(s,c,next){try{return next(s,c)}catch(e){if(s.endsWith('.js'))return next(s.slice(0,-3)+'.ts',c);throw e}}});")
        request.write_text(json.dumps(self.update, ensure_ascii=False))
        target.write_bytes(self.payloads[('profile', self.revision('profile', 1))])
        program.write_text("import fs from 'node:fs/promises';\n" +
            f"const {{TronWorkspace}}=await import({json.dumps((REPO / 'packages/gateway/src/workspace/tron-workspace.ts').as_uri())});\n" +
            f"const {{ProfileStore}}=await import({json.dumps((REPO / 'packages/gateway/src/modules/home/profile-store.ts').as_uri())});\n" +
            "const [home,request,target]=process.argv.slice(2); const workspace=new TronWorkspace(home); await workspace.initialize();\n" +
            "try { const store=new ProfileStore(workspace); const expected=JSON.parse(await fs.readFile(target,'utf8')); const replay=await store.updateNote(JSON.parse(await fs.readFile(request,'utf8'))); if(JSON.stringify(replay.record)!==JSON.stringify(expected))throw new Error('Receipt changed the original revision'); const page=await store.list(); const metadata=await store.profileMetadata(); process.stdout.write(JSON.stringify({receiptRevision:replay.stateRevision,stateRevision:page.stateRevision,notes:page.records.length,metadata:metadata.rows.length,files:(await fs.readdir(home+'/workspace/state/profile/records/profile')).length})); } finally {await workspace.dispose();}\n")
        result = subprocess.run([str(REPO / 'scripts/tron-node'), 'exec', 'node', '--experimental-transform-types', '--import', str(hook), str(program), str(self.home), str(request), str(target)], cwd=REPO, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'receiptRevision': 2, 'stateRevision': 12, 'notes': 1, 'metadata': 1, 'files': 2})
        self.run_command('--verify')

    def test_process_crash_cuts_resume_without_replaying_note_mutations(self):
        original = self.root / 'original'
        shutil.copytree(self.store, original)
        original_marker = self.marker.read_bytes()
        boundaries = [('export_sources(args.backup, args.files, expected, verify_only=sealed)', 1), ('publish_profile(args.store, args.backup, profile)', 1), ('os.rename(stage, profile)', 1), ('sync_dir(profile.parent)', 1), ('os.rename(store, retiring)', 1), ('path.unlink()', 4)]
        for boundary, occurrence in boundaries:
            with self.subTest(boundary=boundary):
                for path in (self.store, self.store.with_name('knowledge.retiring'), self.profile, self.profile.with_name('profile.retirement-partial'), self.files, self.backup):
                    if path.exists(): shutil.rmtree(path)
                shutil.copytree(original, self.store)
                self.write(self.marker, original_marker)
                self.marker.with_name('profile-initialized.json').unlink(missing_ok=True)
                self.cut(boundary, occurrence)
                self.run_command(); self.run_command('--verify'); self.run_command()
                self.assertEqual((self.profile / 'records/profile' / (self.revision('profile', 1) + '.json')).read_bytes(), self.payloads[('profile', self.revision('profile', 1))])

    def test_existing_backup_refuses_changed_current_payload_before_publication(self):
        self.cut('export_sources(args.backup, args.files, expected, verify_only=sealed)')
        changed = self.store / 'records/source' / (self.revision('source', 1) + '.json')
        changed.write_bytes(changed.read_bytes() + b' ')
        before = self.catalog.read_bytes()
        result = self.run_command(ok=False)
        self.assertIn('changed after backup', result.stderr)
        self.assertEqual(self.catalog.read_bytes(), before)
        self.assertTrue(changed.exists())
        self.assertFalse(self.profile.exists())

    def test_rerun_and_read_only_verify_never_restore_a_deliberately_deleted_export(self):
        self.run_command(); before = (self.files / 'MANIFEST.json').read_bytes(); self.run_command()
        self.assertEqual((self.files / 'MANIFEST.json').read_bytes(), before)
        path = self.files / 'attachments' / hashlib.sha256(self.source_object).hexdigest()
        path.unlink()
        self.run_command('--verify', ok=False); self.run_command(ok=False)
        self.assertFalse(path.exists())

    def test_recreated_retired_namespace_is_refused_not_accepted_as_complete(self):
        self.run_command()
        self.store.mkdir(mode=0o700)
        self.write(self.store / 'leftover', self.source_object)
        self.run_command('--verify', ok=False)
        self.assertTrue((self.store / 'leftover').exists())

    def test_unknown_orphan_object_remains_in_the_verified_recovery_archive(self):
        orphan = b'unowned by any committed record'
        name = hashlib.sha256(orphan).hexdigest()
        self.write(self.store / 'objects' / name, orphan)
        self.run_command(); self.run_command('--verify')
        self.assertEqual((self.backup / 'objects' / name).read_bytes(), orphan)
        self.assertFalse(self.store.exists())

    def test_privacy_fences_refuse_plaintext_publication_without_disposition(self):
        for collection, key, value in [('suppressions', 'source', {'excluded': True, 'forgotten': False}), ('scopeExclusions', 'session:private', {'excluded': True})]:
            with self.subTest(collection=collection):
                with sqlite3.connect(self.catalog) as db:
                    db.execute('DELETE FROM entries WHERE collection IN (?,?)', ('suppressions', 'scopeExclusions'))
                    db.execute('INSERT INTO entries VALUES(?,?,?)', (collection, json.dumps(key), json.dumps(value)))
                before = self.catalog.read_bytes()
                self.run_command(ok=False)
                self.assertEqual(self.catalog.read_bytes(), before)
                self.assertFalse(self.files.exists()); self.assertFalse(self.profile.exists())
                shutil.rmtree(self.backup)

    def assert_configured_scope_refusal(self, field, excluded):
        control = json.loads(json.dumps(self.control))
        control['config']['eligibility'][field] = [excluded]
        with sqlite3.connect(self.catalog) as db:
            db.execute('UPDATE control SET value=? WHERE id=1', (json.dumps(control),))
            head = json.loads(db.execute("SELECT value FROM entries WHERE collection='records' AND key=?", (json.dumps('source'),)).fetchone()[0])
            if field == 'excludedSessionIds':
                head['sessionId'] = excluded
            else:
                head['scope'] = 'project'
                head['projectId'] = excluded
            db.execute("UPDATE entries SET value=? WHERE collection='records' AND key=?", (json.dumps(head), json.dumps('source')))
        for index in range(2):
            path = self.store / 'records/source' / (self.revision('source', index) + '.json')
            source = json.loads(path.read_bytes())
            if field == 'excludedSessionIds':
                source['provenance']['sessionId'] = excluded
            else:
                source['scope'] = 'project'
                source['provenance']['source'] = excluded
            self.write(path, json.dumps(source).encode())
        before = self.catalog.read_bytes()
        result = self.run_command(ok=False)
        self.assertIn('privacy disposition', result.stderr)
        self.assertEqual(self.catalog.read_bytes(), before)
        self.assertFalse(self.files.exists()); self.assertFalse(self.profile.exists())
        self.assertTrue(self.store.exists())

    def test_configured_session_exclusion_refuses_plaintext_without_disposition(self):
        self.assert_configured_scope_refusal('excludedSessionIds', 'private-session')

    def test_configured_project_exclusion_refuses_plaintext_without_disposition(self):
        self.assert_configured_scope_refusal('excludedProjectIds', 'private-project')

    def test_normal_file_search_citations_private_modes_and_explicit_deletion(self):
        self.run_command()
        found = subprocess.run(['rg', '--files-with-matches', 'Café', str(self.files / 'sources')], capture_output=True, text=True, check=True)
        paths = [pathlib.Path(line) for line in found.stdout.splitlines()]
        self.assertEqual(len(paths), 4)
        for path in paths: self.assertIn('https://example.com/source', path.read_text())
        self.assertEqual(self.files.stat().st_mode & 0o077, 0)
        for path in self.files.rglob('*'):
            if path.is_file(): self.assertEqual(path.stat().st_mode & 0o077, 0)
        shutil.rmtree(self.files / 'sources/source')
        self.assertEqual(subprocess.run(['rg', '--files-with-matches', 'Café', str(self.files / 'sources')], capture_output=True).returncode, 1)
        self.assertTrue((self.backup / 'records/source' / (self.revision('source', 1) + '.json')).exists())
        self.assertEqual((self.profile / 'records/profile' / (self.revision('profile', 1) + '.json')).read_bytes(), self.payloads[('profile', self.revision('profile', 1))])

    def test_existing_public_output_refuses_private_publication(self):
        self.files.mkdir(mode=0o755); self.files.chmod(0o755)
        before = self.catalog.read_bytes(); self.run_command(ok=False)
        self.assertEqual(self.catalog.read_bytes(), before); self.assertEqual(list(self.files.iterdir()), [])

    def test_count_drift_and_unsafe_links_refuse_before_backup(self):
        before = self.catalog.read_bytes(); self.run_command('--expected-notes', '2', ok=False)
        self.assertEqual(self.catalog.read_bytes(), before); self.assertFalse(self.backup.exists())
        target = self.store / 'objects' / hashlib.sha256(self.source_object).hexdigest()
        target.unlink(); target.symlink_to('/etc/hosts')
        self.run_command(ok=False); self.assertFalse(self.backup.exists())

    def test_unowned_staging_directory_is_preserved_not_erased(self):
        stage = self.backup.with_name('backup.partial')
        stage.mkdir(mode=0o700)
        self.write(stage / 'unrelated', b'not this converter')
        self.run_command(ok=False)
        self.assertEqual((stage / 'unrelated').read_bytes(), b'not this converter')
        self.assertFalse(self.backup.exists()); self.assertTrue(self.store.exists())


if __name__ == '__main__':
    unittest.main()
