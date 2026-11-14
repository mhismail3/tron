#!/usr/bin/env python3
"""Repeat unchanged-main suites through verify's process owner and the mini lease."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import math
import os
import signal
import sys
import time

import ledger
import mini
import verify as v

GROUPS = ('gateway', 'gateway-nested', 'python', 'node', 'node-gateway')


class SourceChanged(v.VerifyError):
    pass


def origin_main() -> str:
    return v.git('ls-remote', '--exit-code', 'origin', 'refs/heads/main').split()[0]


def fence(sha: str) -> None:
    if v.git('status', '--porcelain', '--untracked-files=normal'):
        raise SourceChanged('hunt requires a clean committed checkout')
    if v.git('rev-parse', 'HEAD').strip() != sha or origin_main() != sha:
        raise SourceChanged('hunt requires unchanged HEAD equal to current origin/main')


def main(arguments: list[str]) -> int:
    started = time.monotonic()
    parser = argparse.ArgumentParser(prog='scripts/tron verify --hunt')
    parser.add_argument('--rounds', type=int, default=20)
    parser.add_argument('--hours', type=float, default=8)
    parser.add_argument('--plan', action='store_true')
    args = parser.parse_args(arguments)
    if args.rounds < 1 or not math.isfinite(args.hours) or args.hours <= 0:
        parser.error('rounds and finite hours must be positive')
    try:
        sha, tree = v.git('rev-parse', 'HEAD').strip(), v.git('rev-parse', 'HEAD^{tree}').strip()
        registry, errors = v.ownership.check()
        if errors:
            raise v.VerifyError('; '.join(errors))
        nested, terminal = v.nested_files()
        groups = {name: [] for name in GROUPS}
        for path in registry['tracked']:
            if v.is_test(path):
                group = v.runner_of(path, nested, terminal)
                if group in groups:
                    groups[group].append(path)
        groups = {name: sorted(files) for name, files in groups.items() if files}
        if not groups:
            raise v.VerifyError('no mini-compatible tests selected')
        plan = {'commit': sha, 'tree': tree, 'matchesMain': origin_main() == sha and not v.git('status', '--porcelain'),
                'rounds': args.rounds, 'hours': args.hours, 'host': 'mini', 'groups': groups,
                'contended': os.environ.get('TRON_TEST_CONTENDED') == '1'}
        if args.plan:
            print(json.dumps(plan, indent=2))
            return 0
        fence(sha)
    except (v.VerifyError, v.ownership.GitError) as error:
        print(f'hunt: {error}', file=sys.stderr)
        return 2
    logs = v.ROOT / 'test-results/hunt' / f'{sha[:12]}-{time.time_ns()}'
    run = v.Run(sha, args.rounds * len(groups), logs=logs)
    report = {**plan, 'startedAt': datetime.now(timezone.utc).isoformat(), 'completion': 'running',
              'completedRounds': 0, 'firstFailure': None, 'steps': run.steps, 'flakes': []}
    path = logs / 'summary.json'

    def save():
        report['seconds'] = round(time.monotonic() - started, 3)
        temporary = path.with_suffix('.tmp')
        temporary.write_text(json.dumps(report, indent=2) + '\n')
        temporary.replace(path)

    def interrupt(signum, frame):
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, signal.SIG_IGN)
        raise KeyboardInterrupt

    def repeat() -> int:
        code = 0
        for round_index in range(args.rounds):
            folder = logs / f'round-{round_index + 1}'
            folder.mkdir()
            for group, files in groups.items():
                fence(sha)
                if time.monotonic() - started >= args.hours * 3600:
                    report['completion'] = 'budget'
                    return code or 75
                command, cwd, count = v.test_spec(group, files, [], folder, gateway_host='mini', node_host='mini')
                step = run.step(f'round {round_index + 1}: {group}', command, cwd, count,
                                env={'TRON_VERIFY_COMMIT': sha, 'TRON_MINI_JOB_WAIT_SECONDS': '0'})
                output = (v.ROOT / step['log']).read_text(errors='replace')
                missing = mini.no_result_reason(step['exit'], output)
                if missing:
                    report['completion'], report['reason'] = 'no-result', missing
                    return code or 75
                if step['exit'] in (130, 143):
                    report['completion'] = 'interrupted'
                    return step['exit']
                if step['exit'] == 0 and not step['tests']:
                    report['completion'], report['reason'] = 'undriven', 'lane returned no passing cases'
                    return code or 75
                if step['exit']:
                    code = 1
                    if report['firstFailure'] is None:
                        report['firstFailure'] = step['log']
            report['completedRounds'] += 1
        fence(sha)
        report['completion'] = 'completed'
        return code

    previous = {sig: signal.signal(sig, interrupt) for sig in (signal.SIGINT, signal.SIGTERM)}
    run.on_update = save
    code = 0
    try:
        save()
        code = repeat()
    except SourceChanged as error:
        report['completion'], report['reason'], code = 'source-changed', str(error), 1 if report['firstFailure'] else 75
    except (v.VerifyError, v.ownership.GitError) as error:
        report['completion'], report['reason'], code = 'no-result', str(error), 1 if report['firstFailure'] else 75
    except KeyboardInterrupt:
        report['completion'], code = 'interrupted', 130
    except Exception as error:
        report['completion'], report['reason'], code = 'error', str(error), 1
    finally:
        for sig in previous:
            signal.signal(sig, signal.SIG_IGN)
        try:
            try:
                run.stop(list(run.live))
            except Exception as error:
                report['cleanupError'] = str(error)
                if code == 0:
                    report['completion'], code = 'error', 1
            try:
                report['flakes'] = ledger.flakes(tree)
            except Exception as error:
                report['rankingError'] = str(error)
                if code == 0:
                    report['completion'], code = 'error', 1
            report['exit'] = code
            save()
            print(f'hunt: report: {path.relative_to(v.ROOT)}', flush=True)
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
    return code


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
