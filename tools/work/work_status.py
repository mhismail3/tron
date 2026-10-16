"""Home's requested work view, composed from the existing claim, queue and report owners."""
from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import claim
import gate
import heavy
import landqueue
import report


def run(root: Path, config: dict, requested_areas: list, as_json: bool) -> int:
    areas = claim.normalized_areas(requested_areas)
    now = datetime.now(timezone.utc)
    # A daily digest means the previous complete UTC day, not a moving 24h window.
    end = now.replace(hour=0, minute=0, second=0, microsecond=0)
    start = end - timedelta(days=1)
    end -= timedelta(microseconds=1)  # report.build has an inclusive end; midnight belongs to the next day.
    rules = config["claim"]
    view = {"sampledAt": now.isoformat(), "window": [start.isoformat(), end.isoformat()]}
    readers = (
        ("land", lambda: landqueue.counts(root)),
        ("heavy", heavy.counts),
        ("digest", lambda: report.digest(report.build(root, gate.load_catalog()["steps"], start, end, [],
                                                     heavy_events=heavy._directory() / "events.jsonl"))),
        ("advice", lambda: claim.area_advice(areas, claim.all_claims(root, rules["remote"], rules["baseBranch"]),
                                           claim._git(root, "branch", "--show-current").stdout.strip())),
    )
    for name, read in readers:
        try:
            view[name] = read()
        except Exception as error:
            # A broken history must not hide live queue facts. Null is unavailable,
            # never zero; do not echo remote credentials or damaged ledger contents.
            view[name] = None
            view[name + "Error"] = type(error).__name__
    if as_json:
        print(json.dumps(view, indent=2))
    else:
        print(f"work status {view['sampledAt']} (snapshot, not a reservation)")
        for name, scope in (("land", "this repository"), ("heavy", "this user/host")):
            counts = view[name]
            text = (f"{counts['running'] if counts['running'] is not None else 'unknown'} running / "
                    f"{counts['waiting'] if counts['waiting'] is not None else 'unknown'} waiting") if counts is not None else f"unavailable ({view[name + 'Error']})"
            print(f"  {name} ({scope}): {text}")
        print("  daily " + (view["digest"] if view["digest"] is not None else f"unavailable ({view['digestError']})"))
        print(claim.render_advice(view["advice"]) if view["advice"] is not None else f"  overlap advice unavailable ({view['adviceError']})")
    return 0
