use super::SkillMetadata;
use super::{RwLock, SkillRegistry, SkillsClearedMode, SkillsClearedPayload};
use crate::domains::session::event_store::EventStore;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use std::sync::Arc;

/// Collect skills activated since the last `message.user` event.
///
/// Returns `skills_json` in the format expected by clients:
/// `[{"name", "source", "service", "displayName"}]`.
///
/// Uses event-store sequence ordering to find only the skill events that belong
/// to the current prompt. Registry metadata enriches service/display names;
/// missing registry entries degrade to `"unknown"` plus the raw skill name.
pub fn collect_pending_skill_payloads(
    event_store: &crate::domains::session::event_store::EventStore,
    session_id: &str,
    skill_registry: Option<&crate::domains::skills::registry::SkillRegistry>,
) -> Option<Value> {
    let last_user_seq = event_store
        .get_latest_event_by_type(session_id, "message.user")
        .ok()
        .flatten()
        .map(|e| e.sequence)
        .unwrap_or(0);

    let recent_events = event_store
        .get_events_since(session_id, last_user_seq)
        .unwrap_or_default();

    let mut skills: Vec<Value> = Vec::new();

    for event in &recent_events {
        let payload: Value = match serde_json::from_str(&event.payload) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if event.event_type.as_str() == "skill.activated" {
            if let Some(name) = payload.get("skillName").and_then(|v| v.as_str()) {
                let source = payload
                    .get("source")
                    .and_then(|v| v.as_str())
                    .unwrap_or("project");
                let registry_entry = skill_registry.and_then(|r| r.get(name));
                let display_name = registry_entry
                    .map(|m| m.display_name.as_str())
                    .unwrap_or(name);
                let service = registry_entry
                    .map(|m| m.service.as_str())
                    .unwrap_or("unknown");
                skills.push(serde_json::json!({
                    "name": name,
                    "source": source,
                    "service": service,
                    "displayName": display_name,
                }));
            }
        }
    }

    if skills.is_empty() {
        None
    } else {
        Some(Value::Array(skills))
    }
}

