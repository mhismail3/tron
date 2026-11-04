"""Read-only timing observations of one finished batch lane. Never a verdict input.

Sources are the lane's own evidence: the verifier's per-step seconds, each Vitest JSON report's
per-file wall time, every `-showBuildTimingSummary` block in the lane's logs, the owners'
per-journey/per-case wall-time lines, and each XCTest result bundle the log names, read with
`xcrun xcresulttool get test-results tests|activities`. Each source fails alone into `errors`.
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess

BUILD_BUCKET = re.compile(r'^(\S[^|\n]*?) \((\d+) tasks?\) \| ([\d.]+) seconds$')
JOURNEY = re.compile(r'^(Real-UI journey|Focused E2E case) (\S+) completed in (\d+)s \(status (\d+)\)', re.M)
RESULT_BUNDLE = re.compile(r'(?:-resultBundlePath |^\s+)(/\S+\.xcresult)\s*$', re.M)
IOS_RUN = re.compile(r'^iOS test run (?:complete|failed with status \d+): (/\S+)$', re.M)
XCRESULT_SECONDS = 120
# Bounds keep report.json reviewable: slowest activities per case, normalized-title groups.
SLOWEST_ACTIVITIES = 15


def build_summaries(text: str) -> list[list[dict]]:
    """Each Build Timing Summary block's buckets in printed order."""
    summaries, current = [], None
    for line in text.splitlines():
        if line.strip() == 'Build Timing Summary':
            current = []
            summaries.append(current)
            continue
        if current is None:
            continue
        match = BUILD_BUCKET.match(line.strip())
        if match:
            current.append({'bucket': match[1], 'tasks': int(match[2]), 'seconds': float(match[3])})
        elif line.strip() and current:
            current = None
    return [summary for summary in summaries if summary]


def vitest_files(report: Path, root: Path) -> list[dict]:
    """Per-file wall seconds and case count from one Vitest JSON report, slowest first."""
    data = json.loads(report.read_text())
    files = []
    for suite in data.get('testResults', []):
        name = Path(suite['name'])
        if name.is_relative_to(root):
            name = name.relative_to(root)
        files.append({'file': name.as_posix(), 'seconds': round((suite['endTime'] - suite['startTime']) / 1000, 3),
                      'cases': len(suite.get('assertionResults', [])), 'status': suite.get('status')})
    return sorted(files, key=lambda item: -item['seconds'])


def xcresult(*args: str) -> dict:
    done = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', *args], capture_output=True,
                          text=True, timeout=XCRESULT_SECONDS)
    if done.returncode:
        raise ValueError(f'xcresulttool exit {done.returncode}: {done.stderr.strip()[-300:]}')
    return json.loads(done.stdout)


def test_cases(nodes: list[dict]):
    for node in nodes:
        if node.get('nodeType') == 'Test Case':
            yield node
        else:
            yield from test_cases(node.get('children', []))


def normalized(title: str) -> str:
    return re.sub(r'\d+(?:\.\d+)?', 'N', re.sub(r'"[^"]*"|`[^`]*`|\'[^\']*\'', '…', title))


def activities(bundle: Path, identifier: str) -> dict:
    """Top-level activity seconds, each from its start to the next sibling's (the last has no end, so it is omitted)."""
    data = xcresult('activities', '--test-id', identifier, '--path', str(bundle))
    runs = []
    for run in data.get('testRuns', []):
        top = [item for item in run.get('activities', []) if 'startTime' in item]
        if not top:
            continue
        timed = [{'title': item['title'], 'seconds': round(after['startTime'] - item['startTime'], 3)}
                 for item, after in zip(top, top[1:])]
        groups, idle = {}, 0

        def visit(items):
            nonlocal idle
            for item in items:
                idle += bool(re.search(r'\bto idle\b', item.get('title', '')))
                visit(item.get('childActivities', []))
        visit(top)
        for item in timed:
            group = groups.setdefault(normalized(item['title']), {'count': 0, 'seconds': 0.0})
            group['count'] += 1
            group['seconds'] = round(group['seconds'] + item['seconds'], 3)
        runs.append({'activities': len(top), 'idleWaits': idle,
                     'slowest': sorted(timed, key=lambda item: -item['seconds'])[:SLOWEST_ACTIVITIES],
                     'byKind': dict(sorted(groups.items(), key=lambda pair: -pair[1]['seconds'])[:SLOWEST_ACTIVITIES])})
    return {'runs': runs}


def bundle_timing(bundle: Path, errors: list[str]) -> dict:
    cases = []
    for node in test_cases(xcresult('tests', '--path', str(bundle)).get('testNodes', [])):
        case = {'test': node.get('nodeIdentifier'), 'result': node.get('result'), 'seconds': node.get('durationInSeconds')}
        try:
            case.update(activities(bundle, node['nodeIdentifier']))
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            errors.append(f"activities {bundle} {node.get('nodeIdentifier')}: {error}")
        cases.append(case)
    return {'bundle': str(bundle), 'cases': cases}


def bundles(text: str) -> list[Path]:
    found = [Path(path) for path in RESULT_BUNDLE.findall(text)]
    found += [Path(directory) / 'TestResults.xcresult' for directory in IOS_RUN.findall(text)]
    return [path for path in dict.fromkeys(found) if path.is_dir()]


def lane_timing(result: dict, directory: Path, root: Path) -> dict:
    """Observations for one executed lane; every failure is recorded, never raised."""
    timing, errors = {'seconds': result.get('seconds')}, []
    logs = [Path(result['log'])] if result.get('log') else []
    logs += sorted((directory / 'steps').glob('*.log'))
    texts = {}
    for log in logs:
        try:
            texts[log] = log.read_text(errors='replace')
        except OSError as error:
            errors.append(f'{log.name}: {error}')
    try:
        report = directory / 'verify.json'
        if report.is_file():
            timing['verifierSteps'] = [{'name': step['name'], 'seconds': step.get('seconds'), 'status': step.get('status')}
                                       for step in json.loads(report.read_text()).get('steps', [])]
    except (OSError, ValueError, KeyError, TypeError) as error:
        errors.append(f'verify.json: {error}')
    vitest = {}
    for report in [directory / 'vitest.json', *sorted((directory / 'steps').glob('*vitest.json'))]:
        if report.is_file():
            try:
                vitest[report.name if report.parent == directory else f'steps/{report.name}'] = vitest_files(report, root)
            except (OSError, ValueError, KeyError, TypeError) as error:
                errors.append(f'{report.name}: {error}')
    if vitest:
        timing['vitestFiles'] = vitest
    builds = [{'log': log.name, 'buckets': summary} for log, text in texts.items() for summary in build_summaries(text)]
    if builds:
        timing['buildTiming'] = builds
    journeys = [{'kind': kind, 'test': test, 'seconds': int(seconds), 'status': int(status)}
                for text in texts.values() for kind, test, seconds, status in JOURNEY.findall(text)]
    if journeys:
        timing['journeys'] = journeys
    results = []
    for bundle in dict.fromkeys(path for text in texts.values() for path in bundles(text)):
        try:
            results.append(bundle_timing(bundle, errors))
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            errors.append(f'tests {bundle}: {error}')
    if results:
        timing['xcresults'] = results
    if errors:
        timing['errors'] = errors
    return timing
