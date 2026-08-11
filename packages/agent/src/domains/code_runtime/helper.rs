//! Versioned stdio protocol for the disposable QuickJS helper process.
//!
//! The server sends one compiled evaluation. Broker calls are emitted as
//! request messages and must be durably admitted by the server before it sends
//! the matching response. The helper has no store and no authority of its own;
//! killing it is the cancellation backstop. A fresh helper can replay the same
//! journal without changing logical runtime identity.

use std::cell::RefCell;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use rquickjs::context::intrinsic;
use rquickjs::function::{Func, MutFn};
use rquickjs::promise::MaybePromise;
use rquickjs::{Context, Error as JsError, Function, Module, Runtime, Value as JsValue};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use thiserror::Error;

use super::compiler::capture_candidate_result;
use super::evaluator::SDK_BOOTSTRAP;
use super::types::RuntimeLimits;

/// Protocol ABI.
pub const HELPER_PROTOCOL_VERSION: u32 = 1;

/// Initial server-to-helper command.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum HelperCommand {
    /// Evaluate type-stripped committed source followed by the candidate.
    Evaluate {
        /// Must equal [`HELPER_PROTOCOL_VERSION`].
        version: u32,
        /// Correlation id copied into every message.
        request_id: String,
        /// Successful historical cells assembled in sequence order.
        committed_source: String,
        /// Current compiled candidate cell.
        candidate_source: String,
        /// Physical execution bounds.
        limits: RuntimeLimits,
    },
    /// Invoke one digest-pinned skill module in a fresh authority-empty VM.
    InvokeSkill {
        /// Must equal [`HELPER_PROTOCOL_VERSION`].
        version: u32,
        /// Correlation id copied into every message.
        request_id: String,
        /// Stable synthetic ES module name.
        module_name: String,
        /// Type-stripped module with exactly one default export.
        module_source: String,
        /// JSON-safe module input.
        input: Value,
        /// Physical execution bounds.
        limits: RuntimeLimits,
    },
}

/// Helper-to-server output.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum HelperEvent {
    /// Nested broker request. The server journals before replying.
    BrokerRequest {
        /// Protocol ABI.
        version: u32,
        /// Evaluation correlation.
        request_id: String,
        /// Monotonic call ordinal across replay and candidate execution.
        ordinal: u64,
        /// Versioned operation.
        operation: String,
        /// JSON request.
        input: Value,
    },
    /// Terminal evaluation result.
    Complete {
        /// Protocol ABI.
        version: u32,
        /// Evaluation correlation.
        request_id: String,
        /// Whether evaluation succeeded.
        ok: bool,
        /// JSON-safe result on success.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        value: Option<Value>,
        /// Candidate console output.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        output: Vec<String>,
        /// Bounded failure on error.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
}

/// Server response to one nested broker event.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum HelperBrokerResponse {
    /// Matching durable result/failure.
    BrokerResponse {
        /// Protocol ABI.
        version: u32,
        /// Evaluation correlation.
        request_id: String,
        /// Exact request ordinal.
        ordinal: u64,
        /// Result on success.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        value: Option<Value>,
        /// Failure on error.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
}

