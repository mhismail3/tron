//! Native interactive terminal custody for authenticated Tron clients.
//!
//! This fixed domain owns PTY process lifecycle, ordered input/output, bounded
//! replay, and authoritative session-directory resolution. It is deliberately
//! native-client-only and has no model-tool contract: adaptive interpretation
//! of terminal output belongs in workers, while byte custody must remain
//! deterministic.
//!
//! | Module | Responsibility |
//! | --- | --- |
//! | [`journal`] | Mode-private ordered replay records and bounded vt100 checkpoints. |
//!
//! The module root owns process lifecycle, typed native-client contracts, and
//! session cleanup because those invariants share the live PTY registry.

use std::collections::{HashSet, VecDeque};
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use base64::Engine as _;
use portable_pty::{CommandBuilder, MasterPty, PtySize};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::broadcast;

use crate::domains::registration::bindings::operation_bindings;
use crate::domains::registration::composition::{
    DomainFunctionRegistration, DomainRegistrationContext,
};
use crate::domains::registration::contract::FunctionContract;
use crate::domains::session::event_store::{EventStore, TerminalRecord};
use crate::engine::{
    EffectClass, FunctionDefinition, FunctionVisibility, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};
use crate::shared::foundation::paths;
use crate::shared::server::errors::ToolError;

mod journal;

use journal::{
    append_journal, private_dir, read_journal, replace_journal, replace_private_file, retained,
    terminal_snapshot,
};

const MAX_ACTIVE_TERMINALS: usize = 8;
const MAX_REPLAY_BYTES: usize = 64 * 1024 * 1024;
const MAX_INPUT_BYTES: usize = 64 * 1024;
const MAX_OUTPUT_CHUNK: usize = 32 * 1024;
const CHECKPOINT_INTERVAL_BYTES: usize = 1024 * 1024;

/// Authenticated client capability negotiated during `hello`.
pub const CAPABILITY: &str = "terminal.v1";

/// One durably sequenced PTY output chunk.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalChunk {
    /// Stable terminal identifier.
    pub terminal_id: String,
    /// PTY launch generation.
    pub generation: u64,
    /// Monotonic output sequence.
    pub sequence: u64,
    /// Exact PTY bytes.
    pub data_base64: String,
}

/// Live attachment notification.
#[derive(Clone, Debug)]
pub enum TerminalStreamEvent {
    /// New ordered PTY bytes.
    Output(TerminalChunk),
    /// Terminal process state changed.
    Status {
        /// Stable terminal identifier.
        terminal_id: String,
        /// PTY launch generation.
        generation: u64,
        /// New process state.
        state: String,
        /// Process exit code when known.
        exit_code: Option<i32>,
    },
}

struct LiveTerminal {
    id: String,
    session_id: String,
    generation: u64,
    master: Mutex<Box<dyn MasterPty + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    killer: Mutex<Box<dyn portable_pty::ChildKiller + Send + Sync>>,
    state: Mutex<LiveState>,
    events: broadcast::Sender<TerminalStreamEvent>,
    journal_path: PathBuf,
    checkpoint_path: PathBuf,
    reader_done: (Mutex<bool>, Condvar),
}

struct LiveState {
    rows: u16,
    columns: u16,
    next_sequence: u64,
    replay: VecDeque<TerminalChunk>,
    replay_bytes: usize,
    accepted_inputs: HashSet<String>,
    accepted_input_order: VecDeque<String>,
    running: bool,
    parser: vt100::Parser,
    bytes_since_checkpoint: usize,
    last_metadata_update: Instant,
}

