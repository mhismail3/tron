//! Durable reusable-agent role-review proposal tests.

use super::*;

fn proposal(request_key: &str, suffix: char) -> NewAgentRoleReviewProposal {
    let proposal_hash = suffix.to_string().repeat(64);
    NewAgentRoleReviewProposal {
        proposal_id: format!("agent_role_review_{proposal_hash}"),
        request_key: request_key.to_owned(),
        proposal_hash,
        target_worker_id: "legacy-agent".to_owned(),
        target_worker_version: "a".repeat(64),
        target_content_hash: "a".repeat(64),
        reviewer_worker_id: "reviewer-capability".to_owned(),
        reviewer_worker_version: "b".repeat(64),
        reviewer_invocation_id: format!("worker_invocation_{suffix}"),
        agent_role: WorkerAgentRole::Disabled,
        rationale: "This runner is intentionally a direct-only capability.".to_owned(),
    }
}

#[test]
fn role_review_proposals_survive_restart_and_recover_an_interrupted_apply() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let request = proposal("role-review-start-one", 'c');
    let (created, was_created) = store.create_agent_role_review_proposal(&request).unwrap();
    let (replay, replay_created) = store.create_agent_role_review_proposal(&request).unwrap();
    assert!(was_created);
    assert!(!replay_created);
    assert_eq!(created.proposal_id, replay.proposal_id);
    assert_eq!(created.reviewer_invocation_id, "worker_invocation_c");
    assert_eq!(created.status, AgentRoleReviewStatus::Proposed);

    store
        .begin_agent_role_review_apply(&created.proposal_id, "role-review-apply-one")
        .unwrap();
    drop(store);

    let reopened = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let recovered = reopened
        .agent_role_review_proposal(&created.proposal_id)
        .unwrap()
        .unwrap();
    assert_eq!(recovered.status, AgentRoleReviewStatus::Proposed);
    assert!(
        recovered
            .last_error
            .as_deref()
            .unwrap()
            .contains("restarted")
    );
    assert_eq!(recovered.reviewer_invocation_id, "worker_invocation_c");

    let rejected = reopened
        .reject_agent_role_review_proposal(
            &created.proposal_id,
            "role-review-reject-one",
            Some("Not a reusable role"),
        )
        .unwrap();
    assert_eq!(rejected.status, AgentRoleReviewStatus::Rejected);
    assert_eq!(
        rejected.rejection_reason.as_deref(),
        Some("Not a reusable role")
    );
    assert!(
        reopened
            .reject_agent_role_review_proposal(
                &created.proposal_id,
                "role-review-reject-one",
                Some("Different reason under the same key"),
            )
            .is_err()
    );
}

#[test]
fn role_review_history_is_paged_and_request_replays_are_exact() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let first = proposal("role-review-page-one", 'd');
    store.create_agent_role_review_proposal(&first).unwrap();
    let mut second = proposal("role-review-page-two", 'e');
    second.target_worker_id = "legacy-agent-two".to_owned();
    store.create_agent_role_review_proposal(&second).unwrap();

    let page = store.list_agent_role_review_proposals(1, 0).unwrap();
    assert_eq!(page.proposals.len(), 1);
    assert_eq!(page.total, 2);
    assert_eq!(page.next_offset, Some(1));
    let final_page = store.list_agent_role_review_proposals(1, 1).unwrap();
    assert_eq!(final_page.proposals.len(), 1);
    assert_eq!(final_page.next_offset, None);

    let mut conflicting = first;
    conflicting.rationale = "Different output under the same admission key".to_owned();
    assert_eq!(
        store
            .create_agent_role_review_proposal(&conflicting)
            .unwrap_err(),
        "agent role review proposal idempotency conflict"
    );
}

#[test]
fn one_open_proposal_wins_for_an_exact_target_version() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let first = proposal("role-review-race-one", 'a');
    let (winner, created) = store.create_agent_role_review_proposal(&first).unwrap();
    assert!(created);

    let competitor = proposal("role-review-race-two", 'b');
    let (observed, competitor_created) = store
        .create_agent_role_review_proposal(&competitor)
        .unwrap();
    assert!(!competitor_created);
    assert_eq!(observed.proposal_id, winner.proposal_id);
    assert_eq!(
        store.list_agent_role_review_proposals(10, 0).unwrap().total,
        1
    );
}
