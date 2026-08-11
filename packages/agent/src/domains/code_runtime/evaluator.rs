use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use rquickjs::context::intrinsic;
use rquickjs::function::{Func, MutFn};
use rquickjs::promise::MaybePromise;
use rquickjs::{
    CatchResultExt, Context, Error as JsError, Function, Module, Runtime, Value as JsValue,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use thiserror::Error;
use uuid::Uuid;

use super::compiler::capture_candidate_result;
use super::store::{CallRow, CellRow, CodeRuntimeStore, StoreError};
use super::types::RuntimeLimits;

pub(crate) const SDK_BOOTSTRAP: &str = r#"
(() => {
  'use strict';
  const invoke = globalThis.__tronNativeCall;
  const emit = globalThis.__tronNativeLog;
  delete globalThis.__tronNativeCall;
  delete globalThis.__tronNativeLog;
  // QuickJS requires its Eval intrinsic for host-side source/module
  // evaluation. Remove the language-level direct eval before untrusted code so
  // it cannot reach private module-local replay instrumentation.
  delete globalThis.eval;

  const call = (operation, input = null) => {
    const encoded = JSON.stringify(input === undefined ? null : input);
    return JSON.parse(invoke(String(operation), encoded));
  };
  const format = (value) => {
    if (typeof value === 'string') return value;
    try {
      const encoded = JSON.stringify(value);
      return encoded === undefined ? String(value) : encoded;
    } catch (_) {
      return String(value);
    }
  };
  const logger = (...values) => emit(values.map(format).join(' '));
  const consoleValue = Object.freeze({
    log: logger, info: logger, warn: logger, error: logger, debug: logger
  });
  const agents = Object.freeze({
    discover: (input = {}) => call('agent.discover.v1', input),
    spawn: (input) => call('agent.spawn.v1', input),
    send: (input) => call('agent.send.v1', input),
    wait: (input) => call('agent.wait.v1', input),
    manage: (input) => call('agent.manage.v1', input)
  });
  const schedules = Object.freeze({
    list: (input = {}) => call('schedule.list.v1', input),
    create: (input) => call('schedule.create.v1', input),
    manage: (input) => call('schedule.manage.v1', input)
  });
  const services = Object.freeze({
    discover: (input = {}) => call('service.discover.v1', input),
    invoke: (input) => call('service.invoke.v1', input)
  });
  const skills = Object.freeze({
    discover: (input = {}) => call('skill.discover.v1', input),
    inspect: (input) => call('skill.inspect.v1', input),
    invoke: (input) => call('skill.invoke.v1', input)
  });
  const state = Object.freeze({
    query: (input) => call('state.query.v1', input),
    execute: (input) => call('state.execute.v1', input),
    info: (input) => call('state.info.v1', input)
  });
  const files = Object.freeze({
    read: (input) => call('file.read.v1', input),
    write: (input) => call('file.write.v1', input),
    edit: (input) => call('file.edit.v1', input)
  });
  const sdk = Object.freeze({
    version: 'tron.code.v1',
    help: () => call('runtime.help', null),
    call,
    agents,
    schedules,
    services,
    skills,
    state,
    files
  });
  Object.defineProperty(globalThis, 'tron', {
    value: sdk, writable: false, configurable: false, enumerable: true
  });
  Object.defineProperty(globalThis, 'console', {
    value: consoleValue, writable: false, configurable: false, enumerable: true
  });

  const originalDate = Date;
  class JournalDate extends originalDate {
    constructor(...args) {
      super(...(args.length === 0 ? [call('runtime.now', null)] : args));
    }
    static now() { return call('runtime.now', null); }
  }
  Object.defineProperty(globalThis, 'Date', {
    value: JournalDate, writable: false, configurable: false
  });
  Object.defineProperty(Math, 'random', {
    value: () => call('runtime.random', null), writable: false, configurable: false
  });
  Object.freeze(Math);
})();
"#;

/// Versioned broker request. `call_id` is the required downstream idempotency key.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BrokerRequest {
    /// Durable call identity, stable across a crash/retry.
    pub call_id: String,
    /// Closed operation name admitted by the engine broker.
    pub operation: String,
    /// JSON input.
    pub input: Value,
}

/// A broker failure is itself journaled and deterministically replayed.
#[derive(Debug, Clone, Error, PartialEq, Eq, Serialize, Deserialize)]
#[error("{message}")]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BrokerError {
    /// Stable, non-secret diagnostic.
    pub message: String,
}

