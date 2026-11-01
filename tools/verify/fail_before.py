"""Report-only comparison of retained verify case observations; never causal proof."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def revision(value):
    return subprocess.check_output(['git', 'rev-parse', '--verify', f'{value}^{{commit}}'], text=True).strip()


def observation(path, commit, identity):
    raw = Path(path).read_bytes()
    report = json.loads(raw)
    if report['schema'] != 'tron.verify.v1' or report['commit'] != commit:
        raise ValueError('wrong schema or commit')
    if report['verdict'] not in ('passed', 'failed') or not report['caseEvidenceComplete']:
        raise ValueError('incomplete or qualified evidence')
    steps = [s for s in report['steps'] if s['name'].startswith('tests:')]
    if not steps or any(not s.get('caseEvidenceComplete') for s in steps):
        raise ValueError('missing complete case evidence')
    cases = [case for step in steps for case in step['caseOutcomes']]
    if len({c['caseDigest'] for c in cases}) != len(cases):
        raise ValueError('duplicate case identity')
    selected = [c for c in cases if c['caseDigest'] == identity]
    if len(selected) != 1 or selected[0]['status'] not in ('passed', 'failed'):
        raise ValueError('empty selection is not evidence')
    case = selected[0]
    if case['status'] == 'failed' and not case.get('failureDigest'):
        raise ValueError('missing failure digest')
    if report['verdict'] == 'passed' and any(c['status'] != 'passed' for c in cases):
        raise ValueError('inconsistent passing report')
    return {'path': str(Path(path).resolve()), 'sha256': hashlib.sha256(raw).hexdigest(),
            'commit': commit, 'attemptId': report['attemptId'], 'verdict': report['verdict'], **case}


def main(argv):
    parser = argparse.ArgumentParser(prog='scripts/tron verify --fail-before')
    parser.add_argument('--fail-before', required=True, metavar='FILE::FULL_CASE_NAME')
    parser.add_argument('--base', required=True)
    parser.add_argument('--candidate', default='HEAD')
    parser.add_argument('--before-report', required=True)
    parser.add_argument('--after-report', required=True)
    args = parser.parse_args(argv)
    result = {'reportOnly': True, 'causalProof': False, 'selector': args.fail_before}
    try:
        file, name = args.fail_before.split('::', 1)
        if not file.startswith('packages/gateway/') or not name or '..' in Path(file).parts:
            raise ValueError('only exact repository-relative Gateway case identities are supported')
        identity = hashlib.sha256(args.fail_before.encode()).hexdigest()
        base, candidate = revision(args.base), revision(args.candidate)
        if base == candidate:
            raise ValueError('base and candidate must differ')
        before = observation(args.before_report, base, identity)
        after = observation(args.after_report, candidate, identity)
        result.update(before=before, after=after)
        if after['status'] != 'passed' or after['verdict'] != 'passed':
            result['verdict'] = 'candidate-not-green'
        elif before['status'] == 'passed':
            result['verdict'] = 'missing-fail-before'
        else:
            result['verdict'] = 'observed-fail-before-pass-after'
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        result.update(verdict='insufficient-evidence', reason=str(error))
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0  # Advisory only, including absent evidence; never a shipping gate.
