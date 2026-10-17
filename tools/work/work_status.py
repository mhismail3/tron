"""On-demand advisory claim overlap view; never reserves or admits work."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

import claim


def run(root: Path, config: dict, requested_areas: list, as_json: bool) -> int:
    areas = claim.normalized_areas(requested_areas)
    rules = config["claim"]
    view = {"sampledAt": datetime.now(timezone.utc).isoformat()}
    try:
        view["advice"] = claim.area_advice(
            areas, claim.all_claims(root, rules["remote"], rules["baseBranch"]),
            claim._git(root, "branch", "--show-current").stdout.strip())
    except Exception as error:
        view["advice"] = None
        view["adviceError"] = type(error).__name__
    if as_json:
        print(json.dumps(view, indent=2))
    else:
        print(f"work status {view['sampledAt']} (advice, not a reservation)")
        print(claim.render_advice(view["advice"]) if view["advice"] is not None
              else f"overlap advice unavailable ({view['adviceError']})")
    return 0