impl BrokerError {
    /// Construct a broker failure.
    #[must_use]
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

/// Engine authority boundary used by code and skill modules.
///
/// Implementations must treat [`BrokerRequest::call_id`] as an idempotency key
/// because the helper can crash after an external effect but before importing
/// its terminal result.
pub trait Broker: Send + Sync {
    /// Execute one admitted, versioned operation.
    fn call(&self, request: &BrokerRequest) -> Result<Value, BrokerError>;
}

/// Broker which rejects every non-runtime operation.
#[derive(Debug, Default)]
pub struct NoopBroker;

impl Broker for NoopBroker {
    fn call(&self, request: &BrokerRequest) -> Result<Value, BrokerError> {
        Err(BrokerError::new(format!(
            "broker operation '{}' is unavailable",
            request.operation
        )))
    }
}

/// Physical QuickJS bounds for an evaluation.
pub type EvaluationLimits = RuntimeLimits;

#[derive(Debug)]
pub(crate) struct EvaluationOutcome {
    pub value: Value,
    pub output: Vec<String>,
}

#[derive(Debug, Error)]
pub(crate) enum EvaluationError {
    #[error("JavaScript runtime initialization failed: {0}")]
    Initialization(String),
    #[error("JavaScript evaluation failed: {0}")]
    JavaScript(String),
    #[error("broker call failed: {0}")]
    Broker(String),
    #[error("execution was cancelled")]
    Cancelled,
    #[error("execution exceeded its wall-clock limit")]
    TimedOut,
    #[error("execution exceeded its call/output limit")]
    Limit,
    #[error(transparent)]
    Store(#[from] StoreError),
}

struct BridgeState {
    store: CodeRuntimeStore,
    broker: Arc<dyn Broker>,
    replay: Vec<CallRow>,
    replay_cursor: usize,
    candidate_cell_id: String,
    candidate_ordinal: u64,
    candidate_phase: bool,
    total_calls: usize,
    limits: RuntimeLimits,
    output: Vec<String>,
    output_bytes: usize,
    limit_exceeded: bool,
}

impl BridgeState {
    fn invoke(&mut self, operation: &str, input: Value) -> Result<Value, EvaluationError> {
        if self.total_calls >= self.limits.max_calls_per_evaluation {
            self.limit_exceeded = true;
            return Err(EvaluationError::Limit);
        }
        self.total_calls += 1;

        let row = if !self.candidate_phase {
            let row = self.replay.get(self.replay_cursor).ok_or_else(|| {
                EvaluationError::Broker(
                    "replay emitted more broker calls than the committed journal".to_owned(),
                )
            })?;
            self.replay_cursor += 1;
            self.store.verify_call(row, operation, &input)?;
            row.clone()
        } else if let Some(row) = self
            .store
            .load_call(&self.candidate_cell_id, self.candidate_ordinal)?
        {
            self.store.verify_call(&row, operation, &input)?;
            self.candidate_ordinal += 1;
            row
        } else {
            let row = self.store.admit_call(
                &self.candidate_cell_id,
                self.candidate_ordinal,
                operation,
                &input,
            )?;
            self.candidate_ordinal += 1;
            row
        };

        match row.status.as_str() {
            "completed" => row
                .result
                .ok_or_else(|| EvaluationError::Broker("completed call has no result".to_owned())),
            "failed" => {
                Err(EvaluationError::Broker(row.error.unwrap_or_else(|| {
                    "journaled broker call failed".to_owned()
                })))
            }
            "admitted" => {
                let request = BrokerRequest {
                    call_id: row.call_id.clone(),
                    operation: operation.to_owned(),
                    input,
                };
                let outcome = builtin(&request).unwrap_or_else(|| self.broker.call(&request));
                match outcome {
                    Ok(value) => {
                        self.store.finish_call(&row.call_id, Ok(&value))?;
                        Ok(value)
                    }
                    Err(error) => {
                        self.store
                            .finish_call(&row.call_id, Err(error.message.as_str()))?;
                        Err(EvaluationError::Broker(error.message))
                    }
                }
            }
            other => Err(EvaluationError::Broker(format!(
                "unknown durable broker status {other}"
            ))),
        }
    }