/// Atomic replay snapshot followed by a subscribed live receiver.
pub struct TerminalAttachment {
    /// Retained chunks after the requested sequence.
    pub backlog: Vec<TerminalChunk>,
    /// Live output/status receiver installed before the snapshot was read.
    pub receiver: Option<broadcast::Receiver<TerminalStreamEvent>>,
    /// Oldest replayable output sequence.
    pub earliest_sequence: u64,
    /// Newest output sequence at attachment time.
    pub latest_sequence: u64,
    /// PTY launch generation.
    pub generation: u64,
    /// Process state at attachment time.
    pub state: String,
    /// Exit code for retained history when known.
    pub exit_code: Option<i32>,
}

/// Shared terminal registry. One instance belongs to one server runtime.
pub struct TerminalService {
    event_store: Arc<EventStore>,
    live: dashmap::DashMap<String, Arc<LiveTerminal>>,
    root: PathBuf,
    open_lock: tokio::sync::Mutex<()>,
}

impl TerminalService {
    /// Create the terminal service in the runtime-owned private storage root.
    pub fn new(event_store: Arc<EventStore>) -> Arc<Self> {
        Self::new_with_root(event_store, paths::terminal_dir())
    }

    /// Create a terminal service with explicit filesystem custody.
    ///
    /// Embedders and isolated server harnesses use this constructor so terminal
    /// journals share the same resolved Tron home as the rest of their runtime.
    pub fn new_with_root(event_store: Arc<EventStore>, root: PathBuf) -> Arc<Self> {
        if let Err(error) = private_dir(&root) {
            tracing::warn!(%error, "terminal storage initialization failed");
        }
        if let Err(error) = event_store.interrupt_running_terminals() {
            tracing::warn!(%error, "terminal restart reconciliation failed");
        }
        let service = Arc::new(Self {
            event_store,
            live: dashmap::DashMap::new(),
            root,
            open_lock: tokio::sync::Mutex::new(()),
        });
        service.purge_expired();
        service
    }

