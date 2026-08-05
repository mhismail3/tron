#!/usr/bin/env python3
"""Offline acceptance evaluator for whole-agent evidence.

The harness deliberately does not add an evaluation API to the Tron engine.
An external runner can exercise an isolated profile, normalize its durable
evidence into the closed shape below, and evaluate it here without another
model call or network access.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SUITE = Path(__file__).with_name("whole-agent-suite.json")
ALLOWED_ASSERTIONS = {
    "artifact_created",
    "citation_minimum",
    "effective_model_equals",
    "event_kind_present",
    "event_order",
    "latency_maximum",
    "model_provenance_present",
    "no_safety_violation",
    "requested_model_equals",
    "status_equals",
    "worker_used",
}
ALLOWED_CATEGORIES = {
    "artifact",
    "automation",
    "delegation",
    "diagnostics",
    "research",
    "safety",
    "session",
}


def load_json(path: Path) -> object:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def validate_suite(value: object) -> dict:
    if not isinstance(value, dict) or set(value) != {"schemaVersion", "name", "scenarios"}:
        raise ValueError("suite must use the closed top-level contract")
    if value["schemaVersion"] != "tron.whole_agent_suite.v1":
        raise ValueError("unsupported suite schemaVersion")
    scenarios = value["scenarios"]
    if not isinstance(scenarios, list) or len(scenarios) < 20:
        raise ValueError("whole-agent suite requires at least 20 scenarios")
    identifiers: set[str] = set()
    for scenario in scenarios:
        if not isinstance(scenario, dict) or set(scenario) != {
            "id", "category", "prompt", "assertions"
        }:
            raise ValueError("scenario must use the closed contract")
        identifier = scenario["id"]
        if not isinstance(identifier, str) or not identifier or identifier in identifiers:
            raise ValueError("scenario ids must be non-empty and unique")
        identifiers.add(identifier)
        if scenario["category"] not in ALLOWED_CATEGORIES:
            raise ValueError(f"unsupported category for {identifier}")
        if not isinstance(scenario["prompt"], str) or not scenario["prompt"].strip():
            raise ValueError(f"scenario {identifier} requires a prompt")
        assertions = scenario["assertions"]
        if not isinstance(assertions, list) or not 1 <= len(assertions) <= 12:
            raise ValueError(f"scenario {identifier} requires 1 to 12 assertions")
        for assertion in assertions:
            if not isinstance(assertion, dict) or assertion.get("kind") not in ALLOWED_ASSERTIONS:
                raise ValueError(f"scenario {identifier} has an unsupported assertion")
            if set(assertion) - {"kind", "value"}:
                raise ValueError(f"scenario {identifier} assertion has unsupported fields")
    return value


def validate_evidence(value: object) -> dict:
    required = {
        "scenarioId",
        "status",
        "events",
        "workers",
        "citations",
        "artifactCreated",
        "latencyMs",
        "safetyViolation",
        "modelProvenance",
    }
    if not isinstance(value, dict) or set(value) != required:
        raise ValueError("evidence must use the closed contract")
    if not isinstance(value["events"], list) or not all(
        isinstance(event, str) and event for event in value["events"]
    ):
        raise ValueError("evidence.events must be a string array")
    if not isinstance(value["workers"], list) or not all(
        isinstance(worker, str) and worker for worker in value["workers"]
    ):
        raise ValueError("evidence.workers must be a string array")
    if not isinstance(value["citations"], int) or isinstance(value["citations"], bool):
        raise ValueError("evidence.citations must be an integer")
    if not isinstance(value["latencyMs"], (int, float)) or isinstance(value["latencyMs"], bool):
        raise ValueError("evidence.latencyMs must be numeric")
    provenance = value["modelProvenance"]
    if not isinstance(provenance, dict) or set(provenance) != {
        "requestedModel", "effectiveModel", "reasoningLevel", "workerVersion"
    }:
        raise ValueError("modelProvenance must use the closed contract")
    return value


def ordered(events: list[str], expected: list[str]) -> bool:
    cursor = 0
    for event in events:
        if cursor < len(expected) and event == expected[cursor]:
            cursor += 1
    return cursor == len(expected)


def evaluate_assertion(assertion: dict, evidence: dict) -> tuple[bool, str]:
    kind = assertion["kind"]
    expected = assertion.get("value")
    provenance = evidence["modelProvenance"]
    if kind == "status_equals":
        passed = evidence["status"] == expected
    elif kind == "event_kind_present":
        passed = expected in evidence["events"]
    elif kind == "event_order":
        passed = isinstance(expected, list) and ordered(evidence["events"], expected)
    elif kind == "worker_used":
        passed = expected in evidence["workers"]
    elif kind == "citation_minimum":
        passed = evidence["citations"] >= expected
    elif kind == "artifact_created":
        passed = evidence["artifactCreated"] is True
    elif kind == "latency_maximum":
        passed = evidence["latencyMs"] <= expected
    elif kind == "no_safety_violation":
        passed = evidence["safetyViolation"] is False
    elif kind == "model_provenance_present":
        passed = all(
            isinstance(provenance[field], str) and bool(provenance[field])
            for field in ("effectiveModel", "reasoningLevel", "workerVersion")
        )
    elif kind == "requested_model_equals":
        passed = provenance["requestedModel"] == expected
    elif kind == "effective_model_equals":
        passed = provenance["effectiveModel"] == expected
    else:  # validate_suite makes this unreachable.
        passed = False
    return passed, f"{kind}: {'passed' if passed else 'failed'}"


def evaluate(suite: dict, evidence_items: list[object]) -> dict:
    scenarios = {scenario["id"]: scenario for scenario in suite["scenarios"]}
    evidence_by_id: dict[str, dict] = {}
    for raw in evidence_items:
        evidence = validate_evidence(raw)
        identifier = evidence["scenarioId"]
        if identifier not in scenarios or identifier in evidence_by_id:
            raise ValueError("evidence scenario ids must be known and unique")
        evidence_by_id[identifier] = evidence
    results = []
    for identifier, scenario in scenarios.items():
        evidence = evidence_by_id.get(identifier)
        if evidence is None:
            results.append({"scenarioId": identifier, "status": "missing", "checks": []})
            continue
        checks = []
        for assertion in scenario["assertions"]:
            passed, detail = evaluate_assertion(assertion, evidence)
            checks.append({"kind": assertion["kind"], "passed": passed, "detail": detail})
        results.append({
            "scenarioId": identifier,
            "status": "passed" if all(check["passed"] for check in checks) else "failed",
            "checks": checks,
        })
    return {
        "schemaVersion": "tron.whole_agent_report.v1",
        "suiteName": suite["name"],
        "scenarioCount": len(results),
        "passed": sum(result["status"] == "passed" for result in results),
        "failed": sum(result["status"] == "failed" for result in results),
        "missing": sum(result["status"] == "missing" for result in results),
        "results": results,
    }


def passing_evidence(scenario: dict) -> dict:
    evidence = {
        "scenarioId": scenario["id"],
        "status": "completed",
        "events": [],
        "workers": [],
        "citations": 0,
        "artifactCreated": False,
        "latencyMs": 1,
        "safetyViolation": False,
        "modelProvenance": {
            "requestedModel": "openai/gpt-5.6-luna",
            "effectiveModel": "openai/gpt-5.6-luna",
            "reasoningLevel": "medium",
            "workerVersion": "synthetic-version",
        },
    }
    for assertion in scenario["assertions"]:
        kind, expected = assertion["kind"], assertion.get("value")
        if kind == "status_equals":
            evidence["status"] = expected
        elif kind == "event_kind_present":
            evidence["events"].append(expected)
        elif kind == "event_order":
            evidence["events"].extend(expected)
        elif kind == "worker_used":
            evidence["workers"].append(expected)
        elif kind == "citation_minimum":
            evidence["citations"] = expected
        elif kind == "artifact_created":
            evidence["artifactCreated"] = True
        elif kind == "latency_maximum":
            evidence["latencyMs"] = expected
        elif kind == "requested_model_equals":
            evidence["modelProvenance"]["requestedModel"] = expected
        elif kind == "effective_model_equals":
            evidence["modelProvenance"]["effectiveModel"] = expected
    return evidence


def self_test(suite: dict) -> None:
    evidence = [passing_evidence(scenario) for scenario in suite["scenarios"]]
    report = evaluate(suite, evidence)
    assert report["scenarioCount"] == 20
    assert report["passed"] == 20 and report["failed"] == 0 and report["missing"] == 0
    evidence[0]["citations"] = 0
    failed = evaluate(suite, evidence)
    assert failed["failed"] == 1 and failed["passed"] == 19


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", type=Path, default=DEFAULT_SUITE)
    parser.add_argument("--evaluate", type=Path, help="JSON array of normalized evidence")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    suite = validate_suite(load_json(args.suite))
    if args.self_test:
        self_test(suite)
        print("whole-agent evaluator self-test passed")
        return
    if args.evaluate is None:
        print(json.dumps({
            "schemaVersion": suite["schemaVersion"],
            "name": suite["name"],
            "scenarioCount": len(suite["scenarios"]),
            "categories": sorted({scenario["category"] for scenario in suite["scenarios"]}),
        }, indent=2))
        return
    raw_evidence = load_json(args.evaluate)
    if not isinstance(raw_evidence, list):
        raise ValueError("evidence file must contain a JSON array")
    report = evaluate(suite, raw_evidence)
    encoded = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)
    if report["failed"] or report["missing"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
