"""Failure-first tests for the typed issue/Project work-write boundary.

Failure modes: (1) filing/triage/promotion and native links have no typed
work command; (2) arbitrary labels/statuses can bypass taxonomy and claim
ownership; (3) a compound Project update hides a committed first field when a
later write fails; (4) retrying issue/Project links duplicates canonical work;
(5) a failed request leaks public text or bypasses the shared audit; (6)
overlapping independent label additions overwrite each other; (7) a missing
live Project option is discovered only after another requested field commits.
"""
from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))


_FAKE_GH = r'''#!/usr/bin/env python3
import fcntl, json, os, sys, time
args=sys.argv[1:]
state_path=os.environ['TRACKING_STATE']
trace_path=os.environ['TRACKING_TRACE']
try: state=json.load(open(state_path))
except FileNotFoundError: state={'number':101,'item':False,'fields':{},'labels':[],'writes':[],'updates':0,'subs':[],'blockers':[]}
with open(trace_path,'a') as f: f.write(json.dumps(args)+'\n')
def save(): json.dump(state,open(state_path,'w'))
def update_state(change):
 lock=os.open(state_path+'.lock',os.O_CREAT|os.O_RDWR,0o600); fcntl.flock(lock,fcntl.LOCK_EX)
 try:
  current=json.load(open(state_path)); change(current); json.dump(current,open(state_path,'w'))
 finally:
  fcntl.flock(lock,fcntl.LOCK_UN); os.close(lock)
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
  update_state(change)
  latest=json.load(open(state_path))
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
        self.fake.write_text(_FAKE_GH)
        self.fake.chmod(0o755)
        self.state = self.root / 'remote-state.json'
        self.trace = self.root / 'calls.jsonl'
        self.env = dict(os.environ, WORK_GH=str(self.fake), TRACKING_STATE=str(self.state),
                        TRACKING_TRACE=str(self.trace), PI_SESSION_ID='fixture-session')
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
        self.assertTrue({'needs-decision', 'regression'} <= set(self.state_json()['labels']))

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