/// Helper protocol/process failure.
#[derive(Debug, Error)]
pub enum HelperError {
    /// Stdio read/write failed.
    #[error("helper I/O failed: {0}")]
    Io(#[from] std::io::Error),
    /// The peer violated versioning, framing, or correlation.
    #[error("invalid helper protocol: {0}")]
    Protocol(String),
    /// QuickJS rejected or interrupted the assembled module.
    #[error("helper JavaScript failed: {0}")]
    JavaScript(String),
}

/// Run one helper command over stdin/stdout and exit.
pub fn run_stdio() -> Result<(), HelperError> {
    let input = Rc::new(RefCell::new(BufReader::new(std::io::stdin())));
    let output = Rc::new(RefCell::new(BufWriter::new(std::io::stdout())));
    let mut command_line = String::new();
    input.borrow_mut().read_line(&mut command_line)?;
    let command: HelperCommand = serde_json::from_str(&command_line)
        .map_err(|error| HelperError::Protocol(error.to_string()))?;
    let (version, request_id, result) = match command {
        HelperCommand::Evaluate {
            version,
            request_id,
            committed_source,
            candidate_source,
            limits,
        } => {
            if version != HELPER_PROTOCOL_VERSION {
                return Err(HelperError::Protocol(format!(
                    "unsupported version {version}"
                )));
            }
            let result = evaluate_over_stdio(
                &request_id,
                &committed_source,
                &candidate_source,
                &limits,
                input,
                output.clone(),
            );
            (version, request_id, result)
        }
        HelperCommand::InvokeSkill {
            version,
            request_id,
            module_name,
            module_source,
            input: module_input,
            limits,
        } => {
            if version != HELPER_PROTOCOL_VERSION {
                return Err(HelperError::Protocol(format!(
                    "unsupported version {version}"
                )));
            }
            let result = invoke_skill_over_stdio(
                &request_id,
                &module_name,
                &module_source,
                &module_input,
                &limits,
                input,
                output.clone(),
            );
            (version, request_id, result)
        }
    };
    let event = match result {
        Ok((value, logs)) => HelperEvent::Complete {
            version,
            request_id,
            ok: true,
            value: Some(value),
            output: logs,
            error: None,
        },
        Err(error) => HelperEvent::Complete {
            version,
            request_id,
            ok: false,
            value: None,
            output: Vec::new(),
            error: Some(error.to_string()),
        },
    };
    write_message(&mut *output.borrow_mut(), &event)
}

fn evaluate_over_stdio(
    request_id: &str,
    committed_source: &str,
    candidate_source: &str,
    limits: &RuntimeLimits,
    input: Rc<RefCell<BufReader<std::io::Stdin>>>,
    output: Rc<RefCell<BufWriter<std::io::Stdout>>>,
) -> Result<(Value, Vec<String>), HelperError> {
    let runtime = Runtime::new().map_err(|error| HelperError::JavaScript(error.to_string()))?;
    runtime.set_memory_limit(limits.memory_bytes);
    runtime.set_max_stack_size(limits.stack_bytes);
    let deadline = Instant::now() + Duration::from_millis(limits.wall_time_ms);
    let timed_out = Arc::new(AtomicBool::new(false));
    let interrupt_timed_out = timed_out.clone();
    runtime.set_interrupt_handler(Some(Box::new(move || {
        if Instant::now() >= deadline {
            interrupt_timed_out.store(true, Ordering::Relaxed);
            true
        } else {
            false
        }
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
        .map_err(|error| HelperError::JavaScript(error.to_string()))?;
    let logs = Rc::new(RefCell::new(Vec::new()));
    let ordinal = Rc::new(RefCell::new(0_u64));
    let request_id = request_id.to_owned();

    let evaluated: Result<Value, JsError> = context.with(|ctx| {
        let call_input = input.clone();
        let call_output = output.clone();
        let call_request_id = request_id.clone();
        let call_ordinal = ordinal.clone();
        ctx.globals().set(
            "__tronNativeCall",
            Func::from(MutFn::from(move |operation: String, encoded: String| {
                let input: Value = serde_json::from_str(&encoded).map_err(|error| {
                    JsError::new_from_js_message("JSON", "broker input", error.to_string())
                })?;
                let current = *call_ordinal.borrow();
                *call_ordinal.borrow_mut() = current.saturating_add(1);
                let event = HelperEvent::BrokerRequest {
                    version: HELPER_PROTOCOL_VERSION,
                    request_id: call_request_id.clone(),
                    ordinal: current,
                    operation,
                    input,
                };
                write_message(&mut *call_output.borrow_mut(), &event).map_err(|error| {
                    JsError::new_from_js_message("helper", "broker", error.to_string())
                })?;
                let mut response_line = String::new();
                call_input
                    .borrow_mut()
                    .read_line(&mut response_line)
                    .map_err(|error| {
                        JsError::new_from_js_message("broker", "helper", error.to_string())
                    })?;
                let response: HelperBrokerResponse =
                    serde_json::from_str(&response_line).map_err(|error| {
                        JsError::new_from_js_message("broker", "helper", error.to_string())
                    })?;
                let HelperBrokerResponse::BrokerResponse {
                    version,
                    request_id,
                    ordinal,
                    value,
                    error,
                } = response;
                if version != HELPER_PROTOCOL_VERSION
                    || request_id != call_request_id
                    || ordinal != current
                {
                    return Err(JsError::new_from_js_message(
                        "broker",
                        "helper",
                        "broker response correlation mismatch",
                    ));
                }
                if let Some(error) = error {
                    return Err(JsError::new_from_js_message("broker", "JavaScript", error));
                }
                serde_json::to_string(&value.unwrap_or(Value::Null)).map_err(|error| {
                    JsError::new_from_js_message("broker", "JSON", error.to_string())
                })
            })),
        )?;
        let log_output = logs.clone();
        let max_output = limits.max_output_bytes;
        ctx.globals().set(
            "__tronNativeLog",
            Func::from(MutFn::from(move |message: String| {
                let bytes = log_output.borrow().iter().map(String::len).sum::<usize>();
                if bytes.saturating_add(message.len()) > max_output {
                    return Err(JsError::new_from_js_message(
                        "console",
                        "JavaScript",
                        "output limit exceeded",
                    ));
                }
                log_output.borrow_mut().push(message);
                Ok(())
            })),
        )?;
        let candidate_logs = logs.clone();
        ctx.globals().set(
            "__tronNativeCandidate",
            Func::from(MutFn::from(move || -> rquickjs::Result<()> {
                candidate_logs.borrow_mut().clear();
                Ok(())
            })),
        )?;
        ctx.eval_promise(SDK_BOOTSTRAP)?.finish::<()>()?;
        let candidate = capture_candidate_result(candidate_source).map_err(|error| {
            JsError::new_from_js_message("candidate", "JavaScript", error.to_string())
        })?;
        let assembled = format!(
            "const __tronCandidate = globalThis.__tronNativeCandidate;\n\
             delete globalThis.__tronNativeCandidate;\n\
             {committed_source}\n;\n\
             __tronCandidate();\n\
             {candidate}"
        );
        Module::evaluate(ctx.clone(), "runtime-helper.mjs", assembled)?.finish::<()>()?;
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
    });
    match evaluated {
        Ok(value) => Ok((value, logs.borrow().clone())),
        Err(_) if timed_out.load(Ordering::Relaxed) => {
            Err(HelperError::JavaScript("evaluation timed out".to_owned()))
        }
        Err(error) => Err(HelperError::JavaScript(error.to_string())),
    }
}

#[allow(clippy::too_many_arguments)]
fn invoke_skill_over_stdio(
    request_id: &str,
    module_name: &str,
    module_source: &str,
    module_input: &Value,
    limits: &RuntimeLimits,
    input: Rc<RefCell<BufReader<std::io::Stdin>>>,
    output: Rc<RefCell<BufWriter<std::io::Stdout>>>,
) -> Result<(Value, Vec<String>), HelperError> {
    let runtime = Runtime::new().map_err(|error| HelperError::JavaScript(error.to_string()))?;
    runtime.set_memory_limit(limits.memory_bytes);
    runtime.set_max_stack_size(limits.stack_bytes);
    let deadline = Instant::now() + Duration::from_millis(limits.wall_time_ms);
    let timed_out = Arc::new(AtomicBool::new(false));
    let interrupt_timed_out = timed_out.clone();
    runtime.set_interrupt_handler(Some(Box::new(move || {
        if Instant::now() >= deadline {
            interrupt_timed_out.store(true, Ordering::Relaxed);
            true
        } else {
            false
        }
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
        .map_err(|error| HelperError::JavaScript(error.to_string()))?;
    let logs = Rc::new(RefCell::new(Vec::new()));
    let ordinal = Rc::new(RefCell::new(0_u64));
    let request_id = request_id.to_owned();

    let evaluated: Result<Value, JsError> = context.with(|ctx| {
        let call_input = input.clone();
        let call_output = output.clone();
        let call_request_id = request_id.clone();
        let call_ordinal = ordinal.clone();
        ctx.globals().set(
            "__tronNativeCall",
            Func::from(MutFn::from(move |operation: String, encoded: String| {
                let input: Value = serde_json::from_str(&encoded).map_err(|error| {
                    JsError::new_from_js_message("JSON", "broker input", error.to_string())
                })?;
                let current = *call_ordinal.borrow();
                *call_ordinal.borrow_mut() = current.saturating_add(1);
                let event = HelperEvent::BrokerRequest {
                    version: HELPER_PROTOCOL_VERSION,
                    request_id: call_request_id.clone(),
                    ordinal: current,
                    operation,
                    input,
                };
                write_message(&mut *call_output.borrow_mut(), &event).map_err(|error| {
                    JsError::new_from_js_message("helper", "broker", error.to_string())
                })?;
                let mut response_line = String::new();
                call_input
                    .borrow_mut()
                    .read_line(&mut response_line)
                    .map_err(|error| {
                        JsError::new_from_js_message("broker", "helper", error.to_string())
                    })?;
                let response: HelperBrokerResponse =
                    serde_json::from_str(&response_line).map_err(|error| {
                        JsError::new_from_js_message("broker", "helper", error.to_string())
                    })?;
                let HelperBrokerResponse::BrokerResponse {
                    version,
                    request_id,
                    ordinal,
                    value,
                    error,
                } = response;
                if version != HELPER_PROTOCOL_VERSION
                    || request_id != call_request_id
                    || ordinal != current
                {
                    return Err(JsError::new_from_js_message(
                        "broker",
                        "helper",
                        "broker response correlation mismatch",
                    ));
                }
                if let Some(error) = error {
                    return Err(JsError::new_from_js_message("broker", "JavaScript", error));
                }
                serde_json::to_string(&value.unwrap_or(Value::Null)).map_err(|error| {
                    JsError::new_from_js_message("broker", "JSON", error.to_string())
                })
            })),
        )?;
        let log_output = logs.clone();
        let max_output = limits.max_output_bytes;
        ctx.globals().set(
            "__tronNativeLog",
            Func::from(MutFn::from(move |message: String| {
                let bytes = log_output.borrow().iter().map(String::len).sum::<usize>();
                if bytes.saturating_add(message.len()) > max_output {
                    return Err(JsError::new_from_js_message(
                        "console",
                        "JavaScript",
                        "output limit exceeded",
                    ));
                }
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
        let module = Module::declare(ctx.clone(), module_name, module_source)?;
        let (module, promise) = module.eval()?;
        promise.finish::<()>()?;
        let callable: Function<'_> = module.get("default")?;
        let capabilities: JsValue<'_> = ctx.globals().get("__tronSkillCapabilities")?;
        let encoded_input = serde_json::to_string(module_input).map_err(|error| {
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
    });
    match evaluated {
        Ok(value) => Ok((value, logs.borrow().clone())),
        Err(_) if timed_out.load(Ordering::Relaxed) => {
            Err(HelperError::JavaScript("evaluation timed out".to_owned()))
        }
        Err(error) => Err(HelperError::JavaScript(error.to_string())),
    }
}

fn write_message(writer: &mut impl Write, value: &impl Serialize) -> Result<(), HelperError> {
    serde_json::to_writer(&mut *writer, value)
        .map_err(|error| HelperError::Protocol(error.to_string()))?;
    writer.write_all(b"\n")?;
    writer.flush()?;
    Ok(())
}
