"""Failure-first tests for the typed issue/Project work-write boundary.

Failure modes: (1) filing/triage/promotion and native links have no typed
work command; (2) arbitrary labels/statuses can bypass taxonomy and claim
ownership; (3) a compound Project update hides a committed first field when a
later write fails; (4) retrying issue/Project links duplicates canonical work;
(5) a failed request leaks public text or bypasses the shared audit; (6)
overlapping independent label additions overwrite each other; (7) a missing
live Project option is discovered only after another requested field commits;
(8) valid multi-area issues are refused or lose areas during unrelated flag
updates; (9) typed issue filing cannot represent multiple valid areas, zero
areas or undeclared areas; (10) a fake GitHub reader parses truncated shared
state instead of waiting for the existing remote-state owner lock.
"""
from __future__ import annotations

import json
import os
import select
import signal
import socket
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))


_FAKE_GH = r'''#!/usr/bin/env python3
import fcntl, json, os, socket, sys, time
args=sys.argv[1:]
state_path=os.environ['TRACKING_STATE']
trace_path=os.environ['TRACKING_TRACE']
def default_state():
 return {'number':101,'item':False,'fields':{},'labels':[],'writes':[],'updates':0,'subs':[],'blockers':[]}
# Each fake-gh invocation is a process; protect both the initial snapshot and
# truncate/write window. Callers release this lock before any test barrier.
def locked_state(mode, change=None):
 lock=os.open(state_path+'.lock',os.O_CREAT|os.O_RDWR,0o600)
 contention_socket=os.environ.get('TRACKING_STATE_CONTENTION_SOCKET')
 if contention_socket:
  try: fcntl.flock(lock,mode|fcntl.LOCK_NB)
  except BlockingIOError:
   with socket.socket(socket.AF_UNIX,socket.SOCK_DGRAM) as marker: marker.sendto(b'blocked',contention_socket)
   fcntl.flock(lock,mode)
 else: fcntl.flock(lock,mode)
 try:
  try: current=json.load(open(state_path))
  except FileNotFoundError: current=default_state()
  if change:
   change(current)
   with open(state_path,'w') as stream: json.dump(current,stream)
  return current
 finally:
  fcntl.flock(lock,fcntl.LOCK_UN); os.close(lock)
def read_state(): return locked_state(fcntl.LOCK_SH)
def update_state(change): return locked_state(fcntl.LOCK_EX,change)
state=read_state()
with open(trace_path,'a') as f: f.write(json.dumps(args)+'\n')
def save():
 snapshot=json.loads(json.dumps(state))
 def replace(current):
  current.clear(); current.update(snapshot)
 update_state(replace)
def wait_for(path):
 deadline=time.time()+10
 while not os.path.exists(path):
  if time.time()>deadline: print('fixture barrier timed out',file=sys.stderr); sys.exit(3)
  time.sleep(.01)
def output(value, code=0):
 print(json.dumps(value)); sys.exit(code)
if args[:2] == ['repo','view']:
 output({'id':'REPO_NODE','nameWithOwner':'owner/repo','owner':{'login':'owner'}})
if args and args[0]=='api' and args[1]!='graphql':
 method='GET'
 for i,a in enumerate(args[:-1]):
  if a in ('-X','--method'): method=args[i+1].upper()
 path=args[args.index('-X')+2] if '-X' in args else args[-1]
 body=json.load(sys.stdin) if '--input' in args else None
 if path.endswith('/issues') and method=='POST':
  state['labels']=body['labels']; state['writes'].append({'method':method,'path':path,'body':body}); save()
  output({'number':101,'node_id':'ISSUE_101','title':body['title'],'labels':[{'name':x} for x in body['labels']]})
 if '/issues/' in path and method=='GET':
  number=int(path.rsplit('/',1)[-1]); labels=list(state['labels']) if number==101 else (['epic'] if number==154 else ['task'])
  barrier=os.environ.get('TRACKING_LABEL_BARRIER'); worker=os.environ.get('TRACKING_LABEL_WORKER')
  if barrier and worker:
   open(os.path.join(barrier,worker+'-read'),'w').close()
   wait_for(os.path.join(barrier,'a-read')); wait_for(os.path.join(barrier,'b-read'))
  output({'number':number,'node_id':f'ISSUE_{number}','labels':[{'name':x} for x in labels]})
 if '/issues/' in path and (method=='PATCH' or (method=='POST' and path.endswith('/labels'))):
  worker=os.environ.get('TRACKING_LABEL_WORKER'); barrier=os.environ.get('TRACKING_LABEL_BARRIER')
  if worker=='b' and barrier: wait_for(os.path.join(barrier,'a-written'))
  def change(current):
   if method=='PATCH': current['labels']=body.get('labels',current['labels'])
   else: current['labels']=list(dict.fromkeys(current['labels']+body.get('labels',[])))
   current['writes'].append({'method':method,'path':path,'body':body})
  latest=update_state(change)
  if worker=='a' and barrier: open(os.path.join(barrier,'a-written'),'w').close()
  output({'number':101,'labels':[{'name':x} for x in latest['labels']]})
 if '/issues/' in path and method=='DELETE' and '/labels/' in path:
  from urllib.parse import unquote
  label=unquote(path.rsplit('/',1)[-1])
  def change(current):
   current['labels']=[x for x in current['labels'] if x!=label]
   current['writes'].append({'method':method,'path':path,'label':label})
  update_state(change); output(None)
 print('unhandled REST',args,file=sys.stderr); sys.exit(2)
if args[:3]==['api','graphql','--input']:
 request=json.load(sys.stdin); q=request['query']; v=request.get('variables',{})
 if 'mutation' not in q:
  if 'projectsV2' in q:
   fields=[{'id':'STATUS_FIELD','name':'Status','dataType':'SINGLE_SELECT','options':[{'id':'PROPOSED','name':'Proposed'},{'id':'READY','name':'Ready'},{'id':'NEEDS','name':'Needs you'},{'id':'BLOCKED','name':'Blocked'},{'id':'PROGRESS','name':'In progress'},{'id':'REVIEW','name':'In review'},{'id':'DONE','name':'Done'}]},{'id':'PRIORITY_FIELD','name':'Priority','dataType':'SINGLE_SELECT','options':[{'id':'P0','name':'P0'},{'id':'P1','name':'P1'},{'id':'P2','name':'P2'},{'id':'P3','name':'P3'}]}]
   if os.environ.get('TRACKING_MISSING_PRIORITY_OPTION'):
    fields[1]['options']=[option for option in fields[1]['options'] if option['name']!='P2']
   project={'id':'PROJECT_NODE','number':1,'title':'Tron','closed':False,'public':False,'shortDescription':'','url':'https://example.invalid/project','repositories':{'nodes':[{'id':'REPO_NODE'}]},'fields':{'nodes':fields}}
   output({'data':{'repositoryOwner':{'id':'OWNER_NODE','projectsV2':{'pageInfo':{'hasNextPage':False,'endCursor':None},'nodes':[project]}}}})
  if 'projectItems' in q:
   nodes=[{'id':'ITEM_101','project':{'id':'PROJECT_NODE'}}] if state['item'] else []
   output({'data':{'node':{'projectItems':{'pageInfo':{'hasNextPage':False,'endCursor':None},'nodes':nodes}}}})
  if 'subIssues' in q or 'blockedBy' in q:
   output({'data':{'node':{'subIssues':{'nodes':[{'id':x} for x in state['subs']]},'blockedBy':{'nodes':[{'id':x} for x in state['blockers']]}}}})
 if 'addProjectV2ItemById' in q:
  if state['item']:
   output({'data':{'addProjectV2ItemById':{'item':{'id':'ITEM_101'}}}})
  state['item']=True; state['writes'].append({'mutation':'addProjectV2ItemById'}); save()
  output({'data':{'addProjectV2ItemById':{'item':{'id':'ITEM_101'}}}})
 if 'updateProjectV2ItemFieldValue' in q:
  state['updates']+=1
  if state['updates']==int(os.environ.get('TRACKING_FAIL_UPDATE_AT','0')):
   print('HTTP 422 rejected field update',file=sys.stderr); sys.exit(1)
  state['fields'][v['field']]=v['option']; state['writes'].append({'mutation':'updateProjectV2ItemFieldValue','field':v['field'],'option':v['option']}); save()
  output({'data':{'updateProjectV2ItemFieldValue':{'projectV2Item':{'id':'ITEM_101'}}}})
 if 'addSubIssue' in q:
  state['subs'].append(v['child']); state['writes'].append({'mutation':'addSubIssue'}); save(); output({'data':{'addSubIssue':{'issue':{'id':'ISSUE_101'}}}})
 if 'addBlockedBy' in q:
  state['blockers'].append(v['blocker']); state['writes'].append({'mutation':'addBlockedBy'}); save(); output({'data':{'addBlockedBy':{'issue':{'id':'ISSUE_101'}}}})
 print('unhandled GraphQL',q,file=sys.stderr); sys.exit(2)
print('unhandled gh',args,file=sys.stderr); sys.exit(2)
'''


class TypedTrackingCommandTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        (self.root / '.github').mkdir()
        (self.root / 'scripts').mkdir()
        (self.root / '.github/work.json').write_text((ROOT / '.github/work.json').read_text())
        config = json.loads((self.root / '.github/work.json').read_text())
        config['verify']['scrubCommand'] = 'python3 scripts/guard.py'
        (self.root / '.github/work.json').write_text(json.dumps(config))
        (self.root / 'scripts/guard.py').write_text(
            "import sys\nsys.exit(1 if 'BLOCKED_TEXT' in sys.stdin.read() else 0)\n"
        )
        self.fake = self.root / 'fake-gh'
        self.fake_errors = self.root / 'fake-gh-errors.log'
        fake_script = ("#!/usr/bin/env python3\nimport os, traceback\ntry:\n" +
                       textwrap.indent(_FAKE_GH, '    ') +
                       "except SystemExit:\n    raise\nexcept BaseException:\n"
                       "    with open(os.environ['TRACKING_FAKE_ERROR_LOG'], 'a') as stream:\n"
                       "        traceback.print_exc(file=stream)\n    raise\n")
        self.fake.write_text(fake_script)
        self.fake.chmod(0o755)
        self.state = self.root / 'remote-state.json'
        self.trace = self.root / 'calls.jsonl'
        self.env = dict(os.environ, WORK_GH=str(self.fake), TRACKING_STATE=str(self.state),
                        TRACKING_TRACE=str(self.trace), TRACKING_FAKE_ERROR_LOG=str(self.fake_errors),
                        PI_SESSION_ID='fixture-session')
        self.env.pop('WORK_SESSION_ID', None)
        self.body = self.root / 'issue.md'
        self.body.write_text('A bounded task body.')

    def tearDown(self):
        self.tmp.cleanup()

    def cli(self, *args, env=None):
        return subprocess.run([sys.executable, str(HERE / 'cli.py'), *args], cwd=self.root,
                              env=env or self.env, capture_output=True, text=True)

    def state_json(self):
        return json.loads(self.state.read_text())

    def test_file_classify_project_and_relationship_writes_are_typed_and_audited(self):
        created = self.cli('issue', 'create', '--title', 'Bounded task', '--body-file', str(self.body),
                           '--kind', 'kind:maintenance', '--visibility', 'visibility:internal',
                           '--area', 'area:tooling')
        self.assertEqual(created.returncode, 0, created.stderr)
        labels = self.cli('issue', 'labels', '101', '--remove', 'needs-triage', '--add', 'needs-decision')
        self.assertEqual(labels.returncode, 0, labels.stderr)
        self.assertEqual(self.cli('issue', 'labels', '101', '--remove', 'needs-triage', '--add', 'needs-decision').returncode, 0)
        added = self.cli('project', 'add', '101')
        self.assertEqual(added.returncode, 0, added.stderr)
        self.assertEqual(self.cli('project', 'add', '101').returncode, 0)
        configured = self.cli('project', 'set', '101', '--status', 'Proposed', '--priority', 'P2')
        self.assertEqual(configured.returncode, 0, configured.stderr)
        parent = self.cli('issue', 'parent', '101', '--epic', '154')
        self.assertEqual(parent.returncode, 0, parent.stderr)
        self.assertEqual(self.cli('issue', 'parent', '101', '--epic', '154').returncode, 0)
        blocker = self.cli('issue', 'block', '101', '--blocked-by', '9')
        self.assertEqual(blocker.returncode, 0, blocker.stderr)
        self.assertEqual(self.cli('issue', 'block', '101', '--blocked-by', '9').returncode, 0)

        state = self.state_json()
        self.assertEqual(set(state['labels']), {'task', 'needs-decision', 'kind:maintenance',
                                                'visibility:internal', 'area:tooling'})
        self.assertIn({'method': 'POST', 'path': 'repos/owner/repo/issues/101/labels',
                       'body': {'labels': ['needs-decision']}}, state['writes'])
        self.assertIn({'method': 'DELETE', 'path': 'repos/owner/repo/issues/101/labels/needs-triage',
                       'label': 'needs-triage'}, state['writes'])
        self.assertTrue(state['item'])
        self.assertEqual(state['fields'], {'STATUS_FIELD': 'PROPOSED', 'PRIORITY_FIELD': 'P2'})
        self.assertEqual(state['subs'], ['ISSUE_101'])
        self.assertEqual(state['blockers'], ['ISSUE_9'])
        self.assertEqual([w['mutation'] for w in state['writes'] if 'mutation' in w],
                         ['addProjectV2ItemById', 'updateProjectV2ItemFieldValue',
                          'updateProjectV2ItemFieldValue', 'addSubIssue', 'addBlockedBy'])
        audit = [json.loads(line) for line in (Path(self.root / '.git/work/github-writes.jsonl')).read_text().splitlines()]
        attempts = [row for row in audit if row['event'] == 'attempt']
        results = [row for row in audit if row['event'] == 'result']
        self.assertEqual(len(attempts), 8)
        self.assertEqual(len(results), 8)
        self.assertTrue(all(row['status'] == 'succeeded' for row in results))
        self.assertNotIn('Bounded task', json.dumps(audit))
        self.assertNotIn('A bounded task body.', json.dumps(audit))

    def test_issue_label_flags_preserve_multiple_declared_areas(self):
        created = self.cli('issue', 'create', '--title', 'Multi-area task', '--body-file', str(self.body),
                           '--kind', 'kind:maintenance', '--visibility', 'visibility:internal', '--area', 'area:ios')
        self.assertEqual(created.returncode, 0, created.stderr)
        state = self.state_json()
        state['labels'] = ['task', 'kind:maintenance', 'visibility:internal', 'area:ios', 'area:mac', 'needs-triage']
        self.state.write_text(json.dumps(state))
        changed = self.cli('issue', 'labels', '101', '--remove', 'needs-triage', '--add', 'needs-decision')
        self.assertEqual(changed.returncode, 0, changed.stderr)
        labels = set(self.state_json()['labels'])
        self.assertTrue({'area:ios', 'area:mac', 'needs-decision'} <= labels)
        self.assertNotIn('needs-triage', labels)

    def test_issue_creation_accepts_multiple_declared_areas(self):
        created = self.cli('issue', 'create', '--title', 'Cross-surface task', '--body-file', str(self.body),
                           '--kind', 'kind:maintenance', '--visibility', 'visibility:internal',
                           '--area', 'area:ios', '--area', 'area:mac')
        self.assertEqual(created.returncode, 0, created.stderr)
        self.assertTrue({'area:ios', 'area:mac'} <= set(self.state_json()['labels']))

    def test_fake_gh_reader_waits_for_truncated_state_writer(self):
        writer_source = r'''import fcntl, json, os, sys
state, ready_fd, release_fd = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
lock = os.open(state + '.lock', os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(lock, fcntl.LOCK_EX)
try:
    with open(state, 'w') as stream:
        os.write(ready_fd, b'T')
        if os.read(release_fd, 1) != b'R': raise SystemExit('writer release missing')
        json.dump({'number':101,'item':False,'fields':{},'labels':['task','needs-triage','kind:maintenance','visibility:internal','area:tooling'],'writes':[],'updates':0,'subs':[],'blockers':[]}, stream)
        stream.flush()
finally:
    fcntl.flock(lock, fcntl.LOCK_UN)
    os.close(lock)
'''
        ready_read, ready_write = os.pipe()
        release_read, release_write = os.pipe()
        contention_path = self.root / 'state-lock-contention.sock'
        contention = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        contention.bind(str(contention_path))
        writer = None
        reader = None

        def release_writer():
            nonlocal release_write
            if release_write is not None:
                try:
                    os.write(release_write, b'R')
                except OSError:
                    pass
                os.close(release_write)
                release_write = None

        try:
            writer = subprocess.Popen(
                [sys.executable, '-c', writer_source, str(self.state), str(ready_write), str(release_read)],
                pass_fds=(ready_write, release_read), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            os.close(ready_write)
            ready_write = None
            os.close(release_read)
            release_read = None
            self.assertEqual(os.read(ready_read, 1), b'T', 'writer did not open and truncate the state file')
            truncated_state = self.state.read_text(encoding='utf-8')
            self.assertEqual(truncated_state, '')

            env = dict(self.env, TRACKING_STATE_CONTENTION_SOCKET=str(contention_path))
            reader = subprocess.Popen(
                [sys.executable, str(HERE / 'cli.py'), 'issue', 'labels', '101', '--add', 'needs-decision'],
                cwd=self.root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            readable, _, _ = select.select([contention, reader.stderr], [], [])
            observed_contention = contention.recv(16) if contention in readable else b''
            if observed_contention != b'blocked':
                stdout, stderr = reader.communicate()
                trace = self.trace.read_text(encoding='utf-8') if self.trace.exists() else ''
                fake_errors = self.fake_errors.read_text(encoding='utf-8') if self.fake_errors.exists() else ''
                self.fail(f"fake-gh did not block on the held state lock; marker={observed_contention!r}; "
                          f"state while writer held EX={truncated_state!r}; rc={reader.returncode}; "
                          f"stdout={stdout!r}; stderr={stderr!r}; fake-gh errors={fake_errors!r}; "
                          f"fake-gh trace={trace!r}")

            release_writer()
            self.assertEqual(writer.wait(), 0, writer.stderr.read())
            stdout, stderr = reader.communicate()
            self.assertEqual(reader.returncode, 0, f"stdout={stdout!r}; stderr={stderr!r}")
            self.assertIn('updated labels on issue #101', stdout)
            self.assertEqual(self.state_json()['labels'],
                             ['task', 'needs-triage', 'kind:maintenance', 'visibility:internal',
                              'area:tooling', 'needs-decision'])
        finally:
            release_writer()
            try:
                if reader is not None:
                    reader.communicate()
            finally:
                try:
                    if writer is not None:
                        writer.wait()
                        if writer.stderr is not None:
                            writer.stderr.close()
                finally:
                    for fd in (ready_read, ready_write, release_read):
                        if fd is not None:
                            try:
                                os.close(fd)
                            except OSError:
                                pass
                    contention.close()

    def test_overlapping_independent_label_additions_preserve_both_remote_flags(self):
        created = self.cli('issue', 'create', '--title', 'Concurrent labels', '--body-file', str(self.body),
                           '--kind', 'kind:maintenance', '--visibility', 'visibility:internal', '--area', 'area:tooling')
        self.assertEqual(created.returncode, 0, created.stderr)
        barrier = self.root / 'barrier'
        barrier.mkdir()
        processes = []
        for worker, label in (('a', 'needs-decision'), ('b', 'regression')):
            env = dict(self.env, TRACKING_LABEL_BARRIER=str(barrier), TRACKING_LABEL_WORKER=worker)
            processes.append(subprocess.Popen(
                [sys.executable, str(HERE / 'cli.py'), 'issue', 'labels', '101', '--add', label],
                cwd=self.root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                start_new_session=True))
        try:
            outputs = [process.communicate(timeout=30) for process in processes]
        except BaseException:
            for process in processes:
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            for process in processes:
                try:
                    process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.communicate()
            raise
        self.assertEqual([process.returncode for process in processes], [0, 0], outputs)
        remote = self.state_json()
        labels = set(remote['labels'])
        calls = [json.loads(line) for line in self.trace.read_text(encoding='utf-8').splitlines()]
        label_writes = [write for write in remote['writes']
                        if write.get('path', '').endswith('/labels') or write.get('method') == 'PATCH']
        self.assertTrue({'needs-decision', 'regression'} <= labels,
                        f"remote labels={sorted(labels)}; label writes={label_writes}; fake-gh calls={calls}")

    def test_live_project_options_are_preflighted_before_any_field_mutation(self):
        created = self.cli('issue', 'create', '--title', 'Option drift', '--body-file', str(self.body),
                           '--kind', 'kind:maintenance', '--visibility', 'visibility:internal', '--area', 'area:tooling')
        self.assertEqual(created.returncode, 0, created.stderr)
        self.assertEqual(self.cli('project', 'add', '101').returncode, 0)
        env = dict(self.env, TRACKING_MISSING_PRIORITY_OPTION='1')
        result = self.cli('project', 'set', '101', '--status', 'Proposed', '--priority', 'P2', env=env)
        self.assertNotEqual(result.returncode, 0)
        state = self.state_json()
        self.assertEqual(state['fields'], {})
        self.assertEqual(state['updates'], 0)
        self.assertFalse(any(write.get('mutation') == 'updateProjectV2ItemFieldValue'
                             for write in state['writes']))

    def test_taxonomy_and_claim_owned_statuses_refuse_before_any_remote_write(self):
        self.body.write_text('BLOCKED_TEXT', encoding='utf-8')
        private = self.cli('issue', 'create', '--title', 'Private marker', '--body-file', str(self.body),
                           '--kind', 'kind:maintenance', '--visibility', 'visibility:internal', '--area', 'area:tooling')
        self.assertNotEqual(private.returncode, 0)
        self.assertIn('refused by the privacy guard', private.stderr)
        self.assertFalse(self.trace.exists())
        self.body.write_text('safe body', encoding='utf-8')
        invalid = self.cli('issue', 'create', '--title', 'Blocked', '--body-file', str(self.body),
                           '--kind', 'kind:bogus', '--visibility', 'visibility:internal',
                           '--area', 'area:tooling')
        self.assertNotEqual(invalid.returncode, 0)
        missing_area = self.cli('issue', 'create', '--title', 'Missing area', '--body-file', str(self.body),
                                '--kind', 'kind:maintenance', '--visibility', 'visibility:internal')
        self.assertNotEqual(missing_area.returncode, 0)
        invalid_area = self.cli('issue', 'create', '--title', 'Unknown area', '--body-file', str(self.body),
                                '--kind', 'kind:maintenance', '--visibility', 'visibility:internal',
                                '--area', 'area:unregistered')
        self.assertNotEqual(invalid_area.returncode, 0)
        invalid_label = self.cli('issue', 'labels', '101', '--add', 'arbitrary-label')
        self.assertNotEqual(invalid_label.returncode, 0)
        invalid_status = self.cli('project', 'set', '101', '--status', 'In progress')
        self.assertNotEqual(invalid_status.returncode, 0)
        self.assertFalse(self.trace.exists())
        self.assertFalse((self.root / '.git/work/github-writes.jsonl').exists())

    def test_partial_project_update_preserves_first_write_and_reports_exact_result_boundary(self):
        self.assertEqual(self.cli('issue', 'create', '--title', 'Bounded task', '--body-file', str(self.body),
                                  '--kind', 'kind:maintenance', '--visibility', 'visibility:internal',
                                  '--area', 'area:tooling').returncode, 0)
        self.assertEqual(self.cli('project', 'add', '101').returncode, 0)
        env = dict(self.env, TRACKING_FAIL_UPDATE_AT='2')
        partial = self.cli('project', 'set', '101', '--status', 'Proposed', '--priority', 'P2', env=env)
        self.assertNotEqual(partial.returncode, 0)
        state = self.state_json()
        self.assertEqual(state['fields'], {'STATUS_FIELD': 'PROPOSED'})
        audit = [json.loads(line) for line in (Path(self.root / '.git/work/github-writes.jsonl')).read_text().splitlines()]
        updates = [row for row in audit if row['event'] == 'result'][-2:]
        self.assertEqual([row['status'] for row in updates], ['succeeded', 'failed'])
        self.assertIn('Status updated', partial.stderr)
        self.assertIn('Priority failed', partial.stderr)


if __name__ == '__main__':
    unittest.main()
