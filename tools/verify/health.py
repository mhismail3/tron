#!/usr/bin/env python3
"""On-demand, local scorecard. Reads reports, never sessions or private stores."""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import subprocess
from statistics import median
import sys
import tempfile
import time

import batch

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = 'tron.health.v1'
RETENTION = {'aggregateDays': 30, 'digestDays': 90}


def git(*args: str) -> str:
    # Batch remains the process-group/cancellation owner. Its transient Git log
    # never enters the scorecard, and is removed only after the child is joined.
    with tempfile.TemporaryDirectory(prefix='tron-health-git-') as temporary, redirect_stdout(io.StringIO()):
        directory = Path(temporary)
        result = batch.execute(ROOT, {'name': 'health git read', 'command': ['git', *args]}, directory)
        if result['exit']:
            raise subprocess.CalledProcessError(result['exit'], 'git')
        return (directory / 'output.log').read_text().strip()


def read(path: Path) -> dict:
    if path.is_symlink() or path.stat().st_size > 16 * 1024 * 1024:
        raise ValueError('source is symlinked or exceeds 16 MiB')
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError('source is not an object')
    return value


def field(status: str, numerator=None, denominator=0, reasons=(), **values) -> dict:
    return dict(status=status, numerator=numerator, denominator=denominator, reasons=list(reasons), **values)


def distribution(samples: list[float]) -> dict:
    ordered = sorted(samples)
    return {'samples': len(samples), 'median': median(ordered) if ordered else None,
            'p90': ordered[math.ceil(len(ordered) * .9) - 1] if ordered else None}


def deploy(main: str, mac: dict | None, iphone: dict | None) -> dict:
    cohorts = {}
    # Existing owner projections, not a second identity classifier: Mac's
    # verified selected payload manifest; iPhone's log-capture metadata.
    for name, value, revision_key, build_key in (
        ('mac', mac or {}, 'sourceRevision', 'payloadFingerprint'),
        ('iphone', iphone or {}, 'appSourceRevision', 'appBuildIdentity'),
    ):
        sha = value.get(revision_key)
        if not isinstance(sha, str) or not re.fullmatch('[0-9a-f]{40}', sha):
            cohorts[name] = field('unavailable', reasons=['installed source identity absent'])
            continue
        missing = []
        if not value.get(build_key) or value.get(build_key) == 'unknown':
            missing.append('build identity absent')
        if not value.get('protocolVersion'):
            missing.append('protocol identity absent from owner export')
        try:
            git('merge-base', '--is-ancestor', sha, main)
            cohorts[name] = field('partial' if missing else 'available', int(git('rev-list', '--count', f'{sha}..{main}')), 1,
                                  missing, sourceRevision=sha)
        except subprocess.CalledProcessError:
            cohorts[name] = field('partial', reasons=['source is unknown or not an ancestor of pinned main'])
    count = sum(c['status'] == 'available' for c in cohorts.values())
    return field('available' if count == 2 else 'partial' if mac or iphone else 'unavailable', count, 2,
                 [] if count == 2 else ['both installed cohort identities required; no build-number subtraction'], cohorts=cohorts,
                 integrationAgeSeconds=None, ageReason='server integration timestamp absent; commit time is not push time')


