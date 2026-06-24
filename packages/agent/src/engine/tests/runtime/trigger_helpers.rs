use super::*;

use std::sync::Mutex;

pub(super) fn loss_tolerant_void_function(id: &str, owner: &str) -> FunctionDefinition {
    let mut function = FunctionDefinition::new(
        fid(id),
        wid(owner),
        "loss-tolerant telemetry",
        VisibilityScope::Agent,
        EffectClass::AppendOnlyEvent,
    )
    .with_allowed_delivery_modes(vec![DeliveryMode::Sync, DeliveryMode::Void])
    .with_idempotency(IdempotencyContract::caller_session());
    function.metadata = json!({
        "delivery": {
            "voidLossTolerant": true
        }
    });
    function
}

#[derive(Clone)]
pub(super) struct CaptureInvocationHandler {
    pub(super) calls: Arc<AtomicUsize>,
    pub(super) invocations: Arc<Mutex<Vec<Invocation>>>,
}

#[async_trait]
impl InProcessFunctionHandler for CaptureInvocationHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.invocations.lock().unwrap().push(invocation.clone());
        Ok(json!({
            "payload": invocation.payload,
            "deliveryMode": invocation.delivery_mode.as_str(),
        }))
    }
}

#[derive(Clone)]
pub(super) struct CascadingTriggerHandler {
    pub(super) handle: EngineHostHandle,
    pub(super) trigger_id: TriggerId,
    pub(super) calls: Arc<AtomicUsize>,
    pub(super) invocations: Arc<Mutex<Vec<Invocation>>>,
}

#[async_trait]
impl InProcessFunctionHandler for CascadingTriggerHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let call = self.calls.fetch_add(1, Ordering::SeqCst) + 1;
        self.invocations.lock().unwrap().push(invocation.clone());
        let cascade = if call == 1 {
            let mut request = TriggerDispatchRequest::new(
                self.trigger_id.clone(),
                json!({"cascade": true}),
                invocation.causal_context.actor_id.clone(),
                invocation.causal_context.actor_kind.clone(),
            );
            request.authority_scopes = invocation.causal_context.authority_scopes.clone();
            request.runtime_metadata = invocation.causal_context.runtime_metadata.clone();
            request.trace_id = Some(invocation.causal_context.trace_id.clone());
            request.parent_invocation_id = Some(invocation.id.clone());
            request.session_id = invocation.causal_context.session_id.clone();
            request.workspace_id = invocation.causal_context.workspace_id.clone();
            let result = EngineTriggerRuntime::dispatch(&self.handle, request).await;
            let kind = match result.error.as_ref() {
                Some(EngineError::PolicyViolation(_)) => Some("policy_violation"),
                Some(_) => Some("unexpected_error"),
                None => None,
            };
            json!({
                "error": result.error.as_ref().map(|error| error.to_string()),
                "kind": kind,
            })
        } else {
            Value::Null
        };
        Ok(json!({
            "call": call,
            "cascadeError": cascade,
        }))
    }
}
