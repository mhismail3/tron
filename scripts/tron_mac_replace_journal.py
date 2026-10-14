"""Durable step journal for `scripts/tron mac replace` (#984).

One operation directory owns one journal: `journal.json` is the authoritative
machine-readable record (atomic replace), `journal.log` is its plain-text
narrative for a terminal (`--status --follow`, or the iPhone SSH terminal), and
`logs/<step>.log` holds each step's full command output. The Gateway only reads
these files; the orchestrator is their single writer.
"""
import datetime
import json
import os
from pathlib import Path
import tempfile

SCHEMA = 1
KIND = 'tron-mac-replace'
FULL_STEPS = ('preflight', 'build', 'verify-signature', 'drain-workers', 'stop-gateway',
              'swap-app', 'start', 'verify', 'finish')
QUICK_STEPS = ('preflight', 'drain-workers', 'rebuild', 'verify', 'finish')
# Steps whose verified product survives a failed attempt. Every other step
# observes or changes live state, so a retry always runs it again.
REUSABLE_STEPS = ('build', 'verify-signature')
TERMINAL_STATES = ('succeeded', 'failed', 'rolled-back', 'rollback-failed')
STEP_TITLES = {
    'preflight': 'Preflight', 'build': 'Build signed app', 'verify-signature': 'Verify signature',
    'drain-workers': 'Stop running workers', 'stop-gateway': 'Stop Gateway', 'swap-app': 'Swap app',
    'start': 'Start new app', 'verify': 'Verify Gateway', 'rebuild': 'Rebuild Gateway from source',
    'finish': 'Finish',
}


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')


def private_mkdir(path):
    path = Path(path)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def write_json_atomic(path, value):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix='.journal-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, indent=1, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class Journal:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.path = self.directory / 'journal.json'
        self.log_path = self.directory / 'journal.log'
        self.data = None

    @classmethod
    def create(cls, directory, operation_id, path, reason, source):
        journal = cls(private_mkdir(directory))
        private_mkdir(journal.directory / 'logs')
        steps = FULL_STEPS if path == 'full' else QUICK_STEPS
        journal.data = {
            'schema': SCHEMA, 'kind': KIND, 'id': operation_id, 'createdAt': now(), 'updatedAt': now(),
            'path': path, 'reason': reason, 'source': source, 'state': 'queued', 'currentStep': None,
            'attempt': 0, 'steps': [{'name': name, 'title': STEP_TITLES[name], 'state': 'pending'} for name in steps],
            'error': None, 'workers': [], 'swap': {}, 'rollback': None, 'artifact': None, 'result': None,
            'notification': None, 'logPath': str(journal.log_path),
        }
        journal.save()
        return journal

    def load(self):
        with self.path.open() as stream:
            data = json.load(stream)
        if not isinstance(data, dict) or data.get('schema') != SCHEMA or data.get('kind') != KIND:
            raise ValueError(f'invalid replacement journal: {self.path}')
        self.data = data
        return self

    def save(self):
        self.data['updatedAt'] = now()
        write_json_atomic(self.path, self.data)

    def note(self, text):
        with self.log_path.open('a') as stream:
            stream.write(f'{now()} {text}\n')

    def step(self, name):
        for step in self.data['steps']:
            if step['name'] == name:
                return step
        raise KeyError(name)

    def step_log(self, name):
        return self.directory / 'logs' / f'{name}.log'

    def begin_attempt(self, runner):
        self.data['attempt'] += 1
        self.data['state'] = 'running'
        self.data['error'] = None
        self.data['rollback'] = None
        self.data['runner'] = runner
        for step in self.data['steps']:
            if step['state'] != 'done' or step['name'] not in REUSABLE_STEPS:
                step.update(state='pending', startedAt=None, endedAt=None, durationSeconds=None, detail=None)
        self.save()
        self.note(f'attempt {self.data["attempt"]} started: {self.data["path"]} path ({self.data["reason"]})')

    def start_step(self, name):
        step = self.step(name)
        step.update(state='running', startedAt=now(), endedAt=None, durationSeconds=None, detail=None,
                    log=str(self.step_log(name)))
        self.data['currentStep'] = name
        self.save()
        self.note(f'{name}: started')

    def progress(self, name, detail):
        self.step(name)['detail'] = detail
        self.save()
        self.note(f'{name}: {detail}')

    def finish_step(self, name, detail, state='done'):
        step = self.step(name)
        step.update(state=state, endedAt=now(), detail=detail)
        if step.get('startedAt'):
            started = datetime.datetime.fromisoformat(step['startedAt'].replace('Z', '+00:00'))
            ended = datetime.datetime.fromisoformat(step['endedAt'].replace('Z', '+00:00'))
            step['durationSeconds'] = round((ended - started).total_seconds(), 1)
        self.save()
        duration = f' ({step["durationSeconds"]}s)' if step.get('durationSeconds') is not None else ''
        self.note(f'{name}: {state}{duration}' + (f' - {detail}' if detail else ''))

    def fail_step(self, name, message):
        step = self.step(name)
        log = str(self.step_log(name))
        self.finish_step(name, message, state='failed')
        self.data['error'] = {'step': name, 'message': message, 'log': log}
        self.save()

    def settle(self, state):
        self.data['state'] = state
        self.data['currentStep'] = None
        self.data['endedAt'] = now()
        self.save()
        self.note(f'operation {state}')


def describe(data):
    """Human-readable status, quiet on success, exact on failure."""
    lines = [f'Mac replacement {data["id"]} · {data["path"]} path · {data["state"]} (attempt {data["attempt"]})',
             f'Reason: {data["reason"]}',
             f'Source: {data["source"].get("revision", "?")[:12]} in {data["source"].get("root", "?")}']
    for step in data['steps']:
        marker = {'done': 'ok', 'running': '..', 'failed': '!!', 'pending': '  ', 'skipped': '--'}.get(step['state'], '??')
        duration = f' {step["durationSeconds"]}s' if step.get('durationSeconds') is not None else ''
        detail = f' - {step["detail"]}' if step.get('detail') else ''
        lines.append(f' [{marker}] {step["title"]}{duration}{detail}')
    if data.get('error'):
        lines.append(f'ERROR at {data["error"]["step"]}: {data["error"]["message"]}')
        lines.append(f'Log: {data["error"]["log"]}')
    if data.get('rollback'):
        lines.append(f'Rollback: {data["rollback"].get("state")} - {data["rollback"].get("detail", "")}')
    if data.get('workers'):
        lines.append('Stopped workers (resume each in place from iPhone Settings → Connections):')
        for worker in data['workers']:
            lines.append(f'  {worker["taskId"]} · {worker.get("title", "")} · session {worker.get("sessionId")}')
    lines.append(f'Journal: {data.get("logPath")}')
    return '\n'.join(lines)