def score(main: str, reports: list[dict], mac: dict | None, iphone: dict | None) -> dict:
    exact = [r for r in reports if r.get('commit') == main and r.get('schema') == 'tron.verify.v1']
    verdicts = Counter(r.get('verdict') if r.get('verdict') in ('passed', 'quarantined', 'failed', 'running', 'interrupted', 'incomplete') else 'unknown' for r in exact)
    quarantined, waived, failures, attempts = set(), set(), set(), defaultdict(list)
    harness = 0
    gaps = []
    refusals = Counter()
    for report in exact:
        if report.get('sourceRefusal') in ('registry-expired', 'registry-invalid'):
            refusals[report['sourceRefusal']] += 1
            gaps.append(report['sourceRefusal'])
        if report.get('skipped') or report.get('selection', {}).get('deferredTests'):
            gaps.append('skipped or deferred tests')
        if report.get('selection', {}).get('docsOnly'):
            gaps.append('static-only report is not main test coverage')
        if report.get('verdict') not in ('passed', 'quarantined'):
            gaps.append('non-complete verifier outcome retained')
        for step in report.get('steps', []):
            if step.get('status') in ('skipped', 'running', 'interrupted') and step.get('name', '').startswith('tests:'):
                gaps.append('missing or interrupted test lane')
            qualified = {hashlib.sha256(q['testId'].encode()).hexdigest() for q in step.get('quarantined', [])}
            quarantined.update(qualified)
            for case in step.get('caseOutcomes', []):
                if not re.fullmatch('[0-9a-f]{64}', case['caseDigest']) or (case['status'] == 'failed' and not re.fullmatch('[0-9a-f]{64}', case['failureDigest'])):
                    raise ValueError('invalid case digest')
                if case['status'] == 'failed':
                    signature = (case['caseDigest'], case['failureDigest'])
                    failures.add(signature)
                    if case['caseDigest'] in qualified:
                        waived.add(signature)
            if step.get('status') == 'failed' and not any(c['status'] == 'failed' for c in step.get('caseOutcomes', [])):
                harness += 1
        # Only the source owner can assert a case was actually executed. Older
        # reports with just group totals cannot supply a comparable denominator.
        if not report.get('caseEvidenceComplete'):
            gaps.append('case-level evidence absent or incomplete')
        key = report.get('attemptId')
        if key:
            config = report.get('configDigest')
            for step in report.get('steps', []):
                for case in step.get('caseOutcomes', []):
                    if config and case['status'] in ('passed', 'failed'):
                        attempts[(config, case['caseDigest'])].append((key, case['status'], case.get('failureDigest')))
    comparable = []
    changed = 0
    for values in attempts.values():
        unique = {v[0]: v for v in values}.values()
        if len({v[2] for v in unique if v[1] == 'failed'}) > 1:
            changed += 1
        elif len(unique) > 1:
            comparable.append(list(unique))
    flaky = sum(len({v[1] for v in values}) == 2 for values in comparable)
    observed_attempts = [v for values in attempts.values() for v in {v[0]: v for v in values}.values()]
    failing = sum(v[1] == 'failed' for v in observed_attempts)
    total = len(observed_attempts)
    reasons = sorted(set(gaps))
    case_evidence = any(step.get('caseOutcomes') for report in exact for step in report.get('steps', []))
    main_reds = field('partial' if exact else 'unavailable', len(failures - waived) if case_evidence else None, len(exact),
                     reasons + ([] if exact else ['no exact-SHA verifier report']) + ['affected reports do not prove all main lanes; first-failure/fix/owner timestamps absent'],
                     distinctFailures=len(failures) if case_evidence else None,
                     newRedSignatures=len(failures - waived) if case_evidence else None,
                     quarantinedCases=len(quarantined) if exact else None, harnessErrors=harness if exact else None,
                     verifierOutcomes=dict(verdicts), sourceRefusals=dict(refusals), firstFailureToFixSeconds=None, firstFailureToOwnerSeconds=None)
    flake = field('partial' if comparable and (gaps or changed) else 'available' if comparable else 'unavailable',
                  flaky if comparable else None, len(comparable), reasons + (['changed failure signatures excluded'] if changed else [])
                  + ([] if comparable else ['no comparable repeated case attempts; one attempt is unknown, not zero']),
                  failingAttempts=failing if observed_attempts else None, totalAttempts=total, changedSignatureCases=changed,
                  rate=flaky / len(comparable) if comparable else None)
    return {'approvalToMain': field('unavailable', reasons=['explicit intent approval and server landed timestamps absent; #2128 seam pending'],
                                   seconds=distribution([]), executionSeconds=None, waitingSeconds=None),
            'deployLag': deploy(main, mac, iphone), 'mainReds': main_reds, 'flakeRate': flake,
            'resumesPerTask': field('unavailable', reasons=['complete root-lineage aggregate from home.taskHistory absent'],
                                    resumes=distribution([]))}


