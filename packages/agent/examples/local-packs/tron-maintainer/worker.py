#!/usr/bin/env python3
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pack_runtime import run_pack_worker


NAMESPACE = "tron_maintainer_example"

PACK = {
    "title": "Tron Maintainer Example Pack",
    "version": "1.0.0",
    "category": "tron-maintainer",
    "namespace": NAMESPACE,
    "worker_id": "tron-maintainer-example-worker",
    "model_preset": "balanced",
    "subagent_roles": ["review"],
    "functions": [
        {
            "id": f"{NAMESPACE}::repo_health",
            "handler": "repo_health",
            "description": "Summarize local repository health for a Tron workspace.",
            "effect_class": "PureRead",
            "risk": "Low",
            "required_authority": [f"{NAMESPACE}.read"],
            "output_resource_kinds": [],
            "tags": ["tron", "repo", "health"],
            "recommendation": "Review status, touched files, and next verification command.",
            "request_schema": {
                "type": "object",
                "additionalProperties": False,
                "required": ["repoPath"],
                "properties": {"repoPath": {"type": "string"}},
            },
            "examples": [{"payload": {"repoPath": "."}}],
        },
        {
            "id": f"{NAMESPACE}::test_summary",
            "handler": "repo_health",
            "description": "Prepare a focused local test summary for a Tron change.",
            "effect_class": "DeterministicCompute",
            "risk": "Low",
            "required_authority": [f"{NAMESPACE}.read"],
            "output_resource_kinds": [],
            "tags": ["tron", "tests", "summary"],
            "recommendation": "Run the smallest high-signal verification before broad CI.",
            "request_schema": {
                "type": "object",
                "additionalProperties": False,
                "required": ["changedArea"],
                "properties": {"changedArea": {"type": "string"}},
            },
            "examples": [{"payload": {"changedArea": "packages/agent"}}],
        },
        {
            "id": f"{NAMESPACE}::scorecard_evidence",
            "handler": "repo_health",
            "description": "Create a local scorecard/evidence checkpoint artifact.",
            "effect_class": "IdempotentWrite",
            "risk": "Medium",
            "required_authority": [f"{NAMESPACE}.write"],
            "output_resource_kinds": ["artifact"],
            "tags": ["tron", "scorecard", "evidence"],
            "recommendation": "Record commands, results, open loops, and no-release boundary.",
            "request_schema": {
                "type": "object",
                "additionalProperties": False,
                "required": ["scorecardPath", "evidencePath"],
                "properties": {
                    "scorecardPath": {"type": "string"},
                    "evidencePath": {"type": "string"},
                },
            },
            "examples": [{
                "payload": {
                    "scorecardPath": "packages/agent/docs/tron-productization-scorecard.md",
                    "evidencePath": "packages/agent/docs/tron-productization-evidence-manifest.md",
                }
            }],
        },
    ],
}


if __name__ == "__main__":
    run_pack_worker(PACK)
