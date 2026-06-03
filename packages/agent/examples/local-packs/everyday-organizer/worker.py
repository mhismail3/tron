#!/usr/bin/env python3
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pack_runtime import run_pack_worker


NAMESPACE = "everyday_organizer_example"

PACK = {
    "title": "Everyday Organizer Example Pack",
    "version": "1.0.0",
    "category": "everyday-organizer",
    "namespace": NAMESPACE,
    "worker_id": "everyday-organizer-example-worker",
    "model_preset": "localWhenPossible",
    "subagent_roles": ["organizer"],
    "functions": [
        {
            "id": f"{NAMESPACE}::daily_digest",
            "handler": "daily_digest",
            "description": "Summarize local notes or task snippets into a daily digest.",
            "effect_class": "DeterministicCompute",
            "risk": "Low",
            "required_authority": [f"{NAMESPACE}.read"],
            "output_resource_kinds": [],
            "tags": ["digest", "organizer", "local"],
            "recommendation": "Review today, next, and waiting sections before filing.",
            "request_schema": {
                "type": "object",
                "additionalProperties": False,
                "required": ["items"],
                "properties": {"items": {"type": "string"}},
            },
            "examples": [{"payload": {"items": "Draft agenda; confirm follow-up"}}],
        },
        {
            "id": f"{NAMESPACE}::organize_items",
            "handler": "daily_digest",
            "description": "Create an organizer artifact with today, next, and waiting sections.",
            "effect_class": "IdempotentWrite",
            "risk": "Medium",
            "required_authority": [f"{NAMESPACE}.write"],
            "output_resource_kinds": ["artifact"],
            "tags": ["organizer", "artifact", "local"],
            "recommendation": "Store the organized artifact before scheduling reminders.",
            "request_schema": {
                "type": "object",
                "additionalProperties": False,
                "required": ["items", "digestFolder"],
                "properties": {
                    "items": {"type": "string"},
                    "digestFolder": {"type": "string"},
                },
            },
            "examples": [{"payload": {"items": "Inbox sample", "digestFolder": "local-digests"}}],
        },
        {
            "id": f"{NAMESPACE}::deliver_notification",
            "handler": "daily_digest",
            "description": "Record a local notification delivery for a completed digest.",
            "effect_class": "ExternalSideEffect",
            "risk": "Medium",
            "required_authority": [f"{NAMESPACE}.notify"],
            "output_resource_kinds": ["notification"],
            "tags": ["notification", "digest", "local"],
            "recommendation": "Use a local notification record; do not call external services.",
            "request_schema": {
                "type": "object",
                "additionalProperties": False,
                "required": ["title", "body"],
                "properties": {
                    "title": {"type": "string"},
                    "body": {"type": "string"},
                },
            },
            "examples": [{"payload": {"title": "Digest ready", "body": "Review today and next."}}],
        },
    ],
}


if __name__ == "__main__":
    run_pack_worker(PACK)
