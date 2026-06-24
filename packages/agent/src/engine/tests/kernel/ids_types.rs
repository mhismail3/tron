use super::*;

#[test]
fn ids_reject_empty_and_invalid_function_ids() {
    assert!(WorkerId::new("").is_err());
    assert!(FunctionId::new("missing_separator").is_err());
    assert!(FunctionId::new("::op").is_err());
    assert!(FunctionId::new("ns::").is_err());
    assert!(FunctionId::new("ns::op::extra").is_err());
    assert_eq!(FunctionId::new("ns::op").unwrap().namespace(), "ns");
}

#[test]
fn effect_class_helpers_classify_mutation() {
    assert!(!EffectClass::PureRead.is_mutating());
    assert!(!EffectClass::DeterministicCompute.is_mutating());
    assert!(!EffectClass::DelegatedInvocation.is_mutating());
    assert!(EffectClass::IdempotentWrite.is_mutating());
    assert!(EffectClass::IrreversibleSideEffect.requires_idempotency_for_agent_visibility());
}
