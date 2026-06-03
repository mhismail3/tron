#!/usr/bin/env python3
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pack_runtime import run_pack_worker


NAMESPACE = "creative_knowledge_example"

PACK = {
    "title": "Creative Knowledge Example Pack",
    "version": "1.0.0",
    "category": "creative-knowledge",
    "namespace": NAMESPACE,
    "worker_id": "creative-knowledge-example-worker",
    "model_preset": "deep",
    "subagent_roles": ["research"],
    "functions": [
        {
            "id": f"{NAMESPACE}::transform_prompt",
            "handler": "creative_transform",
            "description": "Transform a rough prompt into a reusable instruction.",
            "effect_class": "DeterministicCompute",
            "risk": "Low",
            "required_authority": [f"{NAMESPACE}.read"],
            "output_resource_kinds": [],
            "tags": ["prompt", "transform", "creative"],
            "recommendation": "Keep the transformed prompt inspectable before reuse.",
            "request_schema": {
                "type": "object",
                "additionalProperties": False,
                "required": ["prompt", "style"],
                "properties": {
                    "prompt": {"type": "string"},
                    "style": {"type": "string"},
                },
            },
            "examples": [{"payload": {"prompt": "Draft a brief", "style": "clear"}}],
        },
        {
            "id": f"{NAMESPACE}::notes_to_outline",
            "handler": "creative_transform",
            "description": "Convert rough notes into a structured knowledge outline.",
            "effect_class": "DeterministicCompute",
            "risk": "Low",
            "required_authority": [f"{NAMESPACE}.read"],
            "output_resource_kinds": [],
            "tags": ["notes", "outline", "knowledge"],
            "recommendation": "Use generated UI preview before saving the outline.",
            "request_schema": {
                "type": "object",
                "additionalProperties": False,
                "required": ["notes"],
                "properties": {"notes": {"type": "string"}},
            },
            "examples": [{"payload": {"notes": "Topic, references, next angle"}}],
        },
        {
            "id": f"{NAMESPACE}::save_transformation",
            "handler": "creative_transform",
            "description": "Save a prompt or notes transformation artifact for reuse.",
            "effect_class": "IdempotentWrite",
            "risk": "Medium",
            "required_authority": [f"{NAMESPACE}.write"],
            "output_resource_kinds": ["artifact"],
            "tags": ["artifact", "generated-ui", "knowledge"],
            "recommendation": "Create a reusable artifact and review it through package UI.",
            "request_schema": {
                "type": "object",
                "additionalProperties": False,
                "required": ["title", "content"],
                "properties": {
                    "title": {"type": "string"},
                    "content": {"type": "string"},
                },
            },
            "examples": [{"payload": {"title": "Reusable prompt", "content": "Write clearly."}}],
        },
    ],
}


if __name__ == "__main__":
    run_pack_worker(PACK)