def landed_changes(main: str, reports: list[dict]) -> list[dict]:
    """Local successful-push observations, never commit dates masquerading as land times."""
    history = git('rev-list', '--first-parent', '--max-count=20', main).splitlines()
    try:
        entries = [line.split('\t', 2) for line in git('reflog', 'show', '-1000', '--date=unix',
                   '--format=%H%x09%gD%x09%gs', 'refs/remotes/origin/main').splitlines()]
    except subprocess.CalledProcessError:
        entries = []
    pushes = {}
    for index, (sha, selector, action) in enumerate(entries):
        stamp = re.search(r'@\{(\d+)\}$', selector)
        if action == 'update by push' and stamp and sha in history:
            # Repeated pushes of the same tip retain the earliest observation.
            pushes[sha] = (int(stamp[1]), entries[index + 1][0] if index + 1 < len(entries) else None)
    rows = []
    for sha in [s for s in history if s in pushes or s == main]:
        stamp, previous = pushes.get(sha, (None, None))
        commits = [sha]
        first = None
        seconds = None
        if stamp is not None and previous:
            try:
                git('merge-base', '--is-ancestor', previous, sha)
                commits = git('rev-list', '--reverse', '--max-count=1001', f'{previous}..{sha}').splitlines()
                if 0 < len(commits) <= 1000:
                    dates = [(int(line.split()[1]), line.split()[0]) for line in
                             git('log', '--format=%H %at', f'{previous}..{sha}').splitlines()]
                    authored, first = min(dates)
                    seconds = stamp - authored if stamp >= authored else None
            except subprocess.CalledProcessError:
                pass
        attempts = {}
        for commit in commits[:1000]:
            path = ROOT / 'test-results/verify' / f'{commit}.json'
            try:
                sources = [*reports, read(path)] if path.exists() else reports
            except (OSError, ValueError):
                sources = reports
            for report in sources:
                if report.get('schema') == 'tron.verify.v1' and report.get('commit') == commit and report.get('attemptId'):
                    attempts[(commit, report['attemptId'])] = report
        durations = [step['seconds'] for report in attempts.values() for step in report.get('steps', [])
                     if step.get('name', '').startswith('tests:') and step.get('status') in ('ok', 'failed', 'quarantined')
                     and type(step.get('seconds')) in (int, float) and math.isfinite(step['seconds']) and step['seconds'] >= 0]
        rows.append({'commit': sha, 'firstCommit': first, 'introducedCommits': len(commits) if first else None,
                     'publicationObservedAt': datetime.fromtimestamp(stamp, timezone.utc).isoformat() if stamp else None,
                     'commitToPublication': field('partial' if seconds is not None else 'unavailable',
                         reasons=['Git author time to local successful-push reflog observation, not request-to-server-land time']
                         if seconds is not None else ['successful-push timestamp and preceding ancestor tip unavailable, or invalid author clock'], seconds=seconds),
                     'testMinutes': field('partial' if durations else 'unavailable', denominator=len(attempts),
                         reasons=['retained completed test-step wall time only; overwritten attempts and direct suite logs are not inferred'],
                         minutes=sum(durations) / 60 if durations else None)})
    return rows


def goal_metrics(resumes: dict) -> dict:
    return {'requestToMain': field('unavailable', reasons=['request timestamp and server main-publication join absent']),
            'mainGreenRate': field('unavailable', reasons=['no complete per-main-commit Gateway/Python/iOS baseline cohort']),
            'rework': {'fullSuiteReruns': field('unavailable', reasons=['retained reports overwrite attempts; --all is locks, not a full-suite census']),
                       'revertsPerSlice': field('unavailable', reasons=['slice-to-revert attribution absent']),
                       'resumesPerSlice': field('unavailable', reasons=['task lineages are not joined to landed slices']),
                       'observedResumesPerTask': resumes},
            'escapedRegressions': field('unavailable', reasons=['post-land regression attribution and observation window absent'])}


