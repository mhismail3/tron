use super::*;

#[test]
fn external_worker_protocol_roundtrips_local_session_default_messages() {
    let worker = WorkerDefinition::new(
        wid("local-worker"),
        WorkerKind::External,
        actor("owner"),
        grant("external-grant"),
    )
    .with_namespace_claim("local");
    let hello =
        super::WorkerProtocolMessage::Hello(Box::new(super::WorkerHello::loopback(worker.clone())));
    let function = FunctionDefinition::new(
        fid("local::echo"),
        wid("local-worker"),
        "session-default external function",
        VisibilityScope::Session,
        EffectClass::PureRead,
    )
    .with_provenance(Provenance::system().with_session_id("session-a"));
    let register =
        super::WorkerProtocolMessage::RegisterFunction(Box::new(super::RegisterFunction {
            definition: external_visible_function(function),
            default_visibility: VisibilityScope::Session,
        }));
    if let super::WorkerProtocolMessage::RegisterFunction(message) = &register {
        assert_eq!(message.default_visibility, VisibilityScope::Session);
        assert_eq!(message.definition.visibility, VisibilityScope::Session);
    }
    let trigger = super::WorkerProtocolMessage::RegisterTrigger(super::RegisterTrigger {
        definition: TriggerDefinition::new(
            TriggerId::new("manual:local.echo").unwrap(),
            wid("local-worker"),
            TriggerTypeId::new("manual").unwrap(),
            fid("local::echo"),
            grant("external-grant"),
        ),
    });
    let invoke = super::WorkerProtocolMessage::Invoke(super::WorkerInvoke {
        invocation_id: super::InvocationId::generate(),
        function_id: fid("local::echo"),
        payload: json!({"hello": "worker"}),
        actor_kind: ActorKind::Agent,
        authority_grant_id: grant("agent-grant"),
        authority_scopes: vec!["local.read".to_owned()],
        trace_id: trace("worker-trace"),
        parent_invocation_id: None,
        trigger_id: Some(TriggerId::new("manual:local.echo").unwrap()),
        idempotency_key: None,
        session_id: Some("session-a".to_owned()),
        workspace_id: None,
        timeout_ms: 30_000,
    });
    for message in [hello, register, trigger, invoke] {
        let json = serde_json::to_string(&message).unwrap();
        let decoded: super::WorkerProtocolMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, message);
    }
}
