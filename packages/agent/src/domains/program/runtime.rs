//! QuickJS-backed program execution runtime.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rquickjs::{Context, Function, Object, Runtime};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{CausalContext, FunctionId, Invocation};
use crate::shared::server::error_mapping::engine_error_to_capability_error;
use crate::shared::server::errors::CapabilityError;

const DEFAULT_TIMEOUT_MS: u64 = 2_000;
const MAX_TIMEOUT_MS: u64 = 30_000;
const DEFAULT_MEMORY_BYTES: usize = 32 * 1024 * 1024;
const DEFAULT_STACK_BYTES: usize = 512 * 1024;
const DEFAULT_OUTPUT_BYTES: usize = 256 * 1024;
const DEFAULT_LOG_BYTES: usize = 64 * 1024;
const DEFAULT_CHILD_CALLS: usize = 16;
const DEFAULT_RECURSION_DEPTH: usize = 2;

/// A safe, bounded program executor boundary.
pub(crate) trait ProgramExecutor: Send + Sync {
    fn execute(
        &self,
        request: ProgramRunRequest,
        tool_host: Arc<dyn ProgramToolHost>,
    ) -> Result<ProgramRunResult, ProgramRuntimeError>;
}

/// Synchronous host-call surface exposed to QuickJS callbacks.
pub(crate) trait ProgramToolHost: Send + Sync {
    fn call(
        &self,
        primitive: ProgramToolPrimitive,
        payload: Value,
    ) -> Result<Value, ProgramRuntimeError>;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ProgramToolPrimitive {
    Search,
    Inspect,
    Execute,
}

impl ProgramToolPrimitive {
    fn function_id(self) -> &'static str {
        match self {
            Self::Search => "capability::search",
            Self::Inspect => "capability::inspect",
            Self::Execute => "capability::execute",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProgramBudget {
    pub(crate) risk_max: Option<String>,
    pub(crate) memory_bytes: Option<usize>,
    pub(crate) stack_bytes: Option<usize>,
    pub(crate) max_output_bytes: Option<usize>,
    pub(crate) max_log_bytes: Option<usize>,
    pub(crate) max_child_calls: Option<usize>,
    pub(crate) max_recursion_depth: Option<usize>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProgramRunRequest {
    pub(crate) language: String,
    pub(crate) code: String,
    #[serde(default)]
    pub(crate) args: Value,
    #[serde(default)]
    pub(crate) allowed_contracts: Vec<String>,
    #[serde(default)]
    pub(crate) allowed_implementations: Vec<String>,
    pub(crate) timeout_ms: Option<u64>,
    pub(crate) budget: Option<ProgramBudget>,
    pub(crate) idempotency_key: Option<String>,
    pub(crate) reason: Option<String>,
}

impl ProgramRunRequest {
    pub(crate) fn from_payload(payload: &Value) -> Result<Self, CapabilityError> {
        let request: Self = serde_json::from_value(payload.clone()).map_err(|error| {
            CapabilityError::InvalidParams {
                message: format!("invalid JavaScript program request: {error}"),
            }
        })?;
        if request.language != "javascript" {
            return Err(CapabilityError::InvalidParams {
                message: "program execution currently supports language='javascript' only"
                    .to_owned(),
            });
        }
        if request.code.trim().is_empty() {
            return Err(CapabilityError::InvalidParams {
                message: "program code must not be empty".to_owned(),
            });
        }
        Ok(request)
    }

    fn limits(&self) -> ProgramLimits {
        let budget = self.budget.as_ref();
        ProgramLimits {
            timeout_ms: self
                .timeout_ms
                .unwrap_or(DEFAULT_TIMEOUT_MS)
                .clamp(10, MAX_TIMEOUT_MS),
            memory_bytes: budget
                .and_then(|value| value.memory_bytes)
                .unwrap_or(DEFAULT_MEMORY_BYTES)
                .clamp(1024 * 1024, 128 * 1024 * 1024),
            stack_bytes: budget
                .and_then(|value| value.stack_bytes)
                .unwrap_or(DEFAULT_STACK_BYTES)
                .clamp(64 * 1024, 8 * 1024 * 1024),
            max_output_bytes: budget
                .and_then(|value| value.max_output_bytes)
                .unwrap_or(DEFAULT_OUTPUT_BYTES)
                .clamp(1024, 1024 * 1024),
            max_log_bytes: budget
                .and_then(|value| value.max_log_bytes)
                .unwrap_or(DEFAULT_LOG_BYTES)
                .clamp(1024, 1024 * 1024),
            max_child_calls: budget
                .and_then(|value| value.max_child_calls)
                .unwrap_or(DEFAULT_CHILD_CALLS)
                .min(128),
            max_recursion_depth: budget
                .and_then(|value| value.max_recursion_depth)
                .unwrap_or(DEFAULT_RECURSION_DEPTH)
                .min(8),
        }
    }

    pub(crate) fn limits_value(&self) -> Value {
        let limits = self.limits();
        json!({
            "timeoutMs": limits.timeout_ms,
            "memoryBytes": limits.memory_bytes,
            "stackBytes": limits.stack_bytes,
            "maxOutputBytes": limits.max_output_bytes,
            "maxLogBytes": limits.max_log_bytes,
            "maxChildCalls": limits.max_child_calls,
            "maxRecursionDepth": limits.max_recursion_depth,
            "riskMax": self.budget.as_ref().and_then(|budget| budget.risk_max.clone()),
        })
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ProgramLimits {
    timeout_ms: u64,
    memory_bytes: usize,
    stack_bytes: usize,
    max_output_bytes: usize,
    max_log_bytes: usize,
    max_child_calls: usize,
    max_recursion_depth: usize,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProgramRunResult {
    pub(crate) status: String,
    pub(crate) output: Value,
    pub(crate) error: Option<Value>,
    pub(crate) trace_id: String,
    pub(crate) program_run_id: String,
    pub(crate) code_hash: String,
    pub(crate) args_hash: String,
    pub(crate) child_invocations: Vec<String>,
    pub(crate) selected_implementations: Vec<String>,
    pub(crate) approval_state: Option<Value>,
    pub(crate) artifacts: Vec<Value>,
    pub(crate) logs: Vec<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct ProgramRuntimeError {
    pub(crate) code: String,
    pub(crate) message: String,
    pub(crate) details: Option<Value>,
}

impl ProgramRuntimeError {
    pub(super) fn new(code: &str, message: impl Into<String>) -> Self {
        Self {
            code: code.to_owned(),
            message: message.into(),
            details: None,
        }
    }

    pub(super) fn with_details(mut self, details: Value) -> Self {
        self.details = Some(details);
        self
    }
}

#[derive(Default)]
pub(crate) struct QuickJsProgramExecutor;

impl ProgramExecutor for QuickJsProgramExecutor {
    fn execute(
        &self,
        request: ProgramRunRequest,
        tool_host: Arc<dyn ProgramToolHost>,
    ) -> Result<ProgramRunResult, ProgramRuntimeError> {
        let limits = request.limits();
        let code_hash = stable_hash(request.code.as_bytes());
        let args_bytes = serde_json::to_vec(&request.args).unwrap_or_default();
        let args_hash = stable_hash(&args_bytes);
        let program_run_id = format!("program_run_{}", uuid::Uuid::now_v7());
        let trace_id = program_run_id.clone();
        let logs = Arc::new(Mutex::new(Vec::<String>::new()));
        let child_records = Arc::new(Mutex::new(ProgramChildRecords::default()));
        let child_gate = Arc::new(Mutex::new(ProgramChildGate {
            calls: 0,
            max_calls: limits.max_child_calls,
            max_recursion_depth: limits.max_recursion_depth,
        }));

        let runtime = Runtime::new().map_err(|error| js_runtime_error("create runtime", error))?;
        runtime.set_memory_limit(limits.memory_bytes);
        runtime.set_max_stack_size(limits.stack_bytes);
        let deadline = Instant::now() + Duration::from_millis(limits.timeout_ms);
        runtime.set_interrupt_handler(Some(Box::new(move || Instant::now() >= deadline)));
        let context =
            Context::full(&runtime).map_err(|error| js_runtime_error("create context", error))?;

        let output = match context.with(|ctx| {
            let globals = ctx.globals();
            install_host_denials(&globals)?;
            let search_host = tool_host.clone();
            let search_gate = child_gate.clone();
            let search_records = child_records.clone();
            let search = Function::new(ctx.clone(), move |raw: String| {
                host_call_json(
                    search_host.as_ref(),
                    ProgramToolPrimitive::Search,
                    raw,
                    &search_gate,
                    &search_records,
                )
            })?
            .with_name("search")?;
            globals.set("__tronSearchJson", search)?;

            let inspect_host = tool_host.clone();
            let inspect_gate = child_gate.clone();
            let inspect_records = child_records.clone();
            let inspect = Function::new(ctx.clone(), move |raw: String| {
                host_call_json(
                    inspect_host.as_ref(),
                    ProgramToolPrimitive::Inspect,
                    raw,
                    &inspect_gate,
                    &inspect_records,
                )
            })?
            .with_name("inspect")?;
            globals.set("__tronInspectJson", inspect)?;

            let execute_host = tool_host.clone();
            let execute_gate = child_gate.clone();
            let execute_records = child_records.clone();
            let execute = Function::new(ctx.clone(), move |raw: String| {
                host_call_json(
                    execute_host.as_ref(),
                    ProgramToolPrimitive::Execute,
                    raw,
                    &execute_gate,
                    &execute_records,
                )
            })?
            .with_name("execute")?;
            globals.set("__tronExecuteJson", execute)?;

            let log_buffer = logs.clone();
            let max_log_bytes = limits.max_log_bytes;
            let log = Function::new(ctx.clone(), move |raw: String| {
                append_log_json(&log_buffer, max_log_bytes, raw)
            })?
            .with_name("log")?;
            globals.set("__tronLogJson", log)?;

            let prelude = program_prelude();
            ctx.eval::<(), _>(prelude)?;
            let code_json =
                serde_json::to_string(&request.code).unwrap_or_else(|_| "\"\"".to_owned());
            let args_json =
                serde_json::to_string(&request.args).unwrap_or_else(|_| "{}".to_owned());
            let script = format!(
                r#"
                    "use strict";
                    const __tronProgramBody = {code_json};
                    const __tronArgs = JSON.parse({args_json:?});
                    const __tronProgram = new Function("args", __tronProgramBody);
                    const __tronResult = __tronProgram(__tronArgs);
                    JSON.stringify(__tronResult === undefined ? null : __tronResult);
                    "#
            );
            ctx.eval::<String, _>(script.as_str())
        }) {
            Ok(output) => output,
            Err(error) => {
                return Ok(failed_program_result(
                    &program_run_id,
                    &trace_id,
                    &code_hash,
                    &args_hash,
                    &child_records,
                    &logs,
                    js_runtime_error("execute program", error),
                ));
            }
        };

        if output.len() > limits.max_output_bytes {
            return Ok(failed_program_result(
                &program_run_id,
                &trace_id,
                &code_hash,
                &args_hash,
                &child_records,
                &logs,
                ProgramRuntimeError::new(
                    "PROGRAM_OUTPUT_LIMIT_EXCEEDED",
                    format!("program output exceeded {} bytes", limits.max_output_bytes),
                ),
            ));
        }
        let output_value = match serde_json::from_str::<Value>(&output) {
            Ok(value) => value,
            Err(error) => {
                return Ok(failed_program_result(
                    &program_run_id,
                    &trace_id,
                    &code_hash,
                    &args_hash,
                    &child_records,
                    &logs,
                    ProgramRuntimeError::new(
                        "PROGRAM_OUTPUT_INVALID",
                        format!("program output is not JSON: {error}"),
                    ),
                ));
            }
        };
        let records = child_records.lock().map_err(|_| {
            ProgramRuntimeError::new(
                "PROGRAM_STATE_POISONED",
                "program child record mutex poisoned",
            )
        })?;
        let logs = logs.lock().map_err(|_| {
            ProgramRuntimeError::new("PROGRAM_STATE_POISONED", "program log mutex poisoned")
        })?;
        Ok(ProgramRunResult {
            status: "ok".to_owned(),
            output: output_value,
            error: None,
            trace_id,
            program_run_id,
            code_hash,
            args_hash,
            child_invocations: records.child_invocations.clone(),
            selected_implementations: records.selected_implementations.clone(),
            approval_state: records.approval_state.clone(),
            artifacts: Vec::new(),
            logs: logs.clone(),
        })
    }
}

fn failed_program_result(
    program_run_id: &str,
    trace_id: &str,
    code_hash: &str,
    args_hash: &str,
    child_records: &Arc<Mutex<ProgramChildRecords>>,
    logs: &Arc<Mutex<Vec<String>>>,
    error: ProgramRuntimeError,
) -> ProgramRunResult {
    let records = child_records.lock().ok();
    let error = records
        .as_ref()
        .and_then(|records| records.terminal_error.clone())
        .unwrap_or(error);
    let status = program_status_for_error(&error);
    let logs = logs.lock().map(|logs| logs.clone()).unwrap_or_default();
    ProgramRunResult {
        status,
        output: Value::Null,
        error: Some(json!({
            "code": error.code,
            "message": error.message,
            "details": error.details,
        })),
        trace_id: trace_id.to_owned(),
        program_run_id: program_run_id.to_owned(),
        code_hash: code_hash.to_owned(),
        args_hash: args_hash.to_owned(),
        child_invocations: records
            .as_ref()
            .map(|records| records.child_invocations.clone())
            .unwrap_or_default(),
        selected_implementations: records
            .as_ref()
            .map(|records| records.selected_implementations.clone())
            .unwrap_or_default(),
        approval_state: records
            .as_ref()
            .and_then(|records| records.approval_state.clone()),
        artifacts: Vec::new(),
        logs,
    }
}

fn program_status_for_error(error: &ProgramRuntimeError) -> String {
    match error.code.as_str() {
        "PROGRAM_APPROVAL_REQUIRED" => "paused_for_approval".to_owned(),
        "PROGRAM_CONTRACT_NOT_ALLOWED"
        | "PROGRAM_IMPLEMENTATION_NOT_ALLOWED"
        | "PROGRAM_PRIMITIVE_RECURSION_DENIED"
        | "PROGRAM_RISK_BUDGET_EXCEEDED"
        | "PROGRAM_INVALID_RISK_BUDGET" => "policy_denied".to_owned(),
        _ => "failed".to_owned(),
    }
}

#[derive(Default)]
struct ProgramChildRecords {
    child_invocations: Vec<String>,
    selected_implementations: Vec<String>,
    approval_state: Option<Value>,
    terminal_error: Option<ProgramRuntimeError>,
}

struct ProgramChildGate {
    calls: usize,
    max_calls: usize,
    max_recursion_depth: usize,
}

fn host_call_json(
    tool_host: &dyn ProgramToolHost,
    primitive: ProgramToolPrimitive,
    raw: String,
    gate: &Arc<Mutex<ProgramChildGate>>,
    records: &Arc<Mutex<ProgramChildRecords>>,
) -> rquickjs::Result<String> {
    let payload = serde_json::from_str::<Value>(&raw).map_err(|error| {
        rquickjs::Error::new_from_js_message(
            "program",
            "capability",
            format!("tool payload must be JSON: {error}"),
        )
    })?;
    {
        let mut gate = gate.lock().map_err(|_| {
            rquickjs::Error::new_from_js_message(
                "program",
                "capability",
                "child-call gate poisoned",
            )
        })?;
        if gate.calls >= gate.max_calls {
            return Err(rquickjs::Error::new_from_js_message(
                "program",
                "capability",
                "program child-call limit exceeded",
            ));
        }
        if primitive == ProgramToolPrimitive::Execute
            && payload.get("mode").and_then(Value::as_str) == Some("program")
            && gate.max_recursion_depth == 0
        {
            return Err(rquickjs::Error::new_from_js_message(
                "program",
                "capability",
                "program recursion depth exceeded",
            ));
        }
        gate.calls += 1;
    }
    let value = tool_host.call(primitive, payload).map_err(|error| {
        record_terminal_error(records, error.clone());
        rquickjs::Error::new_from_js_message(
            "program",
            "capability",
            format!("{}: {}", error.code, error.message),
        )
    })?;
    record_child_result(records, &value);
    serde_json::to_string(&value).map_err(|error| {
        rquickjs::Error::new_from_js_message(
            "program",
            "capability",
            format!("tool result is not JSON serializable: {error}"),
        )
    })
}

fn record_terminal_error(records: &Arc<Mutex<ProgramChildRecords>>, error: ProgramRuntimeError) {
    if let Ok(mut records) = records.lock() {
        records.terminal_error = Some(error);
    }
}

fn record_child_result(records: &Arc<Mutex<ProgramChildRecords>>, value: &Value) {
    let Some(details) = value.get("details").or_else(|| value.get("detailsJson")) else {
        return;
    };
    let mut records = match records.lock() {
        Ok(records) => records,
        Err(_) => return,
    };
    if let Some(invocations) = details.get("childInvocations").and_then(Value::as_array) {
        for id in invocations.iter().filter_map(Value::as_str) {
            if !records
                .child_invocations
                .iter()
                .any(|existing| existing == id)
            {
                records.child_invocations.push(id.to_owned());
            }
        }
    }
    if let Some(selected) = details
        .get("selectedImplementation")
        .and_then(Value::as_str)
        && !records
            .selected_implementations
            .iter()
            .any(|existing| existing == selected)
    {
        records.selected_implementations.push(selected.to_owned());
    }
    if let Some(approval) = details.get("approvalState") {
        records.approval_state = Some(approval.clone());
    }
}

fn append_log_json(
    buffer: &Arc<Mutex<Vec<String>>>,
    max_log_bytes: usize,
    raw: String,
) -> rquickjs::Result<()> {
    let mut buffer = buffer.lock().map_err(|_| {
        rquickjs::Error::new_from_js_message("program", "console", "program log mutex poisoned")
    })?;
    let current_bytes = buffer.iter().map(String::len).sum::<usize>();
    if current_bytes.saturating_add(raw.len()) > max_log_bytes {
        return Err(rquickjs::Error::new_from_js_message(
            "program",
            "console",
            "program log limit exceeded",
        ));
    }
    buffer.push(raw);
    Ok(())
}

fn install_host_denials(globals: &Object<'_>) -> rquickjs::Result<()> {
    for name in [
        "fetch",
        "WebSocket",
        "XMLHttpRequest",
        "process",
        "require",
        "Deno",
        "Bun",
        "Date",
        "performance",
        "crypto",
        "importScripts",
    ] {
        globals.set(name, rquickjs::Value::new_undefined(globals.ctx().clone()))?;
    }
    Ok(())
}

fn program_prelude() -> &'static str {
    r#"
    const __tronParse = (value) => value === undefined ? {} : value;
    const __tronCall = (name, value) => JSON.parse(globalThis[name](JSON.stringify(__tronParse(value))));
    const __tronLog = (...values) => globalThis.__tronLogJson(JSON.stringify(values));
    const tools = Object.freeze({
      search(input) { return __tronCall("__tronSearchJson", input); },
      inspect(input) { return __tronCall("__tronInspectJson", input); },
      execute(input) { return __tronCall("__tronExecuteJson", input); }
    });
    Object.defineProperty(globalThis, "tools", { value: tools, writable: false, configurable: false });
    Object.defineProperty(globalThis, "console", { value: Object.freeze({ log: __tronLog }), writable: false, configurable: false });
    "#
}

fn js_runtime_error(stage: &str, error: rquickjs::Error) -> ProgramRuntimeError {
    ProgramRuntimeError::new("PROGRAM_RUNTIME_ERROR", format!("{stage}: {error}"))
}

pub(super) fn stable_hash(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub(super) fn failed_result_for_request(
    request: &ProgramRunRequest,
    status: &str,
    error: ProgramRuntimeError,
) -> ProgramRunResult {
    let args_bytes = serde_json::to_vec(&request.args).unwrap_or_default();
    let program_run_id = format!("program_run_{}", uuid::Uuid::now_v7());
    ProgramRunResult {
        status: status.to_owned(),
        output: Value::Null,
        error: Some(json!({
            "code": error.code,
            "message": error.message,
            "details": error.details,
        })),
        trace_id: program_run_id.clone(),
        program_run_id,
        code_hash: stable_hash(request.code.as_bytes()),
        args_hash: stable_hash(&args_bytes),
        child_invocations: Vec::new(),
        selected_implementations: Vec::new(),
        approval_state: None,
        artifacts: Vec::new(),
        logs: Vec::new(),
    }
}

pub(crate) struct EngineProgramToolHost {
    engine_host: crate::engine::EngineHostHandle,
    causal_context: CausalContext,
    allowed_contracts: Vec<String>,
    allowed_implementations: Vec<String>,
    budget: Option<ProgramBudget>,
    runtime: tokio::runtime::Handle,
}

impl EngineProgramToolHost {
    pub(crate) fn new(
        engine_host: crate::engine::EngineHostHandle,
        causal_context: CausalContext,
        allowed_contracts: Vec<String>,
        allowed_implementations: Vec<String>,
        budget: Option<ProgramBudget>,
        runtime: tokio::runtime::Handle,
    ) -> Self {
        Self {
            engine_host,
            causal_context,
            allowed_contracts,
            allowed_implementations,
            budget,
            runtime,
        }
    }

    fn enforce_execute_policy(&self, payload: &Value) -> Result<(), ProgramRuntimeError> {
        if payload.get("mode").and_then(Value::as_str) == Some("program") {
            return Err(ProgramRuntimeError::new(
                "PROGRAM_PRIMITIVE_RECURSION_DENIED",
                "programs cannot recursively invoke execute mode 'program'",
            ));
        }
        let target = payload
            .get("contractId")
            .or_else(|| payload.get("contract_id"))
            .or_else(|| payload.get("implementationId"))
            .or_else(|| payload.get("implementation_id"))
            .or_else(|| payload.get("functionId"))
            .or_else(|| payload.get("function_id"))
            .and_then(Value::as_str)
            .unwrap_or_default();
        if target.starts_with("capability::") {
            return Err(ProgramRuntimeError::new(
                "PROGRAM_PRIMITIVE_RECURSION_DENIED",
                "programs cannot execute capability primitives through tools.execute",
            ));
        }
        if let Some(contract) = payload
            .get("contractId")
            .or_else(|| payload.get("contract_id"))
            .and_then(Value::as_str)
            && !self.allowed_contracts.is_empty()
            && !self
                .allowed_contracts
                .iter()
                .any(|allowed| allowed == contract)
        {
            return Err(ProgramRuntimeError::new(
                "PROGRAM_CONTRACT_NOT_ALLOWED",
                format!("program is not allowed to execute contract {contract}"),
            ));
        }
        if let Some(implementation) = payload
            .get("implementationId")
            .or_else(|| payload.get("implementation_id"))
            .and_then(Value::as_str)
            && !self.allowed_implementations.is_empty()
            && !self
                .allowed_implementations
                .iter()
                .any(|allowed| allowed == implementation)
        {
            return Err(ProgramRuntimeError::new(
                "PROGRAM_IMPLEMENTATION_NOT_ALLOWED",
                format!("program is not allowed to execute implementation {implementation}"),
            ));
        }
        self.enforce_risk_budget(payload)?;
        Ok(())
    }

    fn enforce_risk_budget(&self, payload: &Value) -> Result<(), ProgramRuntimeError> {
        let Some(max_risk) = self
            .budget
            .as_ref()
            .and_then(|budget| budget.risk_max.as_deref())
        else {
            return Ok(());
        };
        let Some(inspect_payload) = inspect_payload_for_execute(payload) else {
            return Ok(());
        };
        let max_rank = risk_budget_rank(max_risk).ok_or_else(|| {
            ProgramRuntimeError::new(
                "PROGRAM_INVALID_RISK_BUDGET",
                format!("unsupported program risk budget '{max_risk}'"),
            )
        })?;
        let inspection = self.invoke_primitive(ProgramToolPrimitive::Inspect, inspect_payload)?;
        let details = inspection
            .get("details")
            .or_else(|| inspection.get("detailsJson"))
            .unwrap_or(&inspection);
        let risk = details
            .pointer("/contract/riskLevel")
            .or_else(|| details.pointer("/implementation/riskLevel"))
            .and_then(Value::as_str)
            .unwrap_or("critical");
        let actual_rank = risk_budget_rank(risk).unwrap_or(usize::MAX);
        if actual_rank > max_rank {
            return Err(ProgramRuntimeError::new(
                "PROGRAM_RISK_BUDGET_EXCEEDED",
                format!("child capability risk '{risk}' exceeds program riskMax '{max_risk}'"),
            )
            .with_details(json!({
                "riskMax": max_risk,
                "childRisk": risk,
                "inspection": details,
            })));
        }
        Ok(())
    }

    fn invoke_primitive(
        &self,
        primitive: ProgramToolPrimitive,
        payload: Value,
    ) -> Result<Value, ProgramRuntimeError> {
        let function_id = FunctionId::new(primitive.function_id()).map_err(|error| {
            ProgramRuntimeError::new("PROGRAM_HOST_INVALID_FUNCTION", error.to_string())
        })?;
        let invocation = Invocation::new_sync(function_id, payload, self.causal_context.clone());
        let result = self.runtime.block_on(self.engine_host.invoke(invocation));
        if let Some(error) = result.error {
            let mapped = engine_error_to_capability_error(error);
            return Err(ProgramRuntimeError::new(
                "PROGRAM_CHILD_CAPABILITY_FAILED",
                mapped.to_string(),
            ));
        }
        Ok(result.value.unwrap_or(Value::Null))
    }
}

fn inspect_payload_for_execute(payload: &Value) -> Option<Value> {
    let mut object = serde_json::Map::new();
    for (camel, snake) in [
        ("capabilityId", "capability_id"),
        ("contractId", "contract_id"),
        ("implementationId", "implementation_id"),
        ("functionId", "function_id"),
    ] {
        if let Some(value) = payload.get(camel).or_else(|| payload.get(snake)).cloned() {
            object.insert(camel.to_owned(), value);
        }
    }
    (!object.is_empty()).then(|| Value::Object(object))
}

fn risk_budget_rank(risk: &str) -> Option<usize> {
    match risk {
        "Low" | "low" => Some(0),
        "Medium" | "medium" => Some(1),
        "High" | "high" => Some(2),
        "Critical" | "critical" => Some(3),
        _ => None,
    }
}

impl ProgramToolHost for EngineProgramToolHost {
    fn call(
        &self,
        primitive: ProgramToolPrimitive,
        payload: Value,
    ) -> Result<Value, ProgramRuntimeError> {
        if primitive == ProgramToolPrimitive::Execute {
            self.enforce_execute_policy(&payload)?;
        }
        let value = self.invoke_primitive(primitive, payload)?;
        if primitive == ProgramToolPrimitive::Execute
            && value
                .get("details")
                .and_then(|details| details.get("approvalState"))
                .is_some()
        {
            return Err(ProgramRuntimeError::new(
                "PROGRAM_APPROVAL_REQUIRED",
                "child capability requires approval; program execution is paused",
            )
            .with_details(value));
        }
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[derive(Default)]
    struct EchoHost;

    impl ProgramToolHost for EchoHost {
        fn call(
            &self,
            primitive: ProgramToolPrimitive,
            payload: Value,
        ) -> Result<Value, ProgramRuntimeError> {
            Ok(json!({
                "primitive": format!("{:?}", primitive),
                "payload": payload,
                "details": {
                    "childInvocations": ["child-1"],
                    "selectedImplementation": "first_party.test.v1.echo"
                }
            }))
        }
    }

    fn run(code: &str) -> Result<ProgramRunResult, ProgramRuntimeError> {
        QuickJsProgramExecutor.execute(
            ProgramRunRequest {
                language: "javascript".to_owned(),
                code: code.to_owned(),
                args: json!({"name": "tron"}),
                allowed_contracts: Vec::new(),
                allowed_implementations: Vec::new(),
                timeout_ms: Some(500),
                budget: Some(ProgramBudget {
                    risk_max: None,
                    memory_bytes: Some(8 * 1024 * 1024),
                    stack_bytes: Some(256 * 1024),
                    max_output_bytes: Some(16 * 1024),
                    max_log_bytes: Some(16 * 1024),
                    max_child_calls: Some(4),
                    max_recursion_depth: Some(0),
                }),
                idempotency_key: Some("test-key".to_owned()),
                reason: None,
            },
            Arc::new(EchoHost),
        )
    }

    #[test]
    fn javascript_program_returns_json_output() {
        let result = run(r#"return { greeting: args.name };"#).expect("program");
        assert_eq!(result.output, json!({"greeting": "tron"}));
    }

    #[test]
    fn javascript_program_can_call_frozen_tools_host_surface() {
        let result = run(r#"return tools.search({ query: "read" });"#).expect("program");
        assert_eq!(result.output["primitive"], "Search");
        assert_eq!(result.child_invocations, vec!["child-1"]);
        assert_eq!(
            result.selected_implementations,
            vec!["first_party.test.v1.echo"]
        );
    }

    #[test]
    fn javascript_program_denies_host_objects() {
        let result =
            run(r#"return { fetch: typeof fetch, process: typeof process, date: typeof Date };"#)
                .expect("program");
        assert_eq!(
            result.output,
            json!({"fetch": "undefined", "process": "undefined", "date": "undefined"})
        );
    }

    #[test]
    fn javascript_program_interrupts_runaway_loops() {
        let result = run(r#"while (true) {}"#).expect("program record");
        assert_eq!(result.status, "failed");
        assert_eq!(
            result
                .error
                .as_ref()
                .and_then(|error| error["code"].as_str()),
            Some("PROGRAM_RUNTIME_ERROR")
        );
    }

    #[test]
    fn javascript_program_enforces_child_call_limit() {
        let result = run(r#"
            tools.search({ query: "one" });
            tools.search({ query: "two" });
            tools.search({ query: "three" });
            tools.search({ query: "four" });
            tools.search({ query: "five" });
            return null;
            "#)
        .expect("program record");
        assert_eq!(result.status, "failed");
        assert_eq!(result.child_invocations, vec!["child-1"]);
        assert_eq!(
            result
                .error
                .as_ref()
                .and_then(|error| error["code"].as_str()),
            Some("PROGRAM_RUNTIME_ERROR")
        );
    }
}
