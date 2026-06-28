//! Provider schema additions for web research metadata execute operations.
//!
//! These fields describe request, review, and source/citation artifact custody.
//! They do not authorize network access, search, crawling, browser automation,
//! login/cookie reuse, or raw page capture.

use serde_json::{Map, Value, json};

#[cfg(test)]
pub(super) const WEB_RESEARCH_SCHEMA_FIELDS: &[&str] = &[
    "webResearchRequestResourceId",
    "webResearchReviewResourceId",
    "webResearchSourceResourceId",
    "webResearchRequestId",
    "webResearchReviewId",
    "webResearchSourceId",
    "questionSummary",
    "scopeSummary",
    "reviewOutcome",
    "reviewSummary",
    "artifactKind",
    "policyLabels",
    "sourceRefs",
    "citationRefs",
    "robotsEvidenceRefs",
    "dependencyRequestRefs",
    "currentScopeRefs",
    "evidenceRefs",
];

pub(super) fn append_schema_properties(properties: &mut Map<String, Value>) {
    for (name, description) in [
        (
            "webResearchRequestResourceId",
            "Durable web_research_request resource id for inspect, review, or source artifact linkage.",
        ),
        (
            "webResearchReviewResourceId",
            "Durable web_research_review resource id for inspect or source artifact linkage.",
        ),
        (
            "webResearchSourceResourceId",
            "Durable web_research_source resource id for source artifact inspect.",
        ),
        (
            "webResearchRequestId",
            "Optional caller-visible web research request id.",
        ),
        (
            "webResearchReviewId",
            "Optional caller-visible web research review id.",
        ),
        (
            "webResearchSourceId",
            "Optional caller-visible web research source artifact id.",
        ),
        (
            "questionSummary",
            "Bounded research question summary for web_research_request_record.",
        ),
        (
            "scopeSummary",
            "Optional bounded current research scope summary.",
        ),
        (
            "reviewOutcome",
            "Bounded review outcome label for web_research_review_record.",
        ),
        (
            "reviewSummary",
            "Bounded review summary for web_research_review_record.",
        ),
        (
            "artifactKind",
            "Bounded source artifact kind such as source_summary, citation_set, robots_evidence, dependency_ref, trace_ref, or replay_ref.",
        ),
    ] {
        insert_string(properties, name, description);
    }
    for (name, description) in [
        (
            "policyLabels",
            "Bounded policy labels for web research metadata records.",
        ),
        (
            "sourceRefs",
            "Bounded refs to web_source or other source evidence resources.",
        ),
        (
            "citationRefs",
            "Bounded refs to citation/source artifact evidence.",
        ),
        (
            "robotsEvidenceRefs",
            "Bounded refs to web_robots_policy evidence resources.",
        ),
        (
            "dependencyRequestRefs",
            "Bounded refs to module dependency request evidence for future module-pack dependency review.",
        ),
        (
            "currentScopeRefs",
            "Bounded refs that prove current session/workspace scope linkage.",
        ),
        (
            "evidenceRefs",
            "Additional bounded evidence refs; no raw HTML, browser logs, local paths, commands, code, or secrets.",
        ),
    ] {
        properties.insert(
            name.to_owned(),
            json!({"type": "array", "description": description}),
        );
    }
}

fn insert_string(properties: &mut Map<String, Value>, name: &str, description: &str) {
    properties.insert(
        name.to_owned(),
        json!({"type": "string", "description": description}),
    );
}
