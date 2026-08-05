//! Provider-neutral worker retrieval and deterministic recovery ranking.
//!
//! Automatic provider projection and explicit `worker_discover` both use the
//! deterministic local scorer below. Worker routing is kernel policy, so it
//! remains immediate, explainable, and independent of another worker run.

use std::cmp::Ordering;
use std::collections::BTreeSet;

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
    pub(crate) completed_runs: u64,
    pub(crate) updated_at: String,
}

/// Ranking plus request-specific evidence about how the ordering was chosen.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct WorkerRankingOutcome {
    pub(crate) ranks: Vec<WorkerRetrievalRank>,
    pub(crate) mechanism: String,
}

impl WorkerRankingOutcome {
    pub(crate) fn deterministic(ranks: Vec<WorkerRetrievalRank>, mechanism: &str) -> Self {
        Self {
            ranks,
            mechanism: mechanism.to_owned(),
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

    fn document(worker_id: &str, intent: &str, completed_runs: u64) -> WorkerRetrievalDocument {
        WorkerRetrievalDocument {
            key: worker_id.to_owned(),
            worker_id: worker_id.to_owned(),
            name: "Worker".to_owned(),
            description: "Persistent worker".to_owned(),
            intents: vec![intent.to_owned()],
            examples: Vec::new(),
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