    /// Wire capabilities exposed during the authenticated hello handshake.
    pub fn capabilities(&self) -> &'static [&'static str] {
        &[CAPABILITY]
    }

    /// List live and retained terminal launches for one session.
    pub fn list(&self, session_id: &str) -> Result<Value, ToolError> {
        self.ensure_session(session_id)?;
        let records = self
            .event_store
            .list_terminals(session_id)
            .map_err(internal)?;
        Ok(json!({"terminals":records.iter().map(record_json).collect::<Vec<_>>() }))
    }

    /// Return the session's live terminal or atomically start its login shell.
    pub async fn open(
        self: &Arc<Self>,
        session_id: &str,
        rows: u16,
        columns: u16,
    ) -> Result<Value, ToolError> {
        validate_size(rows, columns)?;
        let _open_guard = self.open_lock.lock().await;
        if let Some(existing) = self
            .live
            .iter()
            .find(|item| item.session_id == session_id)
            .map(|item| item.clone())
        {
            return Ok(json!({"terminal":self.live_json(&existing)}));
        }
        if self.live.len() >= MAX_ACTIVE_TERMINALS {
            return Err(invalid(
                "the server already has the maximum number of active terminals",
            ));
        }
        let session = self.ensure_session(session_id)?;
        let cwd = paths::normalize_working_directory(&session.working_directory)
            .map_err(|message| invalid(&message))?;
        let shell = resolve_shell()?;
        let id = format!("term_{}", uuid::Uuid::now_v7().simple());
        let generation = 1;
        let terminal_root = self.root.join(&id);
        private_dir(&terminal_root).map_err(internal_string)?;
        let journal_path = terminal_root.join("output.bin");
        let checkpoint_path = terminal_root.join("checkpoint.bin");
        let pair = portable_pty::native_pty_system()
            .openpty(PtySize {
                rows,
                cols: columns,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(internal_string)?;
        let mut command = CommandBuilder::new(&shell);
        command.arg("-l");
        command.cwd(&cwd);
        command.env("TERM", "xterm-256color");
        command.env("COLORTERM", "truecolor");
        for key in ["TRON_AUTH_TOKEN", "TRON_API_KEY"] {
            command.env_remove(key);
        }
        let child = pair.slave.spawn_command(command).map_err(internal_string)?;
        drop(pair.slave);
        let reader = pair.master.try_clone_reader().map_err(internal_string)?;
        let writer = pair.master.take_writer().map_err(internal_string)?;
        let killer = child.clone_killer();
        let (events, _) = broadcast::channel(512);
        let live = Arc::new(LiveTerminal {
            id: id.clone(),
            session_id: session_id.to_owned(),
            generation,
            master: Mutex::new(pair.master),
            writer: Mutex::new(writer),
            killer: Mutex::new(killer),
            state: Mutex::new(LiveState {
                rows,
                columns,
                next_sequence: 1,
                replay: VecDeque::new(),
                replay_bytes: 0,
                accepted_inputs: HashSet::new(),
                accepted_input_order: VecDeque::new(),
                running: true,
                parser: vt100::Parser::new(rows, columns, 10_000),
                bytes_since_checkpoint: 0,
                last_metadata_update: Instant::now()
                    .checked_sub(Duration::from_secs(1))
                    .unwrap_or_else(Instant::now),
            }),
            events,
            journal_path,
            checkpoint_path,
            reader_done: (Mutex::new(false), Condvar::new()),
        });
        let timestamp = now();
        if let Err(error) = self.event_store.insert_terminal(&TerminalRecord {
            id: id.clone(),
            session_id: session_id.to_owned(),
            generation,
            working_directory: cwd.display().to_string(),
            shell: shell.clone(),
            state: "running".into(),
            rows,
            columns,
            earliest_sequence: 0,
            latest_sequence: 0,
            created_at: timestamp.clone(),
            updated_at: timestamp,
            exited_at: None,
            exit_code: None,
            interruption_reason: None,
            retained_until: (chrono::Utc::now() + chrono::Duration::hours(24)).to_rfc3339(),
        }) {
            let _ = live.killer.lock().map(|mut killer| killer.kill());
            let _ = fs::remove_dir_all(&terminal_root);
            return Err(internal(error));
        }
        self.live.insert(id.clone(), live.clone());
        self.spawn_reader(live.clone(), reader);
        self.spawn_waiter(live, child);
        Ok(json!({"terminal":self.record_for_id(&id)?}))
    }

    /// Write one idempotent byte sequence to a live PTY.
    pub fn write(
        &self,
        id: &str,
        generation: u64,
        input_id: &str,
        bytes: &[u8],
    ) -> Result<Value, ToolError> {
        if bytes.is_empty() || bytes.len() > MAX_INPUT_BYTES {
            return Err(invalid("terminal input must contain 1 to 65536 bytes"));
        }
        let terminal = self.get_live(id, generation)?;
        {
            let mut state = terminal.state.lock().map_err(lock_error)?;
            if !state.running {
                return Err(invalid("terminal is not running"));
            }
            if state.accepted_inputs.contains(input_id) {
                return Ok(json!({"accepted":true,"duplicate":true,"inputId":input_id}));
            }
            terminal
                .writer
                .lock()
                .map_err(lock_error)?
                .write_all(bytes)
                .map_err(internal)?;
            state.accepted_inputs.insert(input_id.to_owned());
            state.accepted_input_order.push_back(input_id.to_owned());
            if state.accepted_input_order.len() > 4096
                && let Some(expired) = state.accepted_input_order.pop_front()
            {
                state.accepted_inputs.remove(&expired);
            }
        }
        Ok(json!({"accepted":true,"duplicate":false,"inputId":input_id}))
    }

    /// Resize a live PTY and notify its foreground process group.
    pub fn resize(
        &self,
        id: &str,
        generation: u64,
        rows: u16,
        columns: u16,
    ) -> Result<Value, ToolError> {
        validate_size(rows, columns)?;
        let terminal = self.get_live(id, generation)?;
        terminal
            .master
            .lock()
            .map_err(lock_error)?
            .resize(PtySize {
                rows,
                cols: columns,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(internal_string)?;
        let mut state = terminal.state.lock().map_err(lock_error)?;
        state.rows = rows;
        state.columns = columns;
        state.parser.screen_mut().set_size(rows, columns);
        state.last_metadata_update = Instant::now();
        self.event_store
            .update_terminal_progress(
                id,
                state.replay.front().map_or(0, |c| c.sequence),
                state.next_sequence.saturating_sub(1),
                rows,
                columns,
            )
            .map_err(internal)?;
        Ok(json!({"resized":true,"rows":rows,"columns":columns}))
    }

    /// Terminate a live terminal process group.
    pub fn terminate(&self, id: &str, generation: u64) -> Result<Value, ToolError> {
        let terminal = self.get_live(id, generation)?;
        terminal
            .killer
            .lock()
            .map_err(lock_error)?
            .kill()
            .map_err(internal)?;
        Ok(json!({"terminating":true}))
    }

    /// Atomically subscribe and snapshot replay after `after`.
    pub fn attach(&self, id: &str, after: u64) -> Result<TerminalAttachment, ToolError> {
        if let Some(terminal) = self.live.get(id).map(|entry| entry.clone()) {
            let state = terminal.state.lock().map_err(lock_error)?;
            let receiver = terminal.events.subscribe();
            let earliest = state
                .replay
                .front()
                .map_or(state.next_sequence, |c| c.sequence);
            return Ok(TerminalAttachment {
                backlog: state
                    .replay
                    .iter()
                    .filter(|chunk| chunk.sequence > after)
                    .cloned()
                    .collect(),
                receiver: Some(receiver),
                earliest_sequence: earliest,
                latest_sequence: state.next_sequence.saturating_sub(1),
                generation: terminal.generation,
                state: "running".to_owned(),
                exit_code: None,
            });
        }

        let record = self
            .event_store
            .terminal_by_id(id)
            .map_err(internal)?
            .filter(|record| retained(record))
            .ok_or_else(|| invalid("terminal history is unavailable or expired"))?;
        let backlog = read_journal(
            &self.root.join(id).join("output.bin"),
            id,
            record.generation,
            after,
        )
        .map_err(internal)?;
        Ok(TerminalAttachment {
            backlog,
            receiver: None,
            earliest_sequence: record.earliest_sequence,
            latest_sequence: record.latest_sequence,
            generation: record.generation,
            state: record.state,
            exit_code: record.exit_code,
        })
    }

    /// Stop all PTYs during the Tools shutdown phase.
    pub async fn shutdown(&self) {
        for terminal in self.live.iter() {
            let _ = terminal.killer.lock().map(|mut killer| killer.kill());
        }
    }

    /// Terminate and remove terminal custody before its owning session is deleted.
    pub fn prepare_session_deletion(&self, session_id: &str) {
        let live_ids = self
            .live
            .iter()
            .filter(|terminal| terminal.session_id == session_id)
            .map(|terminal| terminal.id.clone())
            .collect::<Vec<_>>();
        for id in live_ids {
            if let Some((_, terminal)) = self.live.remove(&id) {
                let _ = terminal.killer.lock().map(|mut killer| killer.kill());
            }
        }
        if let Ok(records) = self.event_store.list_terminals(session_id) {
            for record in records {
                let _ = fs::remove_dir_all(self.root.join(record.id));
            }
        }
    }

    fn ensure_session(
        &self,
        id: &str,
    ) -> Result<crate::domains::session::event_store::SessionRow, ToolError> {
        self.event_store
            .get_session(id)
            .map_err(internal)?
            .ok_or_else(|| invalid("session was not found"))
    }
    fn get_live(&self, id: &str, generation: u64) -> Result<Arc<LiveTerminal>, ToolError> {
        let terminal = self
            .live
            .get(id)
            .map(|v| v.clone())
            .ok_or_else(|| invalid("terminal is not live"))?;
        if terminal.generation != generation {
            return Err(invalid("terminal generation is stale"));
        }
        Ok(terminal)
    }
    fn live_json(&self, terminal: &LiveTerminal) -> Value {
        self.record_for_id(&terminal.id).unwrap_or_else(|_|json!({"id":terminal.id,"sessionId":terminal.session_id,"generation":terminal.generation,"state":"running"}))
    }
    fn record_for_id(&self, id: &str) -> Result<Value, ToolError> {
        self.event_store
            .terminal_by_id(id)
            .map_err(internal)?
            .map(|r| record_json(&r))
            .ok_or_else(|| invalid("terminal record was not found"))
    }

    fn spawn_reader(
        self: &Arc<Self>,
        terminal: Arc<LiveTerminal>,
        mut reader: Box<dyn Read + Send>,
    ) {
        let service = Arc::clone(self);
        tokio::task::spawn_blocking(move || {
            let mut buffer = vec![0u8; MAX_OUTPUT_CHUNK];
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) | Err(_) => break,
                    Ok(count) => service.record_output(&terminal, &buffer[..count]),
                }
            }
            if let Ok(mut done) = terminal.reader_done.0.lock() {
                *done = true;
                terminal.reader_done.1.notify_all();
            }
        });
    }
    fn spawn_waiter(
        self: &Arc<Self>,
        terminal: Arc<LiveTerminal>,
        mut child: Box<dyn portable_pty::Child + Send + Sync>,
    ) {
        let service = Arc::clone(self);
        tokio::task::spawn_blocking(move || {
            let status = child.wait();
            if let Ok(done) = terminal.reader_done.0.lock() {
                let _ = terminal.reader_done.1.wait_timeout_while(
                    done,
                    Duration::from_secs(1),
                    |done| !*done,
                );
            }
            if let Ok(mut state) = terminal.state.lock() {
                state.running = false;
                let _ = service.event_store.update_terminal_progress(
                    &terminal.id,
                    state.replay.front().map_or(0, |chunk| chunk.sequence),
                    state.next_sequence.saturating_sub(1),
                    state.rows,
                    state.columns,
                );
            }
            let code = status.ok().map(|s| s.exit_code() as i32);
            let _ = service
                .event_store
                .finish_terminal(&terminal.id, "exited", code, None);
            let _ = terminal.events.send(TerminalStreamEvent::Status {
                terminal_id: terminal.id.clone(),
                generation: terminal.generation,
                state: "exited".into(),
                exit_code: code,
            });
            service.live.remove(&terminal.id);
        });
    }
    fn record_output(&self, terminal: &LiveTerminal, bytes: &[u8]) {
        let Ok(mut state) = terminal.state.lock() else {
            return;
        };
        let sequence = state.next_sequence;
        state.next_sequence += 1;
        state.parser.process(bytes);
        state.bytes_since_checkpoint = state.bytes_since_checkpoint.saturating_add(bytes.len());
        let chunk = TerminalChunk {
            terminal_id: terminal.id.clone(),
            generation: terminal.generation,
            sequence,
            data_base64: base64::engine::general_purpose::STANDARD.encode(bytes),
        };
        if append_journal(&terminal.journal_path, sequence, bytes).is_err() {
            tracing::warn!(terminal_id=%terminal.id,"terminal journal append failed");
        }
        state.replay_bytes += bytes.len();
        state.replay.push_back(chunk.clone());
        if state.bytes_since_checkpoint >= CHECKPOINT_INTERVAL_BYTES {
            let checkpoint = terminal_snapshot(&state.parser);
            if let Err(error) = replace_private_file(&terminal.checkpoint_path, &checkpoint) {
                tracing::warn!(terminal_id=%terminal.id, %error, "terminal checkpoint write failed");
            } else {
                state.bytes_since_checkpoint = 0;
            }
        }
        if state.replay_bytes > MAX_REPLAY_BYTES {
            let snapshot = terminal_snapshot(&state.parser);
            if let Err(error) = replace_journal(&terminal.journal_path, sequence, &snapshot) {
                tracing::warn!(terminal_id=%terminal.id, %error, "terminal journal compaction failed");
            } else {
                let checkpoint = TerminalChunk {
                    terminal_id: terminal.id.clone(),
                    generation: terminal.generation,
                    sequence,
                    data_base64: base64::engine::general_purpose::STANDARD.encode(&snapshot),
                };
                state.replay.clear();
                state.replay.push_back(checkpoint);
                state.replay_bytes = snapshot.len();
            }
        }
        let earliest = state.replay.front().map_or(sequence, |c| c.sequence);
        let persist_progress = state.last_metadata_update.elapsed() >= Duration::from_millis(250);
        let rows = state.rows;
        let columns = state.columns;
        if persist_progress {
            state.last_metadata_update = Instant::now();
        }
        drop(state);
        if persist_progress {
            let _ = self.event_store.update_terminal_progress(
                &terminal.id,
                earliest,
                sequence,
                rows,
                columns,
            );
        }
        let _ = terminal.events.send(TerminalStreamEvent::Output(chunk));
    }
    fn purge_expired(&self) {
        if let Ok(ids) = self.event_store.purge_expired_terminals() {
            for id in ids {
                let _ = fs::remove_dir_all(self.root.join(id));
            }
        }
        if let Ok(retained_ids) = self.event_store.terminal_ids()
            && let Ok(entries) = fs::read_dir(&self.root)
        {
            for entry in entries.flatten().filter(|entry| entry.path().is_dir()) {
                if !retained_ids.contains(&entry.file_name().to_string_lossy().to_string()) {
                    let _ = fs::remove_dir_all(entry.path());
                }
            }
        }
    }
}

