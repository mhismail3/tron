//! Provider-neutral worker retrieval and deterministic recovery ranking.
//!
//! Both automatic provider projection and explicit `worker_discover` first use
//! an active `worker_relevance` hook. The scorer below remains deterministic,
//! local, explainable recovery before a router worker exists, after it fails,
//! and while that worker's own agent-runner session resolves tools.

use std::cmp::Ordering;
use std::collections::{BTreeSet, HashMap};

use serde_json::{Value, json};

use crate::engine::{ActorId, ActorKind, CausalContext, FunctionId, Invocation, TraceId};

const ROUTING_STOP_WORDS: &[&str] = &[
    "and",
    "are",
    "assistant",
    "been",
    "but",
    "can",
    "could",
    "did",
    "does",
    "for",
    "from",
    "had",
    "has",
    "have",
    "how",
    "into",
    "its",
    "may",
    "our",
    "result",
    "should",
    "that",
    "the",
    "their",
    "them",
    "then",
    "there",
    "these",
    "they",
    "this",
    "tool",
    "use",
    "used",
    "user",
    "using",
    "was",
    "were",
    "what",
    "when",
    "where",
    "which",
    "who",
    "will",
    "with",
    "worker",
    "would",
    "you",
    "your",
];

/// Searchable facts for one published worker without its executable payload.
#[derive(Clone, Debug)]
pub(crate) struct WorkerRetrievalDocument {
    pub(crate) key: String,
    pub(crate) worker_id: String,
    pub(crate) name: String,
    pub(crate) description: String,
    pub(crate) intents: Vec<String>,
    pub(crate) examples: Vec<String>,
    pub(crate) provenance: Vec<String>,
    pub(crate) completed_runs: u64,
    pub(crate) updated_at: String,
}

/// Explainable rank evidence shared by discovery and surface selection.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct WorkerRetrievalRank {
    pub(crate) key: String,
    pub(crate) worker_id: String,
    pub(crate) promoted: bool,
    pub(crate) relevance_score: usize,
    pub(crate) explanation: Option<String>,
    pub(crate) completed_runs: u64,
    pub(crate) updated_at: String,
}

/// Ranking plus request-specific evidence about how the ordering was chosen.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct WorkerRankingOutcome {
    pub(crate) ranks: Vec<WorkerRetrievalRank>,
    pub(crate) mechanism: String,
    pub(crate) router_worker_id: Option<String>,
    pub(crate) router_worker_version: Option<String>,
    pub(crate) router_invocation_id: Option<String>,
}

impl WorkerRankingOutcome {
    fn deterministic(ranks: Vec<WorkerRetrievalRank>, mechanism: &str) -> Self {
        Self {
            ranks,
            mechanism: mechanism.to_owned(),
            router_worker_id: None,
            router_worker_version: None,
            router_invocation_id: None,
        }
    }
}

pub(crate) fn rank_workers(
    documents: impl IntoIterator<Item = WorkerRetrievalDocument>,
    query: Option<&str>,
    promoted_workers: &BTreeSet<String>,
) -> Vec<WorkerRetrievalRank> {
    let query_terms = terms(query.unwrap_or_default());
    let query_phrases = adjacent_phrases(query.unwrap_or_default());
    let mut ranked = documents
        .into_iter()
        .map(|document| WorkerRetrievalRank {
            relevance_score: relevance_score(&document, &query_terms, &query_phrases),
            explanation: None,
            promoted: promoted_workers.contains(&document.worker_id),
            key: document.key,
            worker_id: document.worker_id,
            completed_runs: document.completed_runs,
            updated_at: document.updated_at,
        })
        .collect::<Vec<_>>();
    ranked.sort_by(compare_rank);
    ranked
}

