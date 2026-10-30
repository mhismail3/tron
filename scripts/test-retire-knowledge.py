"""Real-process preservation oracles for the offline, one-shot Knowledge retirement."""
import hashlib
import json
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name('retire-knowledge.py')

class Retirement(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='knowledge-retirement-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name).resolve()
        self.store = self.root / 'store'
        self.store.mkdir(mode=0o700)
        self.files = self.root / 'research'
        self.backup = self.root / 'backup'
        self.catalog = self.store / 'catalog-fixture.sqlite'
        (self.store / 'state.json').write_text(json.dumps({'storageVersion':4,'schemaVersion':1,'catalogID':'fixture'}))
        (self.store / 'initialized.json').write_text('{}')
        self.db = sqlite3.connect(self.catalog)
        self.db.executescript('CREATE TABLE control(id INTEGER PRIMARY KEY,value TEXT); CREATE TABLE entries(collection TEXT,key TEXT,value TEXT,PRIMARY KEY(collection,key)); CREATE TABLE revision_owners(revision TEXT PRIMARY KEY,record TEXT); PRAGMA user_version=1;')
        self.db.execute('INSERT INTO control VALUES(1,?)',(json.dumps({'stateRevision':12,'schemaVersion':1,'catalogID':'fixture','profileSorting':'unchanged','config':{}}),))
        self.payloads = {}
        self.note_object = b'profile attachment unchanged'
        self.source_object = b'original source\x00bytes\xff'
        (self.store / 'objects').mkdir()
        for data in (self.note_object,self.source_object):
            (self.store / 'objects' / hashlib.sha256(data).hexdigest()).write_bytes(data)
        for kind, identity, scope, revisions in [('note','profile','personal',2),('source','source','research',2),('observation','observation','personal',1)]:
            ids=[]
            for n in range(revisions):
                revision=f'{identity}-rev-{n}';ids.append(revision)
                obj = self.note_object if kind=='note' else self.source_object
                record={'schemaVersion':1,'id':identity,'revisionId':revision,'kind':kind,'scope':scope,'createdAt':'2026-01-01','updatedAt':'2026-01-02','provenance':{'actor':'user','source':'fixture'},'relations':[], 'content':{'title':'Faithful source','body':'Café\nsecond line','uri':'https://example.com/source','objects':[{'hash':hashlib.sha256(obj).hexdigest(),'bytes':len(obj),'mediaType':'application/octet-stream'}]}}
                raw=(json.dumps(record,ensure_ascii=False)+'\n').encode();self.payloads[(identity,revision)]=raw
                folder=self.store/'records'/identity;folder.mkdir(parents=True,exist_ok=True);(folder/(revision+'.json')).write_bytes(raw)
                self.db.execute('INSERT INTO revision_owners VALUES(?,?)',(revision,identity))
            self.entry('records',identity,{'kind':kind,'scope':scope,'latestRevisionId':ids[-1],'revisionIds':ids,'objectHashes':[hashlib.sha256(obj).hexdigest()]})
        self.entry('coverage','coverage',{'disposition':'observed'})
        self.entry('receipts','profile-write',{'operation':'knowledge.note.update','recordIds':['profile'],'result':{'revisionId':'profile-rev-1'}})
        self.entry('receipts','source-write',{'operation':'knowledge.source.capture','recordIds':['source'],'result':{}})
        self.entry('sourceIdentities','source-key','source')
        self.db.commit();self.db.close()
    def entry(self,collection,key,value):
        self.db.execute('INSERT INTO entries VALUES(?,?,?)',(collection,json.dumps(key),json.dumps(value)))
    def command(self,*extra):
        return [sys.executable,str(SCRIPT),'--store',str(self.store),'--files',str(self.files),'--backup',str(self.backup),'--expected-sources','1','--expected-observations','1','--expected-notes','1','--expected-coverage','1','--offline',*extra]
    def run_command(self,*extra,ok=True):
        result=subprocess.run(self.command(*extra),capture_output=True,text=True)
        if ok:self.assertEqual(result.returncode,0,result.stderr)
        else:self.assertNotEqual(result.returncode,0,result.stdout)
        return result
    def test_plain_files_preserve_every_source_revision_object_and_profile(self):
        self.run_command()
        self.run_command('--verify')
        manifest=json.loads((self.files/'MANIFEST.json').read_text())
        self.assertEqual(manifest['counts'],{'sources':1,'sourceRevisions':2,'notes':1,'observations':1,'coverage':1})
        for (identity,rev),raw in self.payloads.items():
            if identity=='source':
                self.assertEqual((self.files/'sources'/identity/rev/'original.json').read_bytes(),raw)
                text=(self.files/'sources'/identity/rev/'source.md').read_text()
                self.assertIn('Café\nsecond line',text);self.assertIn('https://example.com/source',text)
                self.assertIn(identity,text);self.assertIn(rev,text)
            elif identity=='profile': self.assertEqual((self.store/'records'/identity/(rev+'.json')).read_bytes(),raw)
        digest=hashlib.sha256(self.source_object).hexdigest()
        self.assertEqual((self.files/'attachments'/digest).read_bytes(),self.source_object)
        with sqlite3.connect(self.catalog) as db:
            self.assertEqual(db.execute("SELECT count(*) FROM entries WHERE collection='records'").fetchone()[0],1)
            self.assertEqual(db.execute("SELECT count(*) FROM entries WHERE collection='coverage'").fetchone()[0],0)
            self.assertEqual(db.execute("SELECT value FROM control").fetchone()[0],json.dumps({'stateRevision':12,'schemaVersion':1,'catalogID':'fixture','profileSorting':'unchanged','config':{}}))
        self.assertFalse((self.store/'records'/'observation').exists())
        self.assertFalse((self.store/'records'/'source').exists())
        self.assertTrue(self.backup.is_dir())
    def test_rerun_is_idempotent_and_verify_detects_modified_export(self):
        self.run_command();before=(self.files/'MANIFEST.json').read_bytes();self.run_command();self.assertEqual((self.files/'MANIFEST.json').read_bytes(),before)
        (self.files/'attachments'/hashlib.sha256(self.source_object).hexdigest()).write_bytes(b'tampered')
        self.run_command('--verify',ok=False)
    def test_process_crash_cuts_resume_without_replaying_note_mutations(self):
        # Test-only tracing terminates the real CLI process at durable boundaries;
        # the shipped converter has no fault hooks, mocks, sleeps or retry mode.
        boundaries = [
            'retired = export_sources(args.backup, args.files, expected)',
            'retire(args.store, args.backup, retired)',
            "if current.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':",
            "sync_dir(store / 'records')",
        ]
        original = self.root / 'original'
        import shutil
        shutil.copytree(self.store, original)
        for boundary in boundaries:
            with self.subTest(boundary=boundary):
                shutil.rmtree(self.store)
                shutil.copytree(original, self.store)
                if self.files.exists(): shutil.rmtree(self.files)
                if self.backup.exists(): shutil.rmtree(self.backup)
                wrapper = "import sys,os,runpy; from pathlib import Path\np=Path(sys.argv[1]); target=" + repr(boundary) + "\nline=next(i for i,s in enumerate(p.read_text().splitlines(),1) if s.strip()==target)\ndef trace(frame,event,arg):\n if event=='line' and frame.f_code.co_filename==str(p) and frame.f_lineno==line: os._exit(97)\n return trace\nsys.argv=sys.argv[1:];sys.settrace(trace);runpy.run_path(str(p),run_name='__main__')\n"
                result = subprocess.run([sys.executable, '-c', wrapper, *self.command()[1:]],capture_output=True,text=True)
                self.assertEqual(result.returncode,97,result.stderr)
                self.run_command();self.run_command('--verify');self.run_command()
    def test_existing_backup_cannot_retire_changed_current_payload(self):
        import shutil
        self.run_command()
        shutil.rmtree(self.store)
        shutil.copytree(self.backup,self.store,ignore=shutil.ignore_patterns('BACKUP.json'))
        changed=self.store/'records'/'source'/'source-rev-1.json'
        changed.write_bytes(changed.read_bytes()+b' ')
        before=self.catalog.read_bytes()
        self.run_command(ok=False)
        self.assertEqual(self.catalog.read_bytes(),before)
        self.assertTrue(changed.exists())
    def test_verify_rejects_leftover_retired_object(self):
        self.run_command()
        hash_value=hashlib.sha256(self.source_object).hexdigest()
        (self.store/'objects'/hash_value).write_bytes(self.source_object)
        self.run_command('--verify',ok=False)
    def test_unknown_orphan_object_is_preserved_not_silently_retired(self):
        orphan=b'unowned by any committed record'
        hash_value=hashlib.sha256(orphan).hexdigest()
        path=self.store/'objects'/hash_value
        path.write_bytes(orphan)
        self.run_command();self.run_command('--verify')
        self.assertEqual(path.read_bytes(),orphan)
    def test_privacy_fences_refuse_plaintext_publication_without_new_disposition(self):
        import shutil
        for collection, key, value in [
            ('suppressions','source',{'excluded':True,'forgotten':False}),
            ('scopeExclusions','session:private',{'excluded':True}),
        ]:
            with self.subTest(collection=collection):
                with sqlite3.connect(self.catalog) as db:
                    db.execute('DELETE FROM entries WHERE collection IN (?,?)',('suppressions','scopeExclusions'))
                    db.execute('INSERT INTO entries VALUES(?,?,?)',(collection,json.dumps(key),json.dumps(value)))
                before=self.catalog.read_bytes()
                self.run_command(ok=False)
                self.assertEqual(self.catalog.read_bytes(),before)
                self.assertFalse(self.files.exists())
                self.assertTrue((self.store/'records'/'source'/'source-rev-1.json').exists())
                shutil.rmtree(self.backup)
    def test_normal_file_search_citations_and_explicit_export_deletion(self):
        import shutil
        self.run_command()
        found=subprocess.run(['rg','--files-with-matches','Café',str(self.files/'sources')],capture_output=True,text=True,check=True)
        paths=[pathlib.Path(line) for line in found.stdout.splitlines()]
        self.assertEqual(len(paths),4)  # readable Markdown and exact JSON, two revisions
        for path in paths:
            self.assertIn('https://example.com/source',path.read_text())
        self.assertEqual(self.files.stat().st_mode & 0o077,0)
        for path in self.files.rglob('*'):
            if path.is_file():self.assertEqual(path.stat().st_mode & 0o077,0)
        # Ordinary tools own deliberate file deletion after export. The recovery
        # archive is separate and intentionally retained, never a runtime reader.
        shutil.rmtree(self.files/'sources'/'source')
        (self.files/'attachments'/hashlib.sha256(self.source_object).hexdigest()).unlink()
        absent=subprocess.run(['rg','--files-with-matches','Café',str(self.files/'sources')],capture_output=True,text=True)
        self.assertEqual(absent.returncode,1)
        self.assertTrue((self.backup/'records'/'source'/'source-rev-1.json').exists())
        self.assertEqual((self.store/'records'/'profile'/'profile-rev-1.json').read_bytes(),self.payloads[('profile','profile-rev-1')])
    def test_existing_public_output_refuses_private_publication(self):
        self.files.mkdir(mode=0o755)
        self.files.chmod(0o755)
        before=self.catalog.read_bytes()
        self.run_command(ok=False)
        self.assertEqual(self.catalog.read_bytes(),before)
        self.assertEqual(list(self.files.iterdir()),[])
    def test_count_drift_refuses_before_backup_or_mutation(self):
        before=self.catalog.read_bytes();self.run_command('--expected-notes','2',ok=False)
        self.assertEqual(self.catalog.read_bytes(),before);self.assertFalse(self.backup.exists());self.assertFalse(self.files.exists())
    def test_unsafe_links_refused_before_backup(self):
        target=self.store/'objects'/hashlib.sha256(self.source_object).hexdigest();target.unlink();target.symlink_to('/etc/hosts')
        self.run_command(ok=False);self.assertFalse(self.backup.exists())

if __name__=='__main__': unittest.main()