    fn log(&mut self, message: String) -> Result<(), EvaluationError> {
        if !self.candidate_phase {
            return Ok(());
        }
        let next = self.output_bytes.saturating_add(message.len());
        if next > self.limits.max_output_bytes {
            self.limit_exceeded = true;
            return Err(EvaluationError::Limit);
        }
        self.output_bytes = next;
        self.output.push(message);
        Ok(())
    }
}

pub(crate) fn evaluate(
    store: CodeRuntimeStore,
    committed: &[CellRow],
    candidate: &CellRow,
    broker: Arc<dyn Broker>,
    limits: &RuntimeLimits,
    cancelled: Arc<AtomicBool>,
) -> Result<EvaluationOutcome, EvaluationError> {
    let mut replay = Vec::new();
    for cell in committed {
        replay.extend(store.calls_for_cell(&cell.cell_id)?);
    }
    let state = Rc::new(RefCell::new(BridgeState {
        store,
        broker,
        replay,
        replay_cursor: 0,
        candidate_cell_id: candidate.cell_id.clone(),
        candidate_ordinal: 0,
        candidate_phase: false,
        total_calls: 0,
        limits: limits.clone(),
        output: Vec::new(),
        output_bytes: 0,
        limit_exceeded: false,
    }));

    let runtime =
        Runtime::new().map_err(|error| EvaluationError::Initialization(error.to_string()))?;
    runtime.set_memory_limit(limits.memory_bytes);
    runtime.set_max_stack_size(limits.stack_bytes);
    let deadline = Instant::now() + Duration::from_millis(limits.wall_time_ms);
    let interrupted_for_cancel = cancelled.clone();
    runtime.set_interrupt_handler(Some(Box::new(move || {
        interrupted_for_cancel.load(Ordering::Relaxed) || Instant::now() >= deadline
    })));
    let context = Context::builder()
        .with::<intrinsic::Eval>()
        .with::<intrinsic::Date>()
        .with::<intrinsic::RegExpCompiler>()
        .with::<intrinsic::RegExp>()
        .with::<intrinsic::Json>()
        .with::<intrinsic::Proxy>()
        .with::<intrinsic::MapSet>()
        .with::<intrinsic::TypedArrays>()
        .with::<intrinsic::Promise>()
        .build(&runtime)
        .map_err(|error| EvaluationError::Initialization(error.to_string()))?;

    let result: Result<Value, String> = context.with(|ctx| {
        let evaluated = (|| -> rquickjs::Result<Value> {
            let call_state = state.clone();
            ctx.globals().set(
                "__tronNativeCall",
                Func::from(MutFn::from(move |operation: String, encoded: String| {
                    let input: Value = serde_json::from_str(&encoded).map_err(|error| {
                        JsError::new_from_js_message("JSON", "broker input", error.to_string())
                    })?;
                    let value =
                        call_state
                            .borrow_mut()
                            .invoke(&operation, input)
                            .map_err(|error| {
                                JsError::new_from_js_message(
                                    "broker",
                                    "JavaScript",
                                    error.to_string(),
                                )
                            })?;
                    serde_json::to_string(&value).map_err(|error| {
                        JsError::new_from_js_message("broker output", "JSON", error.to_string())
                    })
                })),
            )?;
            let log_state = state.clone();
            ctx.globals().set(
                "__tronNativeLog",
                Func::from(MutFn::from(move |message: String| {
                    log_state.borrow_mut().log(message).map_err(|error| {
                        JsError::new_from_js_message("console", "JavaScript", error.to_string())
                    })
                })),
            )?;
            let phase_state = state.clone();
            ctx.globals().set(
                "__tronNativeCandidate",
                Func::from(MutFn::from(move || {
                    let mut bridge = phase_state.borrow_mut();
                    if bridge.replay_cursor != bridge.replay.len() {
                        return Err(JsError::new_from_js_message(
                            "journal",
                            "JavaScript",
                            "replay emitted fewer broker calls than the committed journal",
                        ));
                    }
                    bridge.candidate_phase = true;
                    bridge.output.clear();
                    bridge.output_bytes = 0;
                    Ok(())
                })),
            )?;
            let bootstrap = ctx.eval_promise(SDK_BOOTSTRAP)?;
            bootstrap.finish::<()>()?;

            let committed_source = committed
                .iter()
                .map(|cell| cell.compiled.as_str())
                .collect::<Vec<_>>()
                .join("\n;\n");
            let candidate_source =
                capture_candidate_result(&candidate.compiled).map_err(|error| {
                    JsError::new_from_js_message("candidate", "JavaScript", error.to_string())
                })?;
            let assembled = format!(
                "const __tronCandidate = globalThis.__tronNativeCandidate;\n\
             delete globalThis.__tronNativeCandidate;\n\
             {committed_source}\n;\n\
             __tronCandidate();\n\
             {candidate_source}"
            );
            let promise = Module::evaluate(
                ctx.clone(),
                format!("runtime-{}.mjs", candidate.runtime_id),
                assembled,
            )?;
            promise.finish::<()>()?;
            let value: JsValue<'_> = ctx.globals().get("__tronCellResult")?;
            if let Some(encoded) = ctx
                .json_stringify(value)?
                .map(|value| value.to_string())
                .transpose()?
            {
                serde_json::from_str(&encoded).map_err(|error| {
                    JsError::new_from_js_message("JSON", "runtime result", error.to_string())
                })
            } else {
                Ok(json!({ "$tron": "undefined" }))
            }
        })();
        evaluated.catch(&ctx).map_err(|error| error.to_string())
    });

    match result {
        Ok(value) => Ok(EvaluationOutcome {
            value,
            output: state.borrow().output.clone(),
        }),
        Err(error) => {
            let state = state.borrow();
            if state.limit_exceeded {
                Err(EvaluationError::Limit)
            } else if cancelled.load(Ordering::Relaxed) {
                Err(EvaluationError::Cancelled)
            } else if Instant::now() >= deadline {
                Err(EvaluationError::TimedOut)
            } else {
                Err(EvaluationError::JavaScript(error.to_string()))
            }
        }
    }
}

pub(crate) fn evaluate_skill(
    module_name: &str,
    javascript: &str,
    source_digest: &str,
    state_namespace: &str,
    invocation_key: &str,
    input: &Value,
    broker: Arc<dyn Broker>,
    limits: &RuntimeLimits,
) -> Result<EvaluationOutcome, EvaluationError> {
    let runtime =
        Runtime::new().map_err(|error| EvaluationError::Initialization(error.to_string()))?;
    runtime.set_memory_limit(limits.memory_bytes);
    runtime.set_max_stack_size(limits.stack_bytes);
    let deadline = Instant::now() + Duration::from_millis(limits.wall_time_ms);
    runtime.set_interrupt_handler(Some(Box::new(move || Instant::now() >= deadline)));
    let context = Context::builder()
        .with::<intrinsic::Eval>()
        .with::<intrinsic::Date>()
        .with::<intrinsic::RegExpCompiler>()
        .with::<intrinsic::RegExp>()
        .with::<intrinsic::Json>()
        .with::<intrinsic::Proxy>()
        .with::<intrinsic::MapSet>()
        .with::<intrinsic::TypedArrays>()
        .with::<intrinsic::Promise>()
        .build(&runtime)
        .map_err(|error| EvaluationError::Initialization(error.to_string()))?;
    let output = Rc::new(RefCell::new(Vec::<String>::new()));
    let output_bytes = Rc::new(RefCell::new(0_usize));
    let ordinal = Rc::new(RefCell::new(0_u64));
    let digest = source_digest.to_owned();
    let namespace = state_namespace.to_owned();
    let invocation = invocation_key.to_owned();

    let result: Result<Value, String> = context.with(|ctx| {
        let evaluated = (|| -> rquickjs::Result<Value> {
            let call_broker = broker.clone();
            let call_ordinal = ordinal.clone();
            let call_digest = digest.clone();
            let call_namespace = namespace.clone();
            let call_invocation = invocation.clone();
            ctx.globals().set(
                "__tronNativeCall",
                Func::from(MutFn::from(move |operation: String, encoded: String| {
                    let mut input: Value = serde_json::from_str(&encoded).map_err(|error| {
                        JsError::new_from_js_message("JSON", "broker input", error.to_string())
                    })?;
                    if operation.starts_with("state.") {
                        let object = input.as_object_mut().ok_or_else(|| {
                            JsError::new_from_js_message(
                                "state input",
                                "broker input",
                                "skill state operations require an object input",
                            )
                        })?;
                        object.insert(
                            "namespace".to_owned(),
                            Value::String(call_namespace.clone()),
                        );
                    }
                    let current = *call_ordinal.borrow();
                    *call_ordinal.borrow_mut() = current.saturating_add(1);
                    let call_id = super::compiler::digest(
                        format!("{call_digest}:{call_invocation}:{current}").as_bytes(),
                    );
                    let request = BrokerRequest {
                        call_id,
                        operation,
                        input,
                    };
                    let value = builtin(&request)
                        .unwrap_or_else(|| call_broker.call(&request))
                        .map_err(|error| {
                            JsError::new_from_js_message("broker", "JavaScript", error.message)
                        })?;
                    serde_json::to_string(&value).map_err(|error| {
                        JsError::new_from_js_message("broker output", "JSON", error.to_string())
                    })
                })),
            )?;
            let log_output = output.clone();
            let log_bytes = output_bytes.clone();
            let max_output = limits.max_output_bytes;
            ctx.globals().set(
                "__tronNativeLog",
                Func::from(MutFn::from(move |message: String| {
                    let next = log_bytes.borrow().saturating_add(message.len());
                    if next > max_output {
                        return Err(JsError::new_from_js_message(
                            "console",
                            "JavaScript",
                            "output limit exceeded",
                        ));
                    }
                    *log_bytes.borrow_mut() = next;
                    log_output.borrow_mut().push(message);
                    Ok(())
                })),
            )?;
            ctx.eval_promise(SDK_BOOTSTRAP)?.finish::<()>()?;
            ctx.eval::<(), _>(
                "Object.defineProperty(globalThis, '__tronSkillCapabilities', {\
                value: Object.freeze({ tron, state: tron.state }),\
                writable: false, configurable: false\
             });",
            )?;
            let module = Module::declare(ctx.clone(), module_name, javascript)?;
            let (module, evaluated) = module.eval()?;
            evaluated.finish::<()>()?;
            let callable: Function<'_> = module.get("default")?;
            let capabilities: JsValue<'_> = ctx.globals().get("__tronSkillCapabilities")?;
            let encoded_input = serde_json::to_string(input).map_err(|error| {
                JsError::new_from_js_message("JSON", "skill input", error.to_string())
            })?;
            let js_input = ctx.json_parse(encoded_input)?;
            let value: JsValue<'_> = callable.call((capabilities, js_input))?;
            let value = MaybePromise::from_value(value).finish::<JsValue<'_>>()?;
            if let Some(encoded) = ctx
                .json_stringify(value)?
                .map(|value| value.to_string())
                .transpose()?
            {
                serde_json::from_str(&encoded).map_err(|error| {
                    JsError::new_from_js_message("JSON", "skill result", error.to_string())
                })
            } else {
                Ok(json!({ "$tron": "undefined" }))
            }
        })();
        evaluated.catch(&ctx).map_err(|error| error.to_string())
    });
    match result {
        Ok(value) => Ok(EvaluationOutcome {
            value,
            output: output.borrow().clone(),
        }),
        Err(_error) if Instant::now() >= deadline => Err(EvaluationError::TimedOut),
        Err(error) => Err(EvaluationError::JavaScript(error.to_string())),
    }
}

pub(crate) fn builtin(request: &BrokerRequest) -> Option<Result<Value, BrokerError>> {
    match request.operation.as_str() {
        "runtime.help" => Some(Ok(json!({
            "version": "tron.code.v1",
            "surface": [
                "tron.help()", "tron.call(operation, input)", "tron.agents",
                "tron.schedules", "tron.services", "tron.skills", "tron.state",
                "tron.files"
            ],
            "ambientAuthority": false,
            "bash": "explicit separate engine primitive"
        }))),
        "runtime.now" => Some(Ok(Value::from(uuid_v7_millis(&request.call_id)))),
        "runtime.random" => {
            let digest = super::compiler::digest(request.call_id.as_bytes());
            let numerator = u64::from_str_radix(&digest[..13], 16).unwrap_or_default();
            let denominator = (1_u64 << 52) as f64;
            Some(Ok(Value::from(numerator as f64 / denominator)))
        }
        _ => None,
    }
}

fn uuid_v7_millis(call_id: &str) -> u64 {
    let Ok(uuid) = Uuid::parse_str(call_id) else {
        return 0;
    };
    let bytes = uuid.as_bytes();
    bytes[..6]
        .iter()
        .fold(0_u64, |value, byte| (value << 8) | u64::from(*byte))
}
