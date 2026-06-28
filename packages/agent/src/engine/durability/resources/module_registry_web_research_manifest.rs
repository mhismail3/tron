//! Web browser and research module-pack manifest seed.
//!
//! This keeps Slice 24F evidence separate from the generic module-registry
//! definition and does not introduce browser automation, search providers,
//! crawling, login/cookie reuse, raw page capture, dependency restoration, or
//! executable module code.

use serde_json::{Value, json};

use super::module_registry_definitions::{MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION, redaction_proof};

pub(super) fn web_research_module_manifest() -> Value {
    json!({
        "schemaVersion": MODULE_MANIFEST_PAYLOAD_SCHEMA_VERSION,
        "identity": {
            "moduleId": "web_research_module",
            "name": "Web Browser And Research Module Pack",
            "kind": "module_pack",
            "owner": "domains::web_research",
            "summary": "Metadata-only web research request, review, citation, source, robots-evidence, and dependency-request custody",
            "version": "phase3-slice24f"
        },
        "capabilityDeclarations": [
            {"operation": "web_research_request_record", "effect": "write", "providerVisible": true, "description": "Record a metadata-only web research request with bounded summaries, refs, policy labels, side-effect proof, and idempotency evidence"},
            {"operation": "web_research_request_list", "effect": "read", "providerVisible": true, "description": "List bounded provider-safe web research requests"},
            {"operation": "web_research_request_inspect", "effect": "read", "providerVisible": true, "description": "Inspect one bounded redacted web research request"},
            {"operation": "web_research_review_record", "effect": "write", "providerVisible": true, "description": "Record a metadata-only review linked by exact web_research_request selector"},
            {"operation": "web_research_review_list", "effect": "read", "providerVisible": true, "description": "List bounded provider-safe web research reviews"},
            {"operation": "web_research_review_inspect", "effect": "read", "providerVisible": true, "description": "Inspect one bounded redacted web research review"},
            {"operation": "web_research_source_record", "effect": "write", "providerVisible": true, "description": "Record a bounded source or citation artifact linked by exact request or review selectors"},
            {"operation": "web_research_source_list", "effect": "read", "providerVisible": true, "description": "List bounded provider-safe source and citation artifacts"},
            {"operation": "web_research_source_inspect", "effect": "read", "providerVisible": true, "description": "Inspect one bounded redacted source or citation artifact"}
        ],
        "resourceDeclarations": [
            {"kind": "web_research_request", "schemaId": "tron.resource.web_research_request.v1", "payloadSchemaVersion": "tron.web_research_request.v1", "scope": "session_or_workspace"},
            {"kind": "web_research_review", "schemaId": "tron.resource.web_research_review.v1", "payloadSchemaVersion": "tron.web_research_review.v1", "scope": "session_or_workspace"},
            {"kind": "web_research_source", "schemaId": "tron.resource.web_research_source.v1", "payloadSchemaVersion": "tron.web_research_source.v1", "scope": "session_or_workspace"}
        ],
        "authorityNeeds": [
            {"scope": "web_research.read", "purpose": "inspect provider-safe web research metadata"},
            {"scope": "web_research.write", "purpose": "record metadata-only web research requests, reviews, and source artifacts"},
            {"scope": "resource.read", "purpose": "inspect exact linked request, review, source, web_source, web_robots_policy, dependency, trace, and replay refs"},
            {"scope": "resource.write", "purpose": "append web research metadata resources under exact selectors"}
        ],
        "settingsDeclarations": [],
        "dependencyIntents": [],
        "validation": {
            "status": "pending_review",
            "checks": [
                {
                    "id": "metadata_only_custody",
                    "status": "implementation-candidate",
                    "summary": "Records store bounded summaries, labels, refs, side-effect proof, and idempotency fingerprints only"
                },
                {
                    "id": "network_and_browser_deferred",
                    "status": "implementation-candidate",
                    "summary": "Operations require networkPolicy none and do not perform search, crawling, browser automation, login, cookie reuse, or raw page capture"
                },
                {
                    "id": "exact_selector_authority",
                    "status": "implementation-candidate",
                    "summary": "Inspect and linked review/source writes require explicit kind:web_research_* and resource:<id> selectors without wildcard grants"
                },
                {
                    "id": "provider_redaction",
                    "status": "implementation-candidate",
                    "summary": "Provider projections omit raw HTML, page dumps, browser logs, cookies, credentials, local paths, commands, raw code/file contents, grant ids, authority ids, and token-like material"
                }
            ],
            "evidenceRefs": [
                {
                    "kind": "phase3_inventory",
                    "ref": "P3MSA-INV-014"
                }
            ]
        },
        "provenance": {
            "source": "source_backed_first_party",
            "sourceRefs": [
                {
                    "kind": "crate_module",
                    "ref": "domains::web_research"
                },
                {
                    "kind": "crate_module",
                    "ref": "domains::capability"
                }
            ]
        },
        "lifecycle": {
            "state": "pending_review",
            "activation": "review_decision_metadata_only",
            "installable": false,
            "executable": false,
            "networkPolicy": "none"
        },
        "redactionProof": redaction_proof()
    })
}
