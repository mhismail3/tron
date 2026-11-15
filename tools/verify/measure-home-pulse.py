"""Measure the original three-test Home shard ten times under one canonical mini job."""
import json
import os
from pathlib import Path
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
    ledger.write_text(json.dumps(receipt, indent=2) + '\n')
    built = subprocess.run([str(OWNED), 'build'], cwd=ROOT).returncode
    receipt['buildExit'] = built
    ledger.write_text(json.dumps(receipt, indent=2) + '\n')
    if built:
        return built
    arguments = [word for selector in SELECTORS for word in ('--only-testing', selector)]
    for iteration in range(1, 11):
        before = set(results.iterdir())
        print(f'MEASUREMENT repetition {iteration}/10: original three-test shard', flush=True)
        started = time.time()
        code = subprocess.run([str(OWNED), 'run', *arguments], cwd=ROOT).returncode
        summaries = [path / 'summary.json' for path in set(results.iterdir()) - before if path.is_dir() and (path / 'summary.json').is_file()]
        run = {'iteration': iteration, 'exit': code, 'seconds': time.time() - started}
        if len(summaries) == 1:
            run['summaryPath'] = str(summaries[0].relative_to(results))
            run['summary'] = json.loads(summaries[0].read_text())
        receipt['runs'].append(run)
        ledger.write_text(json.dumps(receipt, indent=2) + '\n')
        if code not in (0, 65) or len(summaries) != 1 or run['summary'].get('totalTestCount') != 3:
            print('MEASUREMENT incomplete: owning runner did not produce one complete three-test shard', flush=True)
            return code if code not in (0, 65) else 74
    receipt['complete'] = True
    ledger.write_text(json.dumps(receipt, indent=2) + '\n')
    return 65 if any(run['exit'] for run in receipt['runs']) else 0


if __name__ == '__main__':
    sys.exit(main())
