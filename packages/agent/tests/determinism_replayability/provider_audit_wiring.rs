use super::support::*;

#[test]
fn provider_request_audit_is_wired_before_model_response() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let event_types =
        read_repo_file("packages/agent/src/domains/session/event_store/types/generated.rs");
    let responder = read_repo_file("packages/agent/src/domains/model/responder/mod.rs");
    let turn_runner = read_repo_file("packages/agent/src/domains/agent/loop/turn_runner/mod.rs");
    let runner =
        read_repo_file("packages/agent/src/domains/agent/loop/orchestrator/agent_runner.rs");

    assert!(
        scorecard.contains(
            "| DRC-4 | Provider request audit before model streaming | 12 | passed_after_fix |"
        ),
        "DRC-4 must be closed only when provider audit persistence is implemented"
    );
    assert!(
        event_types.contains(
            "ModelProviderRequest => \"model.provider_request\" => payloads::model::ModelProviderRequestPayload"
        ),
        "model.provider_request must be a typed persisted session event"
    );
    assert!(
        responder.contains("fn request_audit(")
            && responder.contains("audit_payload(&request.context, &stream_options)")
            && responder
                .contains("build_request_audit(info, request, stream_options, provider_request)"),
        "model responder boundary must expose provider request audit without agent-loop provider internals"
    );
    let persist_pos = turn_runner
        .find("persist_model_provider_request_audit(")
        .expect("turn runner must persist provider request audit");
    let respond_pos = turn_runner
        .find("responder.respond(model_request)")
        .expect("turn runner must call responder after audit");
    assert!(
        persist_pos < respond_pos,
        "provider request audit persistence must appear before responder.respond"
    );
    assert!(
        runner.contains("provider_request_audit_persist_failure_prevents_model_response")
            && runner.contains("provider_request_audit_persists_before_assistant_message"),
        "agent-runner tests must prove audit persist failure blocks respond and success persists the audit row"
    );
}