fn resolve_shell() -> Result<String, ToolError> {
    std::env::var("SHELL")
        .ok()
        .filter(|shell| Path::new(shell).is_file())
        .or_else(|| {
            ["/bin/zsh", "/bin/sh"]
                .into_iter()
                .find(|shell| Path::new(shell).is_file())
                .map(str::to_owned)
        })
        .ok_or_else(|| invalid("no supported login shell is installed"))
}
fn validate_size(rows: u16, columns: u16) -> Result<(), ToolError> {
    if !(5..=200).contains(&rows) || !(20..=400).contains(&columns) {
        Err(invalid("terminal dimensions are outside supported bounds"))
    } else {
        Ok(())
    }
}
fn invalid(message: &str) -> ToolError {
    ToolError::InvalidParams {
        message: message.to_owned(),
    }
}
fn internal(error: impl std::fmt::Display) -> ToolError {
    ToolError::Internal {
        message: error.to_string(),
    }
}
fn internal_string(error: impl std::fmt::Display) -> ToolError {
    internal(error)
}
fn lock_error<T>(_: std::sync::PoisonError<T>) -> ToolError {
    internal("terminal state lock poisoned")
}
fn now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
fn record_json(r: &TerminalRecord) -> Value {
    json!({"id":r.id,"sessionId":r.session_id,"generation":r.generation,"workingDirectory":r.working_directory,"shell":r.shell,"state":r.state,"rows":r.rows,"columns":r.columns,"earliestSequence":r.earliest_sequence,"latestSequence":r.latest_sequence,"createdAt":r.created_at,"updatedAt":r.updated_at,"exitedAt":r.exited_at,"exitCode":r.exit_code,"interruptionReason":r.interruption_reason,"retainedUntil":r.retained_until})
}