def owner_summary(source: dict, now: datetime) -> tuple[dict, dict]:
    """Read an explicit source-owner diagnostic export, not its private log store."""
    rows = source.get('records', [])
    if not isinstance(rows, list) or len(rows) > 10_000:
        raise ValueError('owner export exceeds 10000 aggregate records')
    roots, timings, usages = {}, [], Counter()
    seen = set()
    ignored = duplicates = 0
    cutoff = (now - timedelta(days=RETENTION['aggregateDays'])).timestamp() * 1000
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get('counts', {}), dict):
            ignored += 1
            continue
        event = row.get('event')
        if event not in ('home.task.history-summary', 'home.response-timing', 'capability.usage'):
            continue
        try:
            observed = datetime.fromisoformat(row['timestamp'].replace('Z', '+00:00'))
            if not now - timedelta(days=RETENTION['aggregateDays']) <= observed <= now:
                ignored += 1
                continue
        except (KeyError, ValueError, TypeError):
            ignored += 1
            continue
        counts = row.get('counts', {})
        def number(key):
            value = counts.get(key)
            return type(value) is int and 0 <= value <= 9_007_199_254_740_991
        # Only approved projections enter a dedup key. Source log timestamps
        # have finite resolution: an identical same-instant row may be a copy
        # OR a collision. Count conservatively and disclose that lower bound.
        projection = {key: row.get(key) for key in ('event', 'timestamp', 'runtimeEpoch', 'step', 'stage', 'outcome', 'taskHash')}
        projection['counts'] = {key: counts[key] for key in ('calls', 'complete', 'firstVisibleMs', 'terminalMs', 'queueMs', 'modelMs', 'toolMs', 'lineages', 'operations', 'resumes', 'rootCreatedAtMs') if key in counts}
        identity = hashlib.sha256(json.dumps(projection, sort_keys=True).encode()).hexdigest()
        if identity in seen:
            duplicates += 1
            continue
        seen.add(identity)
        if event == 'home.task.history-summary':
            key = row.get('taskHash', '')
            if not re.fullmatch('[0-9a-f]{16}', key) or not all(number(k) for k in ('operations', 'resumes', 'rootCreatedAtMs')) or counts.get('complete') not in (0, 1) or counts['resumes'] != max(0, counts['operations'] - 1) or not cutoff <= counts['rootCreatedAtMs'] <= now.timestamp() * 1000:
                ignored += 1
                continue
            previous = roots.get(key)
            if previous and (previous[1]['rootCreatedAtMs'] != counts['rootCreatedAtMs'] or (previous[0] == observed and previous[1] != counts)):
                raise ValueError('contradictory source lineage summaries')
            if not previous or observed > previous[0]:
                roots[key] = (observed, counts)
        elif event == 'home.response-timing':
            if counts.get('calls') != 1 or counts.get('complete') not in (0, 1) or not all(number(k) for k in ('terminalMs', 'modelMs', 'toolMs')) or any(not number(k) or counts[k] > counts['terminalMs'] for k in ('firstVisibleMs', 'queueMs') if k in counts):
                ignored += 1
                continue
            timings.append(counts)
        elif event == 'capability.usage':
            name, status, bucket = row.get('step', ''), row.get('outcome'), row.get('stage')
            if re.fullmatch('[A-Za-z][A-Za-z0-9_]{0,127}', name) and status in ('ok', 'error', 'refused', 'unknown') and bucket in ('lt100ms', 'lt1s', 'lt10s', 'gte10s', 'unknown'):
                count = counts.get('calls')
                if type(count) is int and 0 < count <= 1_000_000:
                    usages[(name, status, bucket)] += count
                else:
                    ignored += 1
            else:
                ignored += 1
    complete = [r for _, r in roots.values() if r.get('complete') == 1]
    samples = [r['resumes'] for r in complete]
    resumes = field('partial' if roots else 'unavailable', sum(samples) if samples else None, len(samples),
                    ['sampled owner-exported lineages, not a complete task census']
                    + (['incomplete root histories excluded'] if len(complete) != len(roots) else []),
                    resumes=distribution(samples), observedLineages=len(roots),
                    mean=sum(samples) / len(samples) if samples else None)
    def values(key):
        return [r[key] for r in timings if type(r.get(key)) in (int, float) and math.isfinite(r[key]) and r[key] >= 0]
    supplemental = {'coverage': 'partial: bounded source-owner export; no live-store scan or complete-window claim',
                    'ignoredRecords': ignored, 'duplicateOrAmbiguousRows': duplicates,
                    'countsAreLowerBounds': bool(duplicates),
                    'homeResponseTiming': {key: distribution(values(key)) for key in ('firstVisibleMs', 'terminalMs', 'queueMs', 'modelMs', 'toolMs')},
                    'homeTimingComplete': sum(r.get('complete') == 1 for r in timings),
                    'capabilityUsage': [{'name': name, 'status': status, 'latencyBucket': bucket, 'count': count}
                                        for (name, status, bucket), count in sorted(usages.items())]}
    return resumes, supplemental


def save(directory: Path, record: dict) -> Path:
    if directory.is_symlink() or directory.parent.is_symlink():
        raise ValueError('health output directory must not be symlinked')
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"aggregate-{record['runId']}.json"
    temporary = path.with_suffix('.tmp')
    try:
        temporary.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    return path


