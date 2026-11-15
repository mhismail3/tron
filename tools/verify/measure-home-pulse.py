"""Measure the original three-test Home shard ten times under one canonical mini job."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
OWNED = ROOT / 'scripts/tron-ios-test'
SELECTORS = [f'TronMobileUITests/TronSmokeUITests/{name}' for name in (
    'testHomePermissionRevokeRequiresConfirmation',
    'testHomeSheetLoadingSurfaceRemainsFullWidth',
    'testHomeTaskPermissionsRevokeAndReconfirm',
)]


def main():
    if os.environ.get('TRON_VERIFY_EXECUTION_HOST') != 'mini':
        raise SystemExit('This measurement runs only inside the canonical mini lease')
    results = Path(os.environ['TRON_IOS_TEST_RESULTS_DIR'])
    results.mkdir(parents=True, exist_ok=True)
    ledger = results / 'home-pulse-measurement.json'
    receipt = {'plannedRepetitions': 10, 'selectors': SELECTORS, 'runs': [], 'complete': False}
    active = None
    interrupted = None
    forwarded = False

    def save():
        ledger.write_text(json.dumps(receipt, indent=2) + '\n')

    def forward():
        nonlocal forwarded
        if interrupted and active is not None and not forwarded and active.poll() is None:
            forwarded = True
            try:
                active.send_signal(interrupted)
            except ProcessLookupError:
                pass

    def stop(signum, frame):
        nonlocal interrupted
        if interrupted is None:
            interrupted = signum
            forward()

    def run_owned(arguments):
        nonlocal active, forwarded
        if interrupted:
            return 128 + interrupted
        forwarded = False
        active = subprocess.Popen([str(OWNED), *arguments], cwd=ROOT, start_new_session=True)
        forward()
        try:
            return active.wait()
        finally:
            active = None

    def finish(code):
        if interrupted:
            receipt['interrupted'] = interrupted
        save()
        return 128 + interrupted if interrupted else code

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, stop)
    save()
    built = run_owned(['build'])
    receipt['buildExit'] = built
    save()
    if built or interrupted:
        return finish(built)
    arguments = [word for selector in SELECTORS for word in ('--only-testing', selector)]
    for iteration in range(1, 11):
        before = set(results.iterdir())
        print(f'MEASUREMENT repetition {iteration}/10: original three-test shard', flush=True)
        run = {'iteration': iteration, 'startedAt': time.time(), 'complete': False}
        receipt['runs'].append(run)
        save()
        code = run_owned(['run', *arguments])
        run.update({'exit': code, 'seconds': time.time() - run['startedAt']})
        summaries = [path / 'summary.json' for path in set(results.iterdir()) - before if path.is_dir() and (path / 'summary.json').is_file()]
        if len(summaries) == 1:
            run['summaryPath'] = str(summaries[0].relative_to(results))
            try:
                run['summary'] = json.loads(summaries[0].read_text())
            except (OSError, ValueError) as error:
                run['summaryError'] = str(error)
        summary = run.get('summary', {})
        run['complete'] = (
            not interrupted and code in (0, 65) and len(summaries) == 1
            and summary.get('totalTestCount') == 3
            and summary.get('passedTests', 0) + summary.get('failedTests', 0) == 3
            and summary.get('skippedTests') == 0 and summary.get('expectedFailures') == 0
            and (code == 0) == (summary.get('failedTests') == 0)
        )
        save()
        if not run['complete']:
            print('MEASUREMENT incomplete: owning runner did not produce one complete three-test shard', flush=True)
            return finish(code if code not in (0, 65) else 74)
    receipt['complete'] = True
    return finish(65 if any(run['exit'] for run in receipt['runs']) else 0)


if __name__ == '__main__':
    sys.exit(main())
