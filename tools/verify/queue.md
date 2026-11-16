# Shadow landing queue

`tools/verify/landing_queue.py` runs the full suite of Tiers 0 to 2, as they exist today, on every landing on `main`, serially, on the
Mac mini, and appends each verdict and its seconds to a ledger. It gates nothing: no hook, ruleset or write to `main`
depends on it.

## What it runs

For each first-parent commit of `main` after the ledger's last landing, oldest first, it checks the commit out in its own
clone, installs the Gateway and relay dependencies when their inputs changed, and runs

```bash
python3 tools/verify/verify.py --full --base <first parent> --gateway-host local --skip ios,python-here,mac-terminal
```

`--full` selects every test file in every runner group and runs every group even after a red, so one red never hides
another tier. The static steps check the landing's own diff. The report's steps map to tiers: every step that is not a
test step is Tier 0; `gateway`, `python`, `node` and `relay` are Tier 1; `gateway-nested`, `node-gateway`, `shell` and
`mac` are Tier 2. The skipped groups are not covered: the iOS groups are Tier 3, and `python-here` and `mac-terminal`
need this Mac's session store and SSH service.

## Where

| Path on the mini | Holds |
|---|---|
| `~/tron-ci/queue/landing_queue.py` | The runner copy the LaunchAgent starts |
| `~/tron-ci/queue/tron/` | Its clone of the public repository over anonymous HTTPS; no credential |
| `~/tron-ci/queue/tron/test-results/queue/ledger.jsonl` | The append-only ledger |
| `~/tron-ci/queue/tron/test-results/queue/<landing>/` | `verify.log`, `verify.json` and the step logs of that landing |
| `~/tron-ci/queue/queue.log` | The runner's own start and verdict lines |
| `~/Library/LaunchAgents/com.tron.shadow-queue.plist` | Starts `landing_queue.py run` at load and every 300 s |

A run holds the mini job lock (`~/tron-ci/jobs/gateway.lock`) for all the landings it takes, so a `mini.py` job never
runs beside it; a run that finds the lock held exits and the next interval retries. A run stopped before a landing's
entry is written records nothing, and the next run repeats that landing.

## Ledger

One JSON object per line, never rewritten.

- `run`: `landing`, `parents`, `subject`, `landedAt`, `tested`, `host`, `startedAt`, `endedAt`, `seconds`,
  `verdict` (`passed`, `failed` or `no result`), `reason`, `tiers` (`"0"`, `"1"`, `"2"`: `verdict`, `seconds`,
  `failedSteps`, `skippedSteps`) and `failedTests` (`lane: test` from the mini's per-test ledger for that commit and run).
- `claim`: the landing's own `verify --changed` report, found in this Mac's checkouts for a commit of the landed branch
  (`landing^1..landing^2`, newest first): `commit`, `verdict`, `message`, `failedSteps`, `report`.

```bash
scripts/tron queue ledger --mini   # this Mac: record new claims on the mini's ledger, then print it
scripts/tron queue ledger          # on the mini: print its ledger
```

The print lists each landing with its verdict, tier verdicts and seconds and its claim, the red steps and failed tests
under each red, reds per day by landing date, and p50 and p95 seconds of the whole run and of each tier.

## Install and undo

Install once on the mini, from a clone at the commit to run:

```bash
git clone https://github.com/<owner>/tron.git ~/tron-ci/queue/tron   # origin's repository, anonymous HTTPS
cd ~/tron-ci/queue/tron && git checkout --detach <commit> && /usr/bin/python3 tools/verify/landing_queue.py install
/usr/bin/python3 ~/tron-ci/queue/landing_queue.py run --since <landing>   # optional: start after an older landing
```

`install` copies the runner, writes the LaunchAgent and loads it in the user's GUI domain; run it again from a newer
commit to update the runner. The agent starts when the mini's user session starts. Undo:

```bash
/usr/bin/python3 ~/tron-ci/queue/landing_queue.py uninstall   # unload and remove the LaunchAgent; the ledger stays
rm -rf ~/tron-ci/queue                                # also remove the clone, the ledger and the logs
```