def cleanup(directory: Path, now: datetime) -> int:
    removed = 0
    # No recursive traversal, source-file deletion, symlink following or generic
    # mtime sweep. Only this owner's schema + filename + recorded expiry qualify.
    if directory.is_symlink() or directory.parent.is_symlink():
        raise ValueError('health output directory must not be symlinked')
    for path in directory.glob('aggregate-*.json'):
        try:
            record = read(path)
            if record.get('schema') == SCHEMA and path.name == f"aggregate-{record['runId']}.json" and datetime.fromisoformat(record['expiresAt']) < now:
                path.unlink()
                removed += 1
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return removed


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog='scripts/tron health', description=__doc__)
    parser.add_argument('--sha', default='origin/main', help='pinned main commit (default: local origin/main; no fetch)')
    parser.add_argument('--verify-report', type=Path, action='append', default=[], help='retained exact-SHA verifier report; repeat for attempts')
    parser.add_argument('--mac-identity', type=Path, help='selected payload manifest identified by scripts/tron mac verify')
    parser.add_argument('--iphone-identity', type=Path, help='existing iPhone GatewayLogCaptureMetadata export')
    parser.add_argument('--owner-summary', type=Path, help='explicit aggregate records exported by source owners through system.logs')
    parser.add_argument('--cleanup', action='store_true', help='remove only expired health aggregates before reporting')
    args = parser.parse_args(argv)
    now = datetime.now(timezone.utc)
    directory = ROOT / 'test-results/health'
    record = {'schema': SCHEMA, 'runId': str(time.time_ns()), 'createdAt': now.isoformat(),
              'expiresAt': (now + timedelta(days=RETENTION['aggregateDays'])).isoformat(),
              'retention': RETENTION, 'status': 'running', 'coverage': {'reports': 0, 'unreadable': 0}}
    try:
        main_sha = git('rev-parse', '--verify', f'{args.sha}^{{commit}}')
        main_ref = 'origin/main' if git('for-each-ref', 'refs/remotes/origin/main') else 'main'
        if main_sha not in git('rev-list', '--first-parent', main_ref).splitlines():
            raise ValueError('requested SHA is not on pinned main first-parent history')
        record['sourceSha'] = main_sha
        if args.cleanup:
            record['expiredAggregatesRemoved'] = cleanup(directory, now)
        sources = args.verify_report or [ROOT / 'test-results/verify' / f'{main_sha}.json']
        reports = []
        for path in sources[:1000]:
            try:
                reports.append(read(path))
            except (OSError, ValueError):
                record['coverage']['unreadable'] += 1
        record['coverage']['reports'] = len(reports)
        record['coverage']['exactShaReports'] = sum(r.get('commit') == main_sha for r in reports)
        record['coverage']['sourceLimitExceeded'] = len(sources) > 1000
        mac = read(args.mac_identity) if args.mac_identity else None
        iphone = read(args.iphone_identity) if args.iphone_identity else None
        record['fields'] = score(main_sha, reports, mac, iphone)
        if args.owner_summary:
            resumes, supplemental = owner_summary(read(args.owner_summary), now)
            record['fields']['resumesPerTask'] = resumes
            record['supplemental'] = supplemental
        record['goals'] = goal_metrics(record['fields']['resumesPerTask'])
        record['landedChanges'] = landed_changes(main_sha, reports)
        record['context'] = {'productionLOC': field('unavailable', reasons=['no exact-SHA metrics snapshot retained; context, not a target']),
                             'conceptCount': field('unavailable', reasons=['no canonical concept-count source; context, not a target'])}
        metrics = ROOT / 'test-results/metrics' / f'{main_sha}.json'
        if metrics.exists():
            snapshot = read(metrics)
            lines = snapshot.get('metrics', {}).get('M3.size', {}).get('byCategory', {}).get('production', {}).get('lines')
            if snapshot.get('schema') == 'tron-metrics/1' and snapshot.get('commit') == main_sha and type(lines) is int and lines >= 0:
                record['context']['productionLOC'] = {'value': lines, 'sourceSha': main_sha, 'role': 'context, not a target'}
        # Presentation order puts goal outcomes ahead of the old diagnostic fields.
        fields = record.pop('fields')
        record['fields'] = fields
        record['status'] = 'complete'
    except KeyboardInterrupt:
        record['status'] = 'interrupted'
        record['reason'] = 'partial collection retained; not a pass'
    except (OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.CalledProcessError):
        record['status'] = 'unavailable'
        record['reason'] = 'source unavailable, malformed, or not pinned main; no private diagnostic copied'
    try:
        save(directory, record)
    except (OSError, ValueError):
        record['status'] = 'unavailable'
        record['reason'] = 'health output publication refused'
    print(json.dumps(record, indent=2))
    return 130 if record['status'] == 'interrupted' else 1 if record['status'] == 'unavailable' else 0


if __name__ == '__main__':
    import signal

    def interrupted(_signal, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main(sys.argv[1:]))
