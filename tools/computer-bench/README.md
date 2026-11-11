# Computer-use scorecard (`scripts/tron computer-bench`)

The repeatable measure behind #2476: can every Tron surface use computer and browser
tools quickly, accurately and across the functions it needs? It runs a fixed local task
set per tool and reports success rate, wall time per task, and a function-coverage matrix
per tool and per surface. Every change to computer or browser use cites a scorecard delta.

```bash
scripts/tron computer-bench                       # all tools, 3 reps, scorecard on stdout
scripts/tron computer-bench --tools cua --reps 1 --only native-click,replace
scripts/tron computer-bench --foreground --json .scratch/run.json --markdown tools/computer-bench/SCORECARD.md
node --test tools/computer-bench/bench.test.mjs   # fixture site and scoring
```

[`SCORECARD.md`](SCORECARD.md) is the current generated scorecard; regenerate it, never edit it.

## Tools

| Adapter | What it drives | How |
|---|---|---|
| `agent-browser` | The engine behind Tron's `agent_browser` tool | `~/.tron/agent/bin/agent-browser --json --session cb2476-<pid>`; its own managed Chrome for Testing |
| `cua` | The embedded Cua driver behind Tron's `computer` tool | `cua-driver call` on the Native Host socket (`$(getconf DARWIN_USER_TEMP_DIR)/tron-cua-*/s`), using only operations `computer` admits (`packages/gateway/src/machine/cua-client.ts`), element tokens from a fresh observation, and Tron's 200-element/16-depth observation cap |
| `browser-use` | browser-use 1.0 / browser-harness, only if a venv already exists | `<venv>/bin/browser-use` with Python on stdin, its own headless Chrome for Testing on a free port; `BH_HOME` in the run directory; telemetry, update checks and domain skills off. Default venv `~/Workspace/browser-use-eval-20261110/.venv` (`COMPUTER_BENCH_BROWSER_USE_VENV`) |

Adapters measure the engines directly. The live per-call overhead of the Tron tool
wrappers is small next to these times but is not part of a run. An adapter that is missing
is reported as `absent`, never skipped.

## Tasks

Everything is local and deterministic. Nothing signs in anywhere, touches the maintainer's
browser profile, changes Chrome settings or system permissions, or spends money.

- **Fixture site** (`fixtures/site.mjs`, `127.0.0.1:<random>`): form fields, a prefilled field,
  a counter button, select and checkbox, file input, download link, `target=_blank` link,
  `confirm()` dialog, a cookie login and `/whoami`, and a consent page that redirects to a
  second origin (`localhost`) with a code.
- **Scratch window** (`fixtures/scratch-window.swift`, compiled per run): an accessory AppKit
  window that never activates itself, with text fields, a pop-up menu, a counter button and an
  in-app consent sheet. It writes its control state to a JSON file, the oracle.
- **Chromium window for Cua**: Chrome for Testing launched with `open -g`, its own temporary
  profile and a loopback debugging port that only the oracle reads.

Each task acts through the tool and checks the effect with an independent oracle (page
value over CDP, the scratch window's state file, a PNG header, a file on disk). A tool's
own claim (`confirmed`, `unverifiable`) is recorded but is not the result. Tasks run
serially; each rep starts from a fresh page or window.

`signed-in-chrome` only checks whether the maintainer's Chrome exposes a CDP endpoint
(`DevToolsActivePort`); it never attaches. `background-delivery` fails when any background
Cua action changed the frontmost app. `foreground-delivery` runs only with `--foreground`
and after 120 s without user input, so it never takes the shared Mac from a user;
otherwise it reports `idle`. `permission-prompt` and `locked-refusal` are listed as not
measured: a real TCC prompt changes system permissions and refusal needs a locked Mac.

## Surfaces

[`surfaces.json`](surfaces.json) records, with code citations, whether each tool is a
first-class tool (`first-class`), reachable only through bash (`shell`) or absent (`none`)
on Home maintainer turns, Home wake turns, delegated workers and ordinary/automation
sessions, and pi-subagents children. Home admits `computer` only on maintainer turns;
trigger, automation and task-result wakes admit neither computer nor browser. A tool
scores on a surface only where it is first-class: an availability gap is a failure.
Update the file in the same change that moves a tool onto or off a surface.

Surface rows project the measured engine functions through declared tool admission;
they are not live Home or subagent interaction timings. The Home admission E2E owns
the maintainer/wake boundary. Delegation startup and end-to-end Home task latency are
not measured by this harness. Browser-tool admission would add the worker's browser-only
functions to Home, but remains a maintainer decision rather than a benchmark change.