/// Resolve ranking while retaining whether semantic policy or deterministic
/// recovery produced the exact request surface.
pub(crate) async fn rank_workers_with_hook_evidence(
    host: &crate::engine::EngineHostHandle,
    session_id: &str,
    origin_worker_id: Option<&str>,
    documents: Vec<WorkerRetrievalDocument>,
    query: Option<&str>,
    promoted_workers: &BTreeSet<String>,
    selection_limit: usize,
) -> WorkerRankingOutcome {
    // Agent-runner workers resolve their own bounded tool surface. Applying a
    // semantic router there can recurse across internal hook owners (for
    // example Relevance -> Inbox -> Relevance), so worker sessions always use
    // the deterministic recovery scorer.
    if origin_worker_id.is_some() {
        return WorkerRankingOutcome::deterministic(
            rank_workers(documents, query, promoted_workers),
            "child_agent_allowlist",
        );
    }
    // Ranking zero or one worker is deterministic and does not justify a
    // semantic-model lifecycle boundary.
    if query_is_empty(query) || documents.len() <= 1 {
        return WorkerRankingOutcome::deterministic(
            rank_workers(documents, query, promoted_workers),
            "deterministic_trivial",
        );
    }
    let deterministic = rank_workers(documents.clone(), query, promoted_workers);
    let meaningful_count = deterministic
        .iter()
        .filter(|candidate| candidate.relevance_score > 0)
        .count();
    if meaningful_count <= selection_limit {
        return WorkerRankingOutcome::deterministic(deterministic, "deterministic_within_limit");
    }
    let meaningful_worker_ids = deterministic
        .iter()
        .filter(|candidate| candidate.relevance_score > 0)
        .map(|candidate| candidate.worker_id.as_str())
        .collect::<BTreeSet<_>>();
    let candidates = documents
        .iter()
        .filter(|document| meaningful_worker_ids.contains(document.worker_id.as_str()))
        .map(semantic_candidate_payload)
        .collect::<Vec<_>>();
    let mut payload = json!({
        "query":query.unwrap_or_default(),
        "candidates":candidates,
    });
    if let Some(worker_id) = origin_worker_id {
        payload["originWorkerId"] = json!(worker_id);
    }
    let invocation = FunctionId::new(crate::domains::worker_kernel::WORKER_RELEVANCE_FUNCTION)
        .ok()
        .and_then(|function_id| {
            let actor_id = ActorId::new("system:worker-relevance").ok()?;
            Some(Invocation::new_sync(
                function_id,
                payload,
                CausalContext::new(actor_id, ActorKind::System, TraceId::generate())
                    .with_session_id(session_id)
                    .with_idempotency_key(format!("worker-relevance:{}", uuid::Uuid::now_v7())),
            ))
        });
    let Some(invocation) = invocation else {
        return WorkerRankingOutcome::deterministic(deterministic, "deterministic_fallback");
    };
    let outcome = host.invoke(invocation).await;
    let rankings = outcome
        .error
        .is_none()
        .then_some(outcome.value.as_ref())
        .flatten()
        .filter(|value| value["handled"] == true)
        .and_then(|value| value["rankings"].as_array().cloned());
    let Some(rankings) = rankings else {
        if let Some(error) = outcome.error {
            tracing::warn!(%error, "worker relevance hook failed; using deterministic recovery");
        }
        return WorkerRankingOutcome::deterministic(deterministic, "deterministic_fallback");
    };
    let router_worker_id = outcome
        .value
        .as_ref()
        .and_then(|value| value.get("workerId"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    let router_worker_version = outcome
        .value
        .as_ref()
        .and_then(|value| value.get("workerVersion"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    let router_invocation_id = outcome
        .value
        .as_ref()
        .and_then(|value| value.get("invocationId"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    let semantic_evidence = rankings
        .into_iter()
        .filter_map(|ranking| {
            Some((
                ranking["workerId"].as_str()?.to_owned(),
                (
                    usize::try_from(ranking["score"].as_u64()?).ok()?,
                    ranking["reason"].as_str().map(|reason| {
                        crate::shared::foundation::text::truncate_with_suffix(
                            &crate::shared::foundation::redaction::redact_sensitive_content(
                                reason.trim(),
                            ),
                            512,
                            "…",
                        )
                    }),
                ),
            ))
        })
        .collect::<HashMap<_, _>>();
    let mut ranked = documents
        .into_iter()
        .map(|document| WorkerRetrievalRank {
            relevance_score: semantic_evidence
                .get(&document.worker_id)
                .map_or(0, |evidence| evidence.0),
            explanation: semantic_evidence
                .get(&document.worker_id)
                .and_then(|evidence| evidence.1.clone()),
            promoted: promoted_workers.contains(&document.worker_id),
            key: document.key,
            worker_id: document.worker_id,
            completed_runs: document.completed_runs,
            updated_at: document.updated_at,
        })
        .collect::<Vec<_>>();
    ranked.sort_by(compare_rank);
    WorkerRankingOutcome {
        ranks: ranked,
        mechanism: "semantic_hook".to_owned(),
        router_worker_id,
        router_worker_version,
        router_invocation_id,
    }
}

pub(super) fn semantic_candidate_payload(document: &WorkerRetrievalDocument) -> Value {
    json!({
        "workerId":document.worker_id,
        "name":document.name,
        "description":document.description,
        "intents":document.intents,
        "examples":document.examples,
        "provenance":document.provenance,
        "completedRuns":document.completed_runs,
        "updatedAt":document.updated_at,
    })
}

pub(crate) fn query_is_empty(query: Option<&str>) -> bool {
    query.is_none_or(|query| terms(query).is_empty())
}

fn relevance_score(
    document: &WorkerRetrievalDocument,
    query_terms: &BTreeSet<String>,
    query_phrases: &BTreeSet<String>,
) -> usize {
    if query_terms.is_empty() {
        return 0;
    }
    let name = normalized_text(&document.name);
    let description = normalized_text(&document.description);
    let intents = document
        .intents
        .iter()
        .map(|value| normalized_text(value))
        .collect::<Vec<_>>();
    let examples = document
        .examples
        .iter()
        .map(|value| normalized_text(value))
        .collect::<Vec<_>>();
    let name_terms = terms(&name);
    let description_terms = terms(&description);
    let intent_terms = combined_terms(&intents);
    let example_terms = combined_terms(&examples);

    let mut score = 0usize;
    for term in query_terms {
        score += usize::from(name_terms.contains(term)) * 8;
        score += usize::from(intent_terms.contains(term)) * 6;
        score += usize::from(example_terms.contains(term)) * 4;
        score += usize::from(description_terms.contains(term)) * 2;
    }
    for phrase in query_phrases {
        score += contains_phrase(&name, phrase, 14);
        score += contains_any_phrase(&intents, phrase, 10);
        score += contains_any_phrase(&examples, phrase, 8);
        score += contains_phrase(&description, phrase, 4);
    }
    score
}

fn compare_rank(left: &WorkerRetrievalRank, right: &WorkerRetrievalRank) -> Ordering {
    right
        .promoted
        .cmp(&left.promoted)
        .then_with(|| right.relevance_score.cmp(&left.relevance_score))
        .then_with(|| right.completed_runs.cmp(&left.completed_runs))
        .then_with(|| right.updated_at.cmp(&left.updated_at))
        .then_with(|| left.worker_id.cmp(&right.worker_id))
        .then_with(|| left.key.cmp(&right.key))
}

fn terms(value: &str) -> BTreeSet<String> {
    value
        .split(|character: char| !character.is_ascii_alphanumeric())
        .map(str::to_ascii_lowercase)
        .filter(|term| term.len() > 2 && !ROUTING_STOP_WORDS.contains(&term.as_str()))
        .collect()
}

fn normalized_text(value: &str) -> String {
    value
        .split(|character: char| !character.is_ascii_alphanumeric())
        .filter(|part| !part.is_empty())
        .map(str::to_ascii_lowercase)
        .collect::<Vec<_>>()
        .join(" ")
}

fn combined_terms(values: &[String]) -> BTreeSet<String> {
    values.iter().flat_map(|value| terms(value)).collect()
}

fn adjacent_phrases(value: &str) -> BTreeSet<String> {
    value
        .lines()
        .flat_map(|line| {
            let words = normalized_text(line)
                .split_whitespace()
                .filter(|word| word.len() > 2 && !ROUTING_STOP_WORDS.contains(word))
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>();
            (2..=3).flat_map(move |width| {
                words
                    .windows(width)
                    .map(|window| window.join(" "))
                    .collect::<Vec<_>>()
            })
        })
        .collect()
}

fn contains_phrase(value: &str, phrase: &str, weight: usize) -> usize {
    usize::from(value.contains(phrase)) * weight
}

fn contains_any_phrase(values: &[String], phrase: &str, weight: usize) -> usize {
    usize::from(values.iter().any(|value| value.contains(phrase))) * weight
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn install_relevance_worker(
        host: &crate::engine::EngineHostHandle,
        rankings_output: &str,
    ) {
        let bundle = json!({
            "schemaVersion":"tron.worker_bundle.v1",
            "workerId":"semantic-router",
            "name":"Semantic Router",
            "description":"Ranks persistent workers for the current task",
            "modelExposure":"internal",
            "inputSchema":{
                "type":"object","additionalProperties":false,"required":["query","candidates"],
                "properties":{
                    "query":{"type":"string"},
                    "candidates":{"type":"array","items":{
                        "type":"object","additionalProperties":false,
                        "required":["workerId","name","description","intents","examples","provenance","completedRuns","updatedAt"],
                        "properties":{
                            "workerId":{"type":"string","minLength":1},"name":{"type":"string"},
                            "description":{"type":"string"},"intents":{"type":"array"},
                            "examples":{"type":"array"},"provenance":{"type":"array"},
                            "completedRuns":{"type":"integer","minimum":0},"updatedAt":{"type":"string"}
                        }
                    }}
                }
            },
            "outputSchema":{
                "type":"object","additionalProperties":false,"required":["rankings"],
                "properties":{"rankings":{"type":"array","items":{
                    "type":"object","additionalProperties":false,"required":["workerId","score"],
                    "properties":{
                        "workerId":{"type":"string","minLength":1},
                        "score":{"type":"integer","minimum":0,"maximum":1000000000},
                        "reason":{"type":"string"}
                    }
                }}}
            },
            "runner":{"kind":"command","command":["printf",rankings_output]},
            "engineHooks":["worker_relevance"],
            "provenance":[{"source":"test:semantic-router"}]
        });
        let outcome = host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker_kernel::upsert").unwrap(),
                json!({"bundle":bundle}),
                CausalContext::new(
                    ActorId::new("agent:retrieval-test").unwrap(),
                    ActorKind::Agent,
                    TraceId::generate(),
                )
                .with_session_id("retrieval-test")
                .with_idempotency_key("install-semantic-router"),
            ))
            .await;
        assert_eq!(outcome.error, None, "semantic router upsert failed");
    }

    fn document(worker_id: &str, intent: &str, completed_runs: u64) -> WorkerRetrievalDocument {
        WorkerRetrievalDocument {
            key: worker_id.to_owned(),
            worker_id: worker_id.to_owned(),
            name: "Worker".to_owned(),
            description: "Persistent worker".to_owned(),
            intents: vec![intent.to_owned()],
            examples: Vec::new(),
            provenance: Vec::new(),
            completed_runs,
            updated_at: "2026-07-20T00:00:00Z".to_owned(),
        }
    }

    #[test]
    fn explicit_promotion_precedes_relevance_and_recovery_is_deterministic() {
        let ranked = rank_workers(
            [
                document("research", "recent research", 1),
                document("promoted", "unrelated transform", 0),
                document("veteran", "recent research", 9),
            ],
            Some("recent research"),
            &BTreeSet::from(["promoted".to_owned()]),
        );
        assert_eq!(
            ranked
                .iter()
                .map(|rank| rank.worker_id.as_str())
                .collect::<Vec<_>>(),
            ["promoted", "veteran", "research"]
        );
        assert!(ranked[1].relevance_score > 0);
    }

    #[tokio::test]
    async fn active_worker_hook_ranks_projection_and_self_origin_recovers_locally() {
        let context = crate::shared::server::test_support::make_test_context();
        install_relevance_worker(
            &context.engine_host,
            r#"{"rankings":[{"workerId":"formatter","score":1000,"reason":"semantic match"},{"workerId":"research","score":1}]}"#,
        )
        .await;
        let documents = vec![
            document("research", "recent research", 1),
            document("formatter", "format notes", 0),
        ];

        let ranked = rank_workers_with_hook_evidence(
            &context.engine_host,
            "retrieval-test",
            None,
            documents.clone(),
            Some("recent research and format notes"),
            &BTreeSet::new(),
            1,
        )
        .await
        .ranks;
        assert_eq!(ranked[0].worker_id, "formatter");
        assert_eq!(ranked[0].relevance_score, 1000);
        assert_eq!(ranked[0].explanation.as_deref(), Some("semantic match"));

        let self_origin = rank_workers_with_hook_evidence(
            &context.engine_host,
            "retrieval-worker-test",
            Some("semantic-router"),
            documents,
            Some("recent research"),
            &BTreeSet::new(),
            12,
        )
        .await
        .ranks;
        assert_eq!(self_origin[0].worker_id, "research");
        assert!(self_origin[0].relevance_score > 0);
    }

    #[tokio::test]
    async fn single_candidate_skips_semantic_hook_without_disabling_its_owner() {
        let context = crate::shared::server::test_support::make_test_context();
        install_relevance_worker(
            &context.engine_host,
            r#"{"rankings":[{"workerId":"not-a-candidate","score":1000}]}"#,
        )
        .await;

        let ranked = rank_workers_with_hook_evidence(
            &context.engine_host,
            "single-candidate-test",
            None,
            vec![document("research", "recent research", 1)],
            Some("recent research"),
            &BTreeSet::new(),
            12,
        )
        .await
        .ranks;

        assert_eq!(ranked[0].worker_id, "research");
        assert!(ranked[0].relevance_score > 0);
        let inspection = context
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker_kernel::inspect").unwrap(),
                json!({"workerId":"semantic-router","detail":"full"}),
                CausalContext::new(
                    ActorId::new("agent:retrieval-test").unwrap(),
                    ActorKind::Agent,
                    TraceId::generate(),
                )
                .with_session_id("single-candidate-test")
                .with_idempotency_key("inspect-single-candidate-router"),
            ))
            .await
            .value
            .unwrap();
        assert_eq!(inspection["worker"]["enabled"], true);
    }

    #[tokio::test]
    async fn one_meaningful_candidate_skips_semantic_hook_without_invocation_churn() {
        let context = crate::shared::server::test_support::make_test_context();
        install_relevance_worker(
            &context.engine_host,
            r#"{"rankings":[{"workerId":"not-a-candidate","score":1000}]}"#,
        )
        .await;

        let ranked = rank_workers_with_hook_evidence(
            &context.engine_host,
            "one-meaningful-candidate-test",
            None,
            vec![
                document("research", "recent research", 1),
                document("formatter", "format notes", 0),
            ],
            Some("recent research"),
            &BTreeSet::new(),
            12,
        )
        .await
        .ranks;

        assert_eq!(ranked[0].worker_id, "research");
        let inspection = context
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker_kernel::inspect").unwrap(),
                json!({"workerId":"semantic-router","detail":"full"}),
                CausalContext::new(
                    ActorId::new("agent:retrieval-test").unwrap(),
                    ActorKind::Agent,
                    TraceId::generate(),
                )
                .with_session_id("one-meaningful-candidate-test")
                .with_idempotency_key("inspect-one-meaningful-router"),
            ))
            .await
            .value
            .unwrap();
        assert_eq!(inspection["worker"]["enabled"], true);
        assert!(
            inspection["invocations"]
                .as_array()
                .is_none_or(Vec::is_empty),
            "semantic routing should not run for a single meaningful candidate"
        );
    }

    #[tokio::test]
    async fn invalid_worker_hook_ranking_disables_owner_and_uses_recovery() {
        let context = crate::shared::server::test_support::make_test_context();
        install_relevance_worker(
            &context.engine_host,
            r#"{"rankings":[{"workerId":"not-a-candidate","score":1000}]}"#,
        )
        .await;
        let documents = vec![
            document("research", "recent research", 1),
            document("formatter", "format notes", 0),
        ];

        let ranked = rank_workers_with_hook_evidence(
            &context.engine_host,
            "invalid-retrieval-test",
            None,
            documents,
            Some("recent research and format notes"),
            &BTreeSet::new(),
            1,
        )
        .await
        .ranks;
        assert_eq!(ranked[0].worker_id, "research");

        let inspection = context
            .engine_host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker_kernel::inspect").unwrap(),
                json!({"workerId":"semantic-router","detail":"full"}),
                CausalContext::new(
                    ActorId::new("agent:retrieval-test").unwrap(),
                    ActorKind::Agent,
                    TraceId::generate(),
                )
                .with_session_id("invalid-retrieval-test")
                .with_idempotency_key("inspect-invalid-semantic-router"),
            ))
            .await;
        assert_eq!(inspection.error, None);
        let inspection = inspection.value.expect("worker inspection payload");
        assert_eq!(inspection["worker"]["enabled"], false);
        assert_eq!(inspection["route"]["enabled"], false);
        assert_eq!(inspection["healthHistory"][0]["status"], "failed");
    }

    #[test]
    fn intent_phrase_outranks_incidental_description_overlap() {
        let mut incidental = document("incidental", "format data", 0);
        incidental.description = "Mentions recent research somewhere".to_owned();
        let ranked = rank_workers(
            [incidental, document("purpose-built", "recent research", 0)],
            Some("recent research"),
            &BTreeSet::new(),
        );
        assert_eq!(ranked[0].worker_id, "purpose-built");
    }

    #[test]
    fn current_news_routes_to_search_while_deep_investigation_routes_to_coordinator() {
        let mut search = document(
            "research-search",
            "current events latest headlines quick linked lookup",
            3,
        );
        search.name = "Research Search".to_owned();
        search.examples = vec!["What is happening in the news today?".to_owned()];
        let mut coordinator = document(
            "research-coordinator",
            "deep multi source investigation contradiction analysis durable report",
            20,
        );
        coordinator.name = "Research Coordinator".to_owned();

        let quick = rank_workers(
            [search.clone(), coordinator.clone()],
            Some("What's happening in the news today?"),
            &BTreeSet::new(),
        );
        assert_eq!(quick[0].worker_id, "research-search");
        assert!(quick[0].relevance_score > 0);
        assert_eq!(quick[1].relevance_score, 0);

        let deep = rank_workers(
            [search, coordinator],
            Some("Perform a deep multi-source investigation with contradiction analysis"),
            &BTreeSet::new(),
        );
        assert_eq!(deep[0].worker_id, "research-coordinator");
        assert!(deep[0].relevance_score > 0);
    }

    #[test]
    fn exact_tokens_do_not_match_inside_unrelated_words() {
        let ranked = rank_workers(
            [
                document("party", "party catalog", 0),
                document("art", "art catalog", 0),
            ],
            Some("art catalog"),
            &BTreeSet::new(),
        );
        assert_eq!(ranked[0].worker_id, "art");
        assert!(ranked[0].relevance_score > ranked[1].relevance_score);
    }

    #[test]
    fn conversational_framing_does_not_make_every_worker_relevant() {
        let ranked = rank_workers(
            [document("formatter", "format source code", 0)],
            Some("user: use a worker\nassistant: tool result"),
            &BTreeSet::new(),
        );
        assert_eq!(ranked[0].relevance_score, 0);
        assert!(query_is_empty(Some(
            "user: use a worker\nassistant: tool result"
        )));
    }
}