/// Prepare skill context for a prompt: reconstructs the [`SkillTracker`]
/// from events, **emits a `skills.cleared` event** under either the
/// `ClearAll` or `AskUser` compaction policy if any skills were cleared at
/// the last boundary, looks up active skills in the registry, and builds
/// the `<skills>` XML block.
///
/// The payload's `mode` field discriminates the iOS render:
/// - `ClearAll` → informational notice listing the previously-active skills.
/// - `AskUser` → interactive picker chips that call `skill.activate` on tap.
///
/// `AutoRestore` never reaches this emission branch because its tracker
/// preserves active skills through the boundary and leaves `cleared_at_boundary`
/// empty. See `SkillTracker::from_events_with_policy`.
///
/// The `prepare_*` prefix (vs `build_*`) signals that this writes to the
/// event store as a side effect — callers that want a pure formatter
/// against an existing tracker should use the lower-level helpers in
/// `crate::domains::skills::injector` directly.
///
/// The compaction policy is snapshotted before entering the blocking worker so
/// a concurrent settings reload cannot change emission behavior mid-prepare.
pub async fn prepare_skill_context_from_session(
    skill_registry: Arc<RwLock<SkillRegistry>>,
    event_store: Arc<EventStore>,
    session_id: String,
) -> Result<SkillContextResult, CapabilityError> {
    let policy = {
        let settings = crate::domains::settings::get_settings();
        settings.skills.compaction_policy.clone()
    };
    run_blocking_task("agent.prompt.skills", move || {
        let tracker = crate::domains::skills::state::reconstruct_tracker(
            &event_store,
            &session_id,
            &policy,
        );

        // Side effect: under ClearAll OR AskUser policy, persist a
        // `skills.cleared` event so the iOS client can render the correct
        // banner or picker. Documented in the doc-comment above.
        // AutoRestore skips this branch by construction (cleared_at_boundary
        // is always empty under AutoRestore). See M6.
        //
        // INVARIANT: the wire shape of this event is pinned by the typed
        // `SkillsClearedPayload` struct in `events/types/payloads/skill.rs`.
        // We round-trip through `serde_json::to_value(&payload)` rather than
        // an inline `json!` literal so any future rename/retype of the struct
        // fields is caught by the compiler instead of silently drifting
        // between the emitter and the decoders (Rust tests + iOS).
        let mode = match policy {
            crate::domains::settings::types::CompactionPolicy::ClearAll => Some(SkillsClearedMode::ClearAll),
            crate::domains::settings::types::CompactionPolicy::AskUser => Some(SkillsClearedMode::AskUser),
            crate::domains::settings::types::CompactionPolicy::AutoRestore => None,
        };
        if let Some(mode) = mode {
            let cleared = tracker.cleared_at_boundary();
            if !cleared.is_empty() {
                let payload = SkillsClearedPayload {
                    cleared_skills: cleared.to_vec(),
                    reason: "compaction".to_string(),
                    mode,
                };
                let payload_value = serde_json::to_value(&payload).expect(
                    "SkillsClearedPayload is composed of owned primitives and always serializes",
                );
                let _ = event_store.append(&crate::domains::session::event_store::AppendOptions {
                    session_id: &session_id,
                    event_type: crate::domains::session::event_store::EventType::SkillsCleared,
                    payload: payload_value,
                    parent_id: None,
                    sequence: None,
                });
            }
        }

        // Collect active skill names
        let active_names = tracker.active_skill_names();

        tracing::info!(
            active_count = tracker.count(),
            active_skills = ?active_names,
            "[skills] reconstructed tracker for session {session_id}"
        );

        // Look up metadata from registry
        let found: Vec<SkillMetadata> = if active_names.is_empty() {
            Vec::new()
        } else {
            let registry = skill_registry.read();
            let name_refs: Vec<&str> = active_names.iter().map(String::as_str).collect();
            let (found, _not_found) = registry.get_many(&name_refs);
            found.into_iter().cloned().collect()
        };

        tracing::info!(
            found_count = found.len(),
            found_names = ?found.iter().map(|s| &s.name).collect::<Vec<_>>(),
            "[skills] registry lookup result"
        );

        // Build XML context
        let skill_context = if found.is_empty() {
            None
        } else {
            let skill_refs: Vec<&SkillMetadata> = found.iter().collect();
            let context = crate::domains::skills::injector::build_skill_context(&skill_refs);
            tracing::info!(
                context_len = context.len(),
                context_preview = &context[..context.len().min(200)],
                "[skills] built skill context XML"
            );
            (!context.is_empty()).then_some(context)
        };

        // Build activation directive for active skills
        let skill_activation_context =
            crate::domains::skills::injector::build_activation_directive(&active_names);

        // Build removal notice for deactivated skills + post-compaction guidance
        let removal_notice = {
            let mut notices = Vec::new();

            // Post-compaction skill notice: when skills were cleared by compaction
            // and none re-activated, tell the model not to use skills from the summary
            if tracker.skills_cleared_by_compaction() {
                notices.push(
                    "Context was compacted and all previously active skills were cleared. \
                     Skills mentioned in the earlier context summary are not currently active \
                     and should not be used. To use a skill, activate it with @skill-name."
                        .to_string(),
                );
            }

            // Standard removal notice for explicitly deactivated skills
            let pending_removals = tracker.pending_removal_notices();
            if !pending_removals.is_empty() {
                let names: Vec<String> = pending_removals
                    .iter()
                    .map(|n| format!("@{n}"))
                    .collect();
                notices.push(format!(
                    "The following skills have been deactivated. Stop following their instructions: {}.",
                    names.join(", ")
                ));
            }

            if notices.is_empty() {
                None
            } else {
                Some(notices.join("\n\n"))
            }
        };

        Ok(SkillContextResult {
            skill_activation_context,
            skill_context,
            skill_removal_context: removal_notice,
        })
    })
    .await
}

/// Result of building skill context from session state.
pub struct SkillContextResult {
    /// Activation directive ("follow these active skills").
    pub skill_activation_context: Option<String>,
    /// The `<skills>` XML block for active skills.
    pub skill_context: Option<String>,
    /// One-turn removal notice for recently deactivated skills.
    pub skill_removal_context: Option<String>,
}

#[cfg(test)]
mod skills_cleared_emission_tests {
    //! Integration tests for the `skills.cleared` emission side effect in
    //! [`prepare_skill_context_from_session`]. See M6 in the audit plan.
    //!
    //! These tests mutate the global settings singleton and MUST hold the
    //! shared settings test lock to serialize with other settings-
    //! mutating tests.