#[derive(Clone)]
pub(crate) struct Deps {
    service: Arc<TerminalService>,
}
impl Deps {
    fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            service: deps.terminal_service.clone(),
        }
    }
}
pub(crate) fn function_registrations(
    deps: &DomainRegistrationContext,
) -> EngineResult<Vec<DomainFunctionRegistration>> {
    bind_functions(function_definitions()?, Deps::from_engine(deps))
}
fn function_definitions() -> EngineResult<Vec<FunctionDefinition>> {
    [
        ("terminal::list", EffectClass::PureRead, RiskLevel::Low),
        (
            "terminal::open",
            EffectClass::IdempotentWrite,
            RiskLevel::Medium,
        ),
        (
            "terminal::write",
            EffectClass::IdempotentWrite,
            RiskLevel::High,
        ),
        (
            "terminal::resize",
            EffectClass::IdempotentWrite,
            RiskLevel::Low,
        ),
        (
            "terminal::terminate",
            EffectClass::ReversibleSideEffect,
            RiskLevel::High,
        ),
    ]
    .into_iter()
    .map(|(id, effect, risk)| {
        let mut contract = FunctionContract::new(id, "terminal", effect, risk)
            .visibility(FunctionVisibility::NativeClient)
            .request_schema(request_schema(id))
            .response_schema(json!({"type":"object","additionalProperties":true}));
        if effect != EffectClass::PureRead {
            contract = contract.idempotency(IdempotencyContract::profile());
        }
        contract.build()
    })
    .collect()
}

