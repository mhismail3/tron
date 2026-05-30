use super::support::*;

#[test]
fn discovery_message_surfaces_related_trigger_metadata() {
    let mut function = FunctionDefinition::new(
        FunctionId::new("rwo_n7::echo").expect("function id"),
        crate::engine::WorkerId::new("rwo-n7-worker").expect("worker id"),
        "RWO-N7 fixture",
        crate::engine::VisibilityScope::System,
        crate::engine::EffectClass::PureRead,
    );
    function.metadata = json!({
        "relatedTriggers": [{
            "triggerId": "manual:rwo_n7.echo",
            "triggerType": "manual",
            "targetFunction": "rwo_n7::echo"
        }]
    });
    let entry = CapabilityRegistryEntry::from_function(function, 7);
    let target = ResolvedCapabilityTarget {
        binding_decision: CapabilityBindingDecision {
            decision_id: "decision-test".to_owned(),
            contract_id: entry.contract_id.clone(),
            selected_implementation: entry.implementation_id.clone(),
            selected_function_id: entry.function_id.clone(),
            selection_policy: "test".to_owned(),
            rejected_candidates: Vec::new(),
            catalog_revision: entry.catalog_revision,
            schema_digest: entry.schema_digest.clone(),
        },
        entry,
    };

    let message = discovery_message(&target);

    assert!(message.contains("manual:rwo_n7.echo"));
    assert!(message.contains("visible as metadata"));
    assert!(message.contains("not by trigger id"));
}

#[test]
fn trigger_metadata_target_guidance_names_related_function_without_aliasing_trigger() {
    let mut function = FunctionDefinition::new(
        FunctionId::new("rwo_n7::echo").expect("function id"),
        crate::engine::WorkerId::new("rwo-n7-worker").expect("worker id"),
        "RWO-N7 fixture",
        crate::engine::VisibilityScope::System,
        crate::engine::EffectClass::PureRead,
    );
    function.metadata = json!({
        "relatedTriggers": [{
            "triggerId": "manual:rwo_n7.echo",
            "triggerType": "manual",
            "targetFunction": "rwo_n7::echo"
        }]
    });
    let snapshot = CapabilityRegistrySnapshot::new(vec![function], 7);
    let arguments = json!({
        "message": "rwo-n7 live worker test",
        "nonce": "rwo-n7-2026-05-29"
    });

    let guidance = trigger_metadata_target_guidance_for_target_params(
        &json!({"capabilityId": "manual:rwo_n7.echo"}),
        &arguments,
        &snapshot,
    )
    .expect("trigger metadata guidance");
    let message = trigger_metadata_target_message(&guidance);

    assert_eq!(guidance["kind"], json!("trigger_metadata_target"));
    assert_eq!(
        guidance["requestedTriggerIds"],
        json!(["manual:rwo_n7.echo"])
    );
    assert_eq!(
        guidance["candidates"][0]["functionId"],
        json!("rwo_n7::echo")
    );
    assert_eq!(
        guidance["suggestedCalls"][0]["target"],
        json!("rwo_n7::echo")
    );
    assert_eq!(guidance["suggestedCalls"][0]["arguments"], arguments);
    assert!(message.contains("Trigger ids are metadata"));
    assert!(message.contains("target `rwo_n7::echo`"));
    assert!(!message.contains("CAPABILITY_NOT_FOUND"));
}

#[test]
fn trigger_metadata_intent_guidance_uses_exact_visible_trigger_ids() {
    let mut function = FunctionDefinition::new(
        FunctionId::new("rwo_n7::echo").expect("function id"),
        crate::engine::WorkerId::new("rwo-n7-worker").expect("worker id"),
        "RWO-N7 fixture",
        crate::engine::VisibilityScope::System,
        crate::engine::EffectClass::PureRead,
    );
    function.metadata = json!({
        "relatedTriggers": [{
            "triggerId": "manual:rwo_n7.echo",
            "triggerType": "manual",
            "targetFunction": "rwo_n7::echo"
        }]
    });
    let snapshot = CapabilityRegistrySnapshot::new(vec![function], 7);

    let guidance = trigger_metadata_target_guidance_for_intent(
        "Trigger the user-supplied exact manual trigger id `manual:rwo_n7.echo`.",
        &json!({}),
        &snapshot,
    )
    .expect("trigger metadata guidance");

    assert_eq!(
        guidance["requestedTriggerIds"],
        json!(["manual:rwo_n7.echo"])
    );
    assert_eq!(
        guidance["suggestedCalls"],
        json!([{"target": "rwo_n7::echo", "arguments": {}}])
    );
}