    use super::*;
    use crate::domains::session::event_store::types::payloads::skill::{
        SkillsClearedMode, SkillsClearedPayload,
    };
    use crate::domains::settings::types::CompactionPolicy;
    use crate::shared::server::test_support::make_test_context;

    fn settings_lock() -> &'static std::sync::Mutex<()> {
        crate::domains::settings::test_settings_lock()
    }

    fn settings_with_policy(policy: CompactionPolicy) -> crate::domains::settings::TronSettings {
        let mut s = crate::domains::settings::TronSettings::default();
        s.skills.compaction_policy = policy;
        s
    }

    fn append(
        store: &Arc<crate::domains::session::event_store::EventStore>,
        session_id: &str,
        event_type: crate::domains::session::event_store::EventType,
        payload: serde_json::Value,
    ) {
        store
            .append(&crate::domains::session::event_store::AppendOptions {
                session_id,
                event_type,
                payload,
                parent_id: None,
                sequence: None,
            })
            .expect("append must succeed");
    }

    fn seed_skill_activated_then_boundary(
        store: &Arc<crate::domains::session::event_store::EventStore>,
        session_id: &str,
    ) {
        append(
            store,
            session_id,
            crate::domains::session::event_store::EventType::SkillActivated,
            serde_json::json!({ "skillName": "browser", "source": "global" }),
        );
        append(
            store,
            session_id,
            crate::domains::session::event_store::EventType::SkillActivated,
            serde_json::json!({ "skillName": "code", "source": "project" }),
        );
        append(
            store,
            session_id,
            crate::domains::session::event_store::EventType::CompactBoundary,
            serde_json::json!({
                "originalTokens": 0,
                "compactedTokens": 0,
                "reason": "manual",
            }),
        );
    }

    fn read_skills_cleared_events(
        store: &crate::domains::session::event_store::EventStore,
        session_id: &str,
    ) -> Vec<SkillsClearedPayload> {
        store
            .get_events_by_type(session_id, &["skills.cleared"], None)
            .unwrap()
            .into_iter()
            .map(|row| serde_json::from_str::<SkillsClearedPayload>(&row.payload).unwrap())
            .collect()
    }

    async fn run_with_policy(policy: CompactionPolicy) -> Vec<SkillsClearedPayload> {
        let ctx = make_test_context();
        let session_id = ctx
            .session_manager
            .create_session("test-model", "/tmp", Some("t"), None)
            .unwrap();
        seed_skill_activated_then_boundary(&ctx.event_store, &session_id);

        let _guard = settings_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        crate::domains::settings::init_settings(settings_with_policy(policy));
        let _ = prepare_skill_context_from_session(
            ctx.skill_registry.clone(),
            ctx.event_store.clone(),
            session_id.clone(),
        )
        .await
        .unwrap();
        // Restore defaults before releasing the lock.
        crate::domains::settings::init_settings(crate::domains::settings::TronSettings::default());
        drop(_guard);

        read_skills_cleared_events(&ctx.event_store, &session_id)
    }

    #[tokio::test]
    async fn emits_skills_cleared_under_clear_all_with_mode_clear_all() {
        let events = run_with_policy(CompactionPolicy::ClearAll).await;
        assert_eq!(events.len(), 1, "exactly one skills.cleared event expected");
        let payload = &events[0];
        assert_eq!(payload.mode, SkillsClearedMode::ClearAll);
        assert_eq!(payload.reason, "compaction");
        let mut names = payload.cleared_skills.clone();
        names.sort();
        assert_eq!(names, vec!["browser", "code"]);
    }

    #[tokio::test]
    async fn emits_skills_cleared_under_ask_user_with_mode_ask_user() {
        let events = run_with_policy(CompactionPolicy::AskUser).await;
        assert_eq!(events.len(), 1, "exactly one skills.cleared event expected");
        let payload = &events[0];
        assert_eq!(payload.mode, SkillsClearedMode::AskUser);
        assert_eq!(payload.reason, "compaction");
        let mut names = payload.cleared_skills.clone();
        names.sort();
        assert_eq!(names, vec!["browser", "code"]);
    }

    #[tokio::test]
    async fn does_not_emit_under_auto_restore() {
        // AutoRestore preserves active skills through the boundary, so there's
        // nothing cleared to notify about.
        let events = run_with_policy(CompactionPolicy::AutoRestore).await;
        assert!(
            events.is_empty(),
            "AutoRestore must never emit skills.cleared"
        );
    }

    #[tokio::test]
    async fn no_emission_when_no_boundary_yet() {
        // Even under ClearAll/AskUser, if no compact.boundary has happened
        // the cleared list is empty and we must not emit.
        let ctx = make_test_context();
        let session_id = ctx
            .session_manager
            .create_session("test-model", "/tmp", Some("t"), None)
            .unwrap();
        append(
            &ctx.event_store,
            &session_id,
            crate::domains::session::event_store::EventType::SkillActivated,
            serde_json::json!({ "skillName": "a", "source": "global" }),
        );

        let _guard = settings_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        crate::domains::settings::init_settings(settings_with_policy(CompactionPolicy::ClearAll));
        let _ = prepare_skill_context_from_session(
            ctx.skill_registry.clone(),
            ctx.event_store.clone(),
            session_id.clone(),
        )
        .await
        .unwrap();
        crate::domains::settings::init_settings(crate::domains::settings::TronSettings::default());
        drop(_guard);

        let events = read_skills_cleared_events(&ctx.event_store, &session_id);
        assert!(events.is_empty());
    }

    #[tokio::test]
    async fn emitted_payload_exactly_matches_typed_struct_serialization() {
        // Regression guard for the M6 audit follow-up: the emission site must
        // round-trip through `SkillsClearedPayload` rather than an inline
        // `json!` literal, so any rename/retype of a struct field breaks the
        // compiler instead of silently drifting between emitter and decoder.
        //
        // We reconstruct the expected wire shape from the typed struct and
        // assert the raw on-disk payload matches — no field names hardcoded
        // in this test either, so both sides track the struct.
        let events = run_with_policy(CompactionPolicy::ClearAll).await;
        assert_eq!(events.len(), 1);
        let payload = &events[0];

        let expected = SkillsClearedPayload {
            cleared_skills: {
                let mut v = payload.cleared_skills.clone();
                v.sort();
                v
            },
            reason: "compaction".to_string(),
            mode: SkillsClearedMode::ClearAll,
        };

        // Sort on our copy for stable comparison.
        let mut actual = payload.clone();
        actual.cleared_skills.sort();
        assert_eq!(actual, expected);

        // And the reverse: the struct round-trips to a JSON object with
        // exactly the three wire-expected keys — no stray fields, no missing.
        let json = serde_json::to_value(&expected).unwrap();
        let obj = json.as_object().unwrap();
        let mut keys: Vec<&str> = obj.keys().map(String::as_str).collect();
        keys.sort();
        assert_eq!(keys, vec!["clearedSkills", "mode", "reason"]);
    }

    #[tokio::test]
    async fn emission_is_suppressed_on_second_call() {
        // Double-dispatch guard: once skills.cleared has been appended, the
        // tracker resets cleared_at_boundary on its `skills.cleared` branch, so
        // a second call to prepare_skill_context_from_session must not emit a
        // duplicate event.
        let ctx = make_test_context();
        let session_id = ctx
            .session_manager
            .create_session("test-model", "/tmp", Some("t"), None)
            .unwrap();
        seed_skill_activated_then_boundary(&ctx.event_store, &session_id);

        let _guard = settings_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        crate::domains::settings::init_settings(settings_with_policy(CompactionPolicy::AskUser));
        let _ = prepare_skill_context_from_session(
            ctx.skill_registry.clone(),
            ctx.event_store.clone(),
            session_id.clone(),
        )
        .await
        .unwrap();
        let _ = prepare_skill_context_from_session(
            ctx.skill_registry.clone(),
            ctx.event_store.clone(),
            session_id.clone(),
        )
        .await
        .unwrap();
        crate::domains::settings::init_settings(crate::domains::settings::TronSettings::default());
        drop(_guard);

        let events = read_skills_cleared_events(&ctx.event_store, &session_id);
        assert_eq!(events.len(), 1, "duplicate emission suppressed");
    }
}