fn request_schema(id: &str) -> Value {
    let (required, properties) = match id {
        "terminal::list" => (
            vec!["sessionId"],
            json!({"sessionId":{"type":"string","minLength":1}}),
        ),
        "terminal::open" => (
            vec!["sessionId", "rows", "columns"],
            json!({
                "sessionId":{"type":"string","minLength":1},
                "rows":{"type":"integer","minimum":5,"maximum":200},
                "columns":{"type":"integer","minimum":20,"maximum":400}
            }),
        ),
        "terminal::write" => (
            vec!["terminalId", "generation", "inputId", "dataBase64"],
            json!({
                "terminalId":{"type":"string","minLength":1},
                "generation":{"type":"integer","minimum":1},
                "inputId":{"type":"string","minLength":1},
                "dataBase64":{"type":"string","minLength":1}
            }),
        ),
        "terminal::resize" => (
            vec!["terminalId", "generation", "rows", "columns"],
            json!({
                "terminalId":{"type":"string","minLength":1},
                "generation":{"type":"integer","minimum":1},
                "rows":{"type":"integer","minimum":5,"maximum":200},
                "columns":{"type":"integer","minimum":20,"maximum":400}
            }),
        ),
        "terminal::terminate" => (
            vec!["terminalId", "generation"],
            json!({
                "terminalId":{"type":"string","minLength":1},
                "generation":{"type":"integer","minimum":1}
            }),
        ),
        _ => unreachable!("terminal function table and schema table must match"),
    };
    json!({"type":"object","additionalProperties":false,"required":required,"properties":properties})
}
operation_bindings! {
deps=Deps; hidden=[]; bindings=[
"list"=>|invocation,deps|{let session=string(&invocation.payload,"sessionId")?;Ok(deps.service.list(session)?)},
"open"=>|invocation,deps|{let session=string(&invocation.payload,"sessionId")?;let rows=number(&invocation.payload,"rows")?;let columns=number(&invocation.payload,"columns")?;Ok(deps.service.open(session,rows,columns).await?)},
"write"=>|invocation,deps|{let id=string(&invocation.payload,"terminalId")?;let generation=u64_number(&invocation.payload,"generation")?;let input_id=string(&invocation.payload,"inputId")?;let encoded=string(&invocation.payload,"dataBase64")?;let bytes=base64::engine::general_purpose::STANDARD.decode(encoded).map_err(|_|invalid("dataBase64 is invalid"))?;Ok(deps.service.write(id,generation,input_id,&bytes)?)},
"resize"=>|invocation,deps|{Ok(deps.service.resize(string(&invocation.payload,"terminalId")?,u64_number(&invocation.payload,"generation")?,number(&invocation.payload,"rows")?,number(&invocation.payload,"columns")?)?)},
"terminate"=>|invocation,deps|{Ok(deps.service.terminate(string(&invocation.payload,"terminalId")?,u64_number(&invocation.payload,"generation")?)?)},
]; }
fn string<'a>(v: &'a Value, key: &str) -> Result<&'a str, ToolError> {
    v.get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| invalid(&format!("{key} is required")))
}
fn u64_number(v: &Value, key: &str) -> Result<u64, ToolError> {
    v.get(key)
        .and_then(Value::as_u64)
        .ok_or_else(|| invalid(&format!("{key} is required")))
}
fn number(v: &Value, key: &str) -> Result<u16, ToolError> {
    u16::try_from(u64_number(v, key)?).map_err(|_| invalid(&format!("{key} is too large")))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn terminal_size_is_bounded() {
        assert!(validate_size(24, 80).is_ok());
        assert!(validate_size(1, 80).is_err());
        assert!(validate_size(24, 500).is_err());
    }

    #[test]
    fn terminal_functions_are_native_client_only_and_schema_bounded() {
        let definitions = function_definitions().expect("terminal definitions");
        assert_eq!(definitions.len(), 5);
        for definition in definitions {
            assert_eq!(definition.visibility, FunctionVisibility::NativeClient);
            assert!(definition.model_tool.is_none());
            assert_eq!(
                definition
                    .request_schema
                    .as_ref()
                    .and_then(|schema| schema["additionalProperties"].as_bool()),
                Some(false)
            );
        }
    }

    #[test]
    fn journal_replay_is_ordered_and_cursor_bounded() {
        let directory = tempfile::tempdir().expect("temporary terminal directory");
        let path = directory.path().join("output.bin");
        append_journal(&path, 1, b"first").expect("first record");
        append_journal(&path, 2, b"second").expect("second record");

        let chunks = read_journal(&path, "terminal", 1, 1).expect("journal replay");
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].sequence, 2);
        assert_eq!(
            base64::engine::general_purpose::STANDARD
                .decode(&chunks[0].data_base64)
                .expect("base64 output"),
            b"second"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn pty_streams_output_and_reaches_terminal_status() {
        let context = crate::shared::server::test_support::make_test_context();
        let workspace = tempfile::tempdir().expect("temporary workspace");
        let terminal_root = tempfile::tempdir().expect("temporary terminal root");
        let session = context
            .event_store
            .create_session(
                "openai/gpt-5.6-luna",
                workspace.path().to_str().expect("workspace path"),
                Some("terminal test"),
                Some("openai"),
            )
            .expect("session")
            .session;
        let service = TerminalService::new_with_root(
            context.event_store.clone(),
            terminal_root.path().to_path_buf(),
        );
        let opened = service.open(&session.id, 24, 80).await.expect("open PTY");
        let terminal = &opened["terminal"];
        let id = terminal["id"].as_str().expect("terminal id");
        let generation = terminal["generation"].as_u64().expect("generation");
        let mut attachment = service.attach(id, 0).expect("attach PTY");

        service
            .write(
                id,
                generation,
                "input-1",
                b"printf 'TRON_PTY_OK\\n'\nexit\n",
            )
            .expect("write PTY");

        let mut output = Vec::new();
        let receiver = attachment.receiver.as_mut().expect("live receiver");
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                match receiver.recv().await.expect("terminal event") {
                    TerminalStreamEvent::Output(chunk) => output.extend(
                        base64::engine::general_purpose::STANDARD
                            .decode(chunk.data_base64)
                            .expect("terminal base64"),
                    ),
                    TerminalStreamEvent::Status { state, .. } if state == "exited" => break,
                    TerminalStreamEvent::Status { .. } => {}
                }
            }
        })
        .await
        .expect("PTY exit timeout");
        assert!(String::from_utf8_lossy(&output).contains("TRON_PTY_OK"));
    }
}
