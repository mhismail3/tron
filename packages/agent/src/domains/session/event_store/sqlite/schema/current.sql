-- Current event-store schema.
--
-- Databases contain only the stores needed
-- to boot the agent loop, reconstruct bare sessions, persist invocation
-- history, retain agent-owned blobs, and capture server/client logs.

CREATE TABLE IF NOT EXISTS workspaces (
  id               TEXT PRIMARY KEY,
  path             TEXT NOT NULL UNIQUE,
  name             TEXT,
  created_at       TEXT NOT NULL,
  last_activity_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_workspaces_path ON workspaces(path);

-- Core schedules are durable agent tasks, never arbitrary function/worker
-- callbacks. Canonical target/timing/policy JSON is validated by the schedule
-- domain before admission; scalar columns retain lifecycle, CAS, and due-query
-- invariants at the storage boundary.
CREATE TABLE IF NOT EXISTS schedules (
  schedule_id        TEXT PRIMARY KEY,
  idempotency_key    TEXT NOT NULL UNIQUE,
  request_digest     TEXT NOT NULL,
  owner_agent_id     TEXT NOT NULL,
  name               TEXT NOT NULL,
  target_kind        TEXT NOT NULL CHECK(target_kind IN (
    'reusable_agent','fresh_agent','capability'
  )),
  target_principal_agent_id TEXT,
  target_json        TEXT NOT NULL,
  authority_json     TEXT NOT NULL,
  timing_kind        TEXT NOT NULL CHECK(timing_kind IN ('once','recurring')),
  timing_json        TEXT NOT NULL,
  policy_json        TEXT NOT NULL,
  state              TEXT NOT NULL CHECK(state IN ('active','paused','deleted')),
  revision           INTEGER NOT NULL CHECK(revision BETWEEN 1 AND 9223372036854775807),
  cursor_at          TEXT NOT NULL,
  next_due_at        TEXT,
  last_error         TEXT,
  created_at         TEXT NOT NULL,
  updated_at         TEXT NOT NULL,
  deleted_at         TEXT,
  CHECK(length(CAST(name AS BLOB)) BETWEEN 1 AND 200),
  CHECK(length(CAST(target_json AS BLOB)) BETWEEN 2 AND 65536),
  CHECK(length(CAST(authority_json AS BLOB)) BETWEEN 2 AND 65536),
  CHECK(length(CAST(timing_json AS BLOB)) BETWEEN 2 AND 65536),
  CHECK(length(CAST(policy_json AS BLOB)) BETWEEN 2 AND 4096),
  CHECK(
    (target_kind IN ('reusable_agent','fresh_agent')
      AND target_principal_agent_id IS NOT NULL) OR
    (target_kind='capability' AND target_principal_agent_id IS NULL)
  ),
  CHECK((state='deleted')=(deleted_at IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_schedules_due
  ON schedules(state,next_due_at,schedule_id);
CREATE INDEX IF NOT EXISTS idx_schedules_owner_page
  ON schedules(owner_agent_id,created_at,schedule_id);
CREATE INDEX IF NOT EXISTS idx_schedules_page
  ON schedules(created_at,schedule_id);

-- Occurrences snapshot the task and target at admission. Scheduled keys derive
-- from `(schedule_id, scheduled_for)`; manual keys derive from the caller's
-- idempotency key. Compact summary rows audit bounded misfire suppression
-- without manufacturing agent work for every skipped instant.
CREATE TABLE IF NOT EXISTS schedule_occurrences (
  occurrence_id      TEXT PRIMARY KEY,
  occurrence_key     TEXT NOT NULL UNIQUE,
  schedule_id        TEXT NOT NULL REFERENCES schedules(schedule_id),
  schedule_revision  INTEGER NOT NULL CHECK(schedule_revision>=1),
  kind                TEXT NOT NULL CHECK(kind IN ('scheduled','manual','misfire_summary')),
  scheduled_for       TEXT NOT NULL,
  state               TEXT NOT NULL CHECK(state IN (
    'queued','running','completed','failed','skipped','cancelled'
  )),
  target_json         TEXT NOT NULL,
  authority_json      TEXT NOT NULL,
  missed_count        INTEGER NOT NULL DEFAULT 0 CHECK(missed_count>=0),
  window_start        TEXT,
  window_end          TEXT,
  skip_reason         TEXT,
  agent_id            TEXT,
  assignment_id       TEXT,
  invocation_id       TEXT,
  output_ref          TEXT,
  failure             TEXT,
  claim_owner         TEXT,
  lease_expires_at    TEXT,
  attempt             INTEGER NOT NULL DEFAULT 0 CHECK(attempt>=0),
  created_at          TEXT NOT NULL,
  started_at          TEXT,
  finished_at         TEXT,
  CHECK(length(CAST(target_json AS BLOB)) BETWEEN 2 AND 65536),
  CHECK(length(CAST(authority_json AS BLOB)) BETWEEN 2 AND 65536),
  CHECK(
    (kind='misfire_summary' AND state='skipped' AND missed_count>0
      AND window_start IS NOT NULL AND window_end IS NOT NULL) OR
    (kind!='misfire_summary' AND missed_count=0
      AND window_start IS NULL AND window_end IS NULL)
  ),
  CHECK(
    (state='running' AND claim_owner IS NOT NULL AND lease_expires_at IS NOT NULL
      AND started_at IS NOT NULL AND finished_at IS NULL) OR
    (state!='running' AND claim_owner IS NULL AND lease_expires_at IS NULL)
  ),
  CHECK(
    (state IN ('completed','failed','skipped','cancelled'))=(finished_at IS NOT NULL)
  ),
  CHECK(NOT (assignment_id IS NOT NULL AND invocation_id IS NOT NULL)),
  CHECK(agent_id IS NULL OR assignment_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_schedule_occurrences_schedule
  ON schedule_occurrences(schedule_id,created_at DESC,occurrence_id DESC);
CREATE INDEX IF NOT EXISTS idx_schedule_occurrences_dispatch
  ON schedule_occurrences(state,scheduled_for,created_at,occurrence_id);
CREATE INDEX IF NOT EXISTS idx_schedule_occurrences_lease
  ON schedule_occurrences(state,lease_expires_at,occurrence_id);
CREATE INDEX IF NOT EXISTS idx_schedule_occurrences_active
  ON schedule_occurrences(schedule_id,state,created_at,occurrence_id);

CREATE TABLE IF NOT EXISTS sessions (
  id                          TEXT PRIMARY KEY,
  workspace_id                TEXT NOT NULL REFERENCES workspaces(id),
  head_event_id               TEXT,
  root_event_id               TEXT,
  title                       TEXT,
  latest_model                TEXT NOT NULL,
  working_directory           TEXT NOT NULL,
  parent_session_id           TEXT REFERENCES sessions(id),
  fork_from_event_id          TEXT,
  created_at                  TEXT NOT NULL,
  last_activity_at            TEXT NOT NULL,
  ended_at                    TEXT,
  event_count                 INTEGER NOT NULL DEFAULT 0,
  message_count               INTEGER NOT NULL DEFAULT 0,
  turn_count                  INTEGER NOT NULL DEFAULT 0,
  total_input_tokens          INTEGER NOT NULL DEFAULT 0,
  total_output_tokens         INTEGER NOT NULL DEFAULT 0,
  last_turn_input_tokens      INTEGER NOT NULL DEFAULT 0,
  total_cost                  REAL    NOT NULL DEFAULT 0,
  total_cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
  total_cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
  tags                        TEXT    NOT NULL DEFAULT '[]'
);

CREATE INDEX IF NOT EXISTS idx_sessions_workspace ON sessions(workspace_id);
CREATE INDEX IF NOT EXISTS idx_sessions_activity  ON sessions(last_activity_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_parent    ON sessions(parent_session_id);
CREATE INDEX IF NOT EXISTS idx_sessions_ended     ON sessions(ended_at);
CREATE INDEX IF NOT EXISTS idx_sessions_created   ON sessions(created_at DESC);

-- Promotion removes the nested-agent tag so the transcript enters the
-- ordinary Sessions index. This receipt makes that destructive-looking tag
-- rewrite exactly replayable across the workers.sqlite outbox boundary.
CREATE TABLE IF NOT EXISTS agent_session_promotions (
  session_id   TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
  promoted_at  TEXT NOT NULL
);

-- Core reusable-agent identity and work custody. These tables are the dormant
-- same-database successor to Worker Kernel coordination state: a stable agent
-- owns one transcript while assignments are the only causal work nodes. There
-- is intentionally no worker kind, role version, or separate execution ID.
CREATE TABLE IF NOT EXISTS agents (
  agent_id                    TEXT PRIMARY KEY,
  transcript_session_id       TEXT NOT NULL UNIQUE
    REFERENCES sessions(id) ON DELETE RESTRICT,
  root_agent_id               TEXT NOT NULL REFERENCES agents(agent_id),
  workspace_id                TEXT NOT NULL REFERENCES workspaces(id),
  parent_agent_id             TEXT REFERENCES agents(agent_id),
  management_owner_agent_id   TEXT REFERENCES agents(agent_id),
  name                        TEXT NOT NULL,
  visibility                  TEXT NOT NULL CHECK(visibility IN ('nested','visible')),
  lifecycle                   TEXT NOT NULL CHECK(lifecycle IN ('open','closing','closed')),
  default_model               TEXT,
  default_reasoning_level     TEXT,
  default_capability_grant_json TEXT NOT NULL DEFAULT '{}',
  default_write_scopes_json   TEXT NOT NULL DEFAULT '[]',
  default_limits_json         TEXT NOT NULL,
  created_at                  TEXT NOT NULL,
  updated_at                  TEXT NOT NULL,
  closed_at                   TEXT,
  CHECK(length(CAST(name AS BLOB)) BETWEEN 1 AND 160),
  CHECK((lifecycle='closed')=(closed_at IS NOT NULL)),
  CHECK(
    (parent_agent_id IS NULL AND root_agent_id=agent_id
      AND management_owner_agent_id IS NULL AND visibility='visible')
    OR
    (parent_agent_id IS NOT NULL AND root_agent_id!=agent_id AND (
      (visibility='nested' AND management_owner_agent_id IS NOT NULL) OR
      (visibility='visible' AND management_owner_agent_id IS NULL)
    ))
  )
);

CREATE INDEX IF NOT EXISTS idx_agents_root
  ON agents(root_agent_id,lifecycle,created_at,agent_id);
CREATE INDEX IF NOT EXISTS idx_agents_parent
  ON agents(parent_agent_id,lifecycle,created_at,agent_id);
CREATE INDEX IF NOT EXISTS idx_agents_owner
  ON agents(management_owner_agent_id,lifecycle,created_at,agent_id);

-- Persistent code is one logical journal per stable agent. QuickJS execution
-- occurs in a disposable helper process; these rows are the parent-owned
-- recovery truth for accepted cells and nested broker effects. A helper crash
-- therefore cannot erase admission or cause a completed effect to run twice.
CREATE TABLE IF NOT EXISTS code_runtimes (
  runtime_id          TEXT PRIMARY KEY NOT NULL,
  agent_id            TEXT NOT NULL,
  epoch               INTEGER NOT NULL CHECK(epoch>=0),
  is_current          INTEGER NOT NULL CHECK(is_current IN (0,1)),
  state               TEXT NOT NULL CHECK(state IN ('ready','retired')),
  next_cell_sequence  INTEGER NOT NULL DEFAULT 0 CHECK(next_cell_sequence>=0),
  active_cell_id      TEXT,
  runtime_abi         TEXT NOT NULL,
  created_at          TEXT NOT NULL,
  updated_at          TEXT NOT NULL,
  UNIQUE(agent_id,epoch)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_code_runtime_current
  ON code_runtimes(agent_id) WHERE is_current=1;

CREATE TABLE IF NOT EXISTS code_cells (
  cell_id             TEXT PRIMARY KEY NOT NULL,
  runtime_id          TEXT NOT NULL REFERENCES code_runtimes(runtime_id),
  sequence            INTEGER NOT NULL CHECK(sequence>=0),
  invocation_key      TEXT NOT NULL,
  assignment_id       TEXT,
  source_text         TEXT NOT NULL,
  source_digest       TEXT NOT NULL,
  compiled_text       TEXT NOT NULL,
  compiled_digest     TEXT NOT NULL,
  status              TEXT NOT NULL CHECK(status IN (
    'running','committed','failed','cancelled','timed_out'
  )),
  result_json         TEXT,
  output_json         TEXT NOT NULL DEFAULT '[]',
  error_text          TEXT,
  created_at          TEXT NOT NULL,
  started_at          TEXT NOT NULL,
  completed_at        TEXT,
  UNIQUE(runtime_id,sequence),
  UNIQUE(runtime_id,invocation_key),
  CHECK((status='running')=(completed_at IS NULL))
);

CREATE INDEX IF NOT EXISTS idx_code_cells_runtime_status
  ON code_cells(runtime_id,status,sequence);

CREATE TABLE IF NOT EXISTS code_calls (
  call_id             TEXT PRIMARY KEY NOT NULL,
  cell_id             TEXT NOT NULL REFERENCES code_cells(cell_id),
  call_ordinal        INTEGER NOT NULL CHECK(call_ordinal>=0),
  operation           TEXT NOT NULL,
  request_json        TEXT NOT NULL,
  request_digest      TEXT NOT NULL,
  status              TEXT NOT NULL CHECK(status IN ('admitted','completed','failed')),
  result_json         TEXT,
  error_text          TEXT,
  created_at          TEXT NOT NULL,
  completed_at        TEXT,
  UNIQUE(cell_id,call_ordinal),
  CHECK((status='admitted')=(completed_at IS NULL)),
  CHECK((status='completed')=(result_json IS NOT NULL)),
  CHECK((status='failed')=(error_text IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS code_runtime_events (
  event_id            TEXT PRIMARY KEY NOT NULL,
  runtime_id          TEXT NOT NULL REFERENCES code_runtimes(runtime_id),
  cell_id             TEXT REFERENCES code_cells(cell_id),
  kind                TEXT NOT NULL,
  payload_json        TEXT NOT NULL,
  created_at          TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_code_runtime_events_runtime
  ON code_runtime_events(runtime_id,created_at,event_id);

CREATE TABLE IF NOT EXISTS agent_assignments (
  assignment_id                 TEXT PRIMARY KEY,
  admission_key                 TEXT NOT NULL UNIQUE,
  agent_id                      TEXT NOT NULL REFERENCES agents(agent_id),
  requested_by_agent_id         TEXT REFERENCES agents(agent_id),
  parent_assignment_id          TEXT REFERENCES agent_assignments(assignment_id),
  retry_of_assignment_id        TEXT REFERENCES agent_assignments(assignment_id),
  kind                          TEXT NOT NULL CHECK(kind IN (
    'instruction','request','operator','schedule'
  )),
  status                        TEXT NOT NULL CHECK(status IN (
    'offered','queued','running','waiting','completed','declined','failed',
    'cancelled','timed_out','expired'
  )),
  queue_ordinal                 INTEGER NOT NULL CHECK(queue_ordinal>=0),
  trace_id                      TEXT NOT NULL,
  autonomous_hop               INTEGER NOT NULL DEFAULT 0
    CHECK(autonomous_hop BETWEEN 0 AND 4294967295),
  causal_depth                  INTEGER NOT NULL CHECK(causal_depth BETWEEN 0 AND 16),
  causal_ordinal                INTEGER CHECK(causal_ordinal IS NULL OR causal_ordinal>=0),
  task                          TEXT NOT NULL,
  context_json                  TEXT NOT NULL,
  model                         TEXT,
  reasoning_level               TEXT,
  capability_snapshot_json      TEXT NOT NULL,
  write_scopes_snapshot_json    TEXT NOT NULL DEFAULT '[]',
  limits_snapshot_json          TEXT NOT NULL,
  deadline_at                   TEXT,
  created_at                    TEXT NOT NULL,
  accepted_at                   TEXT,
  started_at                    TEXT,
  completed_at                  TEXT,
  updated_at                    TEXT NOT NULL,
  CHECK(length(CAST(task AS BLOB)) BETWEEN 1 AND 40000),
  CHECK((parent_assignment_id IS NULL)=(causal_ordinal IS NULL)),
  CHECK(
    (status IN ('completed','declined','failed','cancelled','timed_out','expired'))
    =(completed_at IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_agent_assignments_queue
  ON agent_assignments(agent_id,status,queue_ordinal,created_at,assignment_id);
CREATE INDEX IF NOT EXISTS idx_agent_assignments_requester
  ON agent_assignments(requested_by_agent_id,created_at DESC,assignment_id);
CREATE INDEX IF NOT EXISTS idx_agent_assignments_parent
  ON agent_assignments(parent_assignment_id,created_at,assignment_id);
CREATE INDEX IF NOT EXISTS idx_agent_assignments_trace
  ON agent_assignments(trace_id,causal_depth,created_at,assignment_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_assignments_causal_order
  ON agent_assignments(parent_assignment_id,causal_ordinal)
  WHERE parent_assignment_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_assignments_one_active
  ON agent_assignments(agent_id) WHERE status IN ('running','waiting');

CREATE TABLE IF NOT EXISTS agent_assignment_attempts (
  attempt_id              TEXT PRIMARY KEY,
  assignment_id           TEXT NOT NULL
    REFERENCES agent_assignments(assignment_id) ON DELETE CASCADE,
  attempt_number          INTEGER NOT NULL CHECK(attempt_number>0),
  status                  TEXT NOT NULL CHECK(status IN (
    'running','waiting','completed','failed','interrupted'
  )),
  run_id                  TEXT,
  baseline_event_sequence INTEGER NOT NULL DEFAULT 0 CHECK(baseline_event_sequence>=0),
  started_at              TEXT NOT NULL,
  completed_at            TEXT,
  error                   TEXT,
  UNIQUE(assignment_id,attempt_number),
  CHECK((status IN ('running','waiting'))=(completed_at IS NULL))
);

CREATE INDEX IF NOT EXISTS idx_agent_assignment_attempts_assignment
  ON agent_assignment_attempts(assignment_id,attempt_number);

-- Every terminal assignment has one immutable result envelope. Small JSON is
-- inline; large JSON uses the EventStore's existing content-addressed blob
-- custody. Failure-only results may intentionally have no payload.
CREATE TABLE IF NOT EXISTS agent_results (
  result_id          TEXT PRIMARY KEY,
  assignment_id      TEXT NOT NULL UNIQUE
    REFERENCES agent_assignments(assignment_id) ON DELETE RESTRICT,
  terminal_status    TEXT NOT NULL CHECK(terminal_status IN (
    'completed','declined','failed','cancelled','timed_out','expired'
  )),
  inline_json        TEXT,
  payload_blob_id    TEXT REFERENCES blobs(id) ON DELETE RESTRICT,
  payload_sha256     TEXT,
  payload_byte_count INTEGER NOT NULL CHECK(payload_byte_count>=0),
  error              TEXT,
  created_at         TEXT NOT NULL,
  CHECK(NOT (inline_json IS NOT NULL AND payload_blob_id IS NOT NULL)),
  CHECK(
    (payload_byte_count=0 AND inline_json IS NULL AND payload_blob_id IS NULL
      AND payload_sha256 IS NULL)
    OR
    (payload_byte_count>0 AND (inline_json IS NOT NULL OR payload_blob_id IS NOT NULL)
      AND payload_sha256 IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS idx_agent_results_created
  ON agent_results(created_at,result_id);

-- One durable autonomy gate per causal graph. Evidence is admitted before a
-- ceiling crossing pauses dispatch; only authenticated operator/user handling
-- may resume the graph, with a recovery wake whose hop resets to zero.
CREATE TABLE IF NOT EXISTS agent_coordination_traces (
  trace_id                 TEXT PRIMARY KEY,
  root_agent_id            TEXT NOT NULL REFERENCES agents(agent_id),
  root_session_id          TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
  state                    TEXT NOT NULL DEFAULT 'active'
    CHECK(state IN ('active','paused')),
  reason                   TEXT,
  message_count            INTEGER NOT NULL DEFAULT 0 CHECK(message_count>=0),
  message_baseline         INTEGER NOT NULL DEFAULT 0
    CHECK(message_baseline>=0 AND message_baseline<=message_count),
  max_autonomous_hop       INTEGER NOT NULL DEFAULT 0 CHECK(max_autonomous_hop>=0),
  paused_agent_id          TEXT REFERENCES agents(agent_id),
  paused_assignment_id     TEXT REFERENCES agent_assignments(assignment_id),
  created_at               TEXT NOT NULL,
  updated_at               TEXT NOT NULL,
  paused_at                TEXT,
  resumed_at               TEXT,
  CHECK((state='paused')=(paused_at IS NOT NULL)),
  CHECK((state='paused')=(reason IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_agent_coordination_traces_state
  ON agent_coordination_traces(state,updated_at,trace_id);

-- Engine-derived wake intent. Model calls never choose active/passive delivery:
-- the coordination owner emits these only for actionable messages, unabsorbed
-- assignment results, aggregate waits, operator instructions, or schedules.
-- Leasing is safe-boundary work and never interrupts a provider stream/tool.
CREATE TABLE IF NOT EXISTS agent_wake_intents (
  wake_id               TEXT PRIMARY KEY,
  idempotency_key       TEXT NOT NULL UNIQUE,
  target_agent_id       TEXT NOT NULL REFERENCES agents(agent_id),
  target_session_id     TEXT NOT NULL REFERENCES sessions(id) ON DELETE RESTRICT,
  target_assignment_id  TEXT REFERENCES agent_assignments(assignment_id),
  cause_kind            TEXT NOT NULL CHECK(cause_kind IN (
    'message','assignment_result','wait_result','operator','schedule','recovery'
  )),
  cause_id              TEXT NOT NULL,
  trace_id              TEXT NOT NULL REFERENCES agent_coordination_traces(trace_id),
  autonomous_hop        INTEGER NOT NULL DEFAULT 0
    CHECK(autonomous_hop BETWEEN 0 AND 4294967295),
  materialized_message_id TEXT UNIQUE
    REFERENCES agent_message_metadata(message_id) ON DELETE SET NULL,
  priority              INTEGER NOT NULL CHECK(priority BETWEEN 0 AND 100),
  disposition           TEXT NOT NULL DEFAULT 'pending'
    CHECK(disposition IN ('pending','leased','delivered','cancelled')),
  not_before            TEXT,
  lease_id              TEXT,
  delivered_by_lease_id TEXT,
  lease_count           INTEGER NOT NULL DEFAULT 0 CHECK(lease_count>=0),
  last_error            TEXT,
  created_at            TEXT NOT NULL,
  leased_at             TEXT,
  delivered_at          TEXT,
  cancelled_at          TEXT,
  UNIQUE(target_agent_id,cause_kind,cause_id),
  CHECK((disposition='leased')=(lease_id IS NOT NULL)),
  CHECK((disposition='delivered')=(delivered_at IS NOT NULL)),
  CHECK((disposition='delivered')=(delivered_by_lease_id IS NOT NULL)),
  CHECK((disposition='cancelled')=(cancelled_at IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_agent_wake_intents_pending
  ON agent_wake_intents(disposition,priority,not_before,created_at,wake_id);
CREATE INDEX IF NOT EXISTS idx_agent_wake_intents_target
  ON agent_wake_intents(target_agent_id,disposition,created_at,wake_id);
CREATE INDEX IF NOT EXISTS idx_agent_wake_intents_trace
  ON agent_wake_intents(trace_id,disposition,created_at,wake_id);

-- Exact mutation replay custody. Management transitions are idempotent even
-- when a client reconnects after commit but before receiving the response.
CREATE TABLE IF NOT EXISTS agent_management_receipts (
  idempotency_key  TEXT PRIMARY KEY,
  action           TEXT NOT NULL CHECK(action IN ('cancel','configure','close','promote')),
  request_json     TEXT NOT NULL,
  outcome_json     TEXT NOT NULL,
  created_at       TEXT NOT NULL,
  CHECK(length(CAST(request_json AS BLOB)) BETWEEN 2 AND 1048576),
  CHECK(length(CAST(outcome_json AS BLOB)) BETWEEN 2 AND 4194304)
);

-- Agent deliveries are durable reference context addressed to either one
-- session or one logical mailbox. They deliberately live beside session truth:
-- the EventStore can create a visible session and seed its first delivery in
-- one transaction, and session deletion can revoke every associated grant.
CREATE TABLE IF NOT EXISTS agent_deliveries (
  delivery_id                TEXT    PRIMARY KEY,
  idempotency_key            TEXT    NOT NULL UNIQUE,
  source_kind                TEXT    NOT NULL
    CHECK (source_kind IN ('worker_result','agent_message','continuity')),
  intent                     TEXT
    CHECK (intent IS NULL OR intent IN ('information','request')),
  source_session_id          TEXT    REFERENCES sessions(id) ON DELETE SET NULL,
  source_workspace_id        TEXT    NOT NULL,
  source_invocation_id       TEXT,
  source_trace_id            TEXT,
  source_root_invocation_id  TEXT,
  causal_depth               INTEGER NOT NULL DEFAULT 0 CHECK (causal_depth >= 0),
  target_kind                TEXT    NOT NULL CHECK (target_kind IN ('session','mailbox')),
  target_session_id          TEXT    REFERENCES sessions(id) ON DELETE CASCADE,
  mailbox_scope              TEXT
    CHECK (mailbox_scope IS NULL OR mailbox_scope IN ('workspace','profile')),
  mailbox_workspace_id       TEXT    REFERENCES workspaces(id) ON DELETE CASCADE,
  mailbox_name               TEXT,
  wake_policy                TEXT    NOT NULL CHECK (wake_policy IN ('passive','wake')),
  boundary                   TEXT    NOT NULL CHECK (boundary IN ('next_turn','next_run')),
  originating_run_id         TEXT,
  arrived_during_run_id      TEXT,
  defer_until_run_id         TEXT,
  result_invocation_id       TEXT,
  content                    TEXT    NOT NULL,
  not_before                 TEXT,
  expires_at                 TEXT,
  disposition                TEXT    NOT NULL DEFAULT 'pending'
    CHECK (disposition IN ('pending','observed','cancelled','stale')),
  leased_run_id              TEXT,
  leased_turn                INTEGER,
  lease_count                INTEGER NOT NULL DEFAULT 0 CHECK (lease_count >= 0),
  wake_attempts              INTEGER NOT NULL DEFAULT 0 CHECK (wake_attempts >= 0),
  next_wake_at               TEXT,
  last_error                 TEXT,
  created_at                 TEXT    NOT NULL,
  claimed_at                 TEXT,
  observed_at                TEXT,
  cancelled_at               TEXT,
  CHECK (
    (target_kind='session' AND target_session_id IS NOT NULL
      AND mailbox_scope IS NULL AND mailbox_workspace_id IS NULL
      AND mailbox_name IS NULL)
    OR
    (target_kind='mailbox' AND target_session_id IS NULL
      AND mailbox_scope IS NOT NULL AND mailbox_name IS NOT NULL)
  ),
  CHECK (
    (mailbox_scope='workspace' AND mailbox_workspace_id IS NOT NULL)
    OR (mailbox_scope='profile' AND mailbox_workspace_id IS NULL)
    OR mailbox_scope IS NULL
  ),
  CHECK (target_kind!='mailbox' OR wake_policy='passive'),
  CHECK (
    (leased_run_id IS NULL AND leased_turn IS NULL)
    OR (leased_run_id IS NOT NULL AND leased_turn IS NOT NULL
      AND disposition='pending')
  ),
  CHECK (length(CAST(content AS BLOB)) BETWEEN 1 AND 40000)
);

CREATE INDEX IF NOT EXISTS idx_agent_deliveries_session_pending
  ON agent_deliveries(target_session_id, disposition, not_before, created_at, delivery_id);
CREATE INDEX IF NOT EXISTS idx_agent_deliveries_wake_due
  ON agent_deliveries(wake_policy, disposition, next_wake_at, created_at);
CREATE INDEX IF NOT EXISTS idx_agent_deliveries_mailbox
  ON agent_deliveries(
    mailbox_scope,
    mailbox_workspace_id,
    mailbox_name,
    disposition,
    created_at
  );
CREATE INDEX IF NOT EXISTS idx_agent_deliveries_result_grant
  ON agent_deliveries(result_invocation_id, target_session_id, disposition);
CREATE INDEX IF NOT EXISTS idx_agent_deliveries_lease
  ON agent_deliveries(leased_run_id, disposition);

-- Accepted assignment instructions are durable conversation evidence before
-- they are runnable, but no unrelated provider turn may lease them. The FIFO
-- assignment supervisor releases this one-way latch only after committing the
-- exact assignment's Running state and attempt baseline.
CREATE TABLE IF NOT EXISTS agent_assignment_delivery_holds (
  delivery_id   TEXT PRIMARY KEY REFERENCES agent_deliveries(delivery_id) ON DELETE CASCADE,
  assignment_id TEXT NOT NULL UNIQUE,
  state         TEXT NOT NULL CHECK (state IN ('held','released')),
  created_at    TEXT NOT NULL,
  released_at   TEXT
);

CREATE TABLE IF NOT EXISTS agent_waits (
  wait_id          TEXT PRIMARY KEY,
  idempotency_key  TEXT NOT NULL UNIQUE,
  session_id       TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  source_invocation_id TEXT NOT NULL,
  source_trace_id  TEXT NOT NULL,
  source_root_invocation_id TEXT,
  causal_depth     INTEGER NOT NULL CHECK (causal_depth >= 0 AND causal_depth <= 4294967295),
  mode             TEXT NOT NULL CHECK (mode IN ('all','any')),
  disposition      TEXT NOT NULL DEFAULT 'pending'
    CHECK (disposition IN ('pending','satisfied','cancelled')),
  delivery_id      TEXT REFERENCES agent_deliveries(delivery_id) ON DELETE SET NULL,
  created_at       TEXT NOT NULL,
  resolved_at      TEXT
);

CREATE INDEX IF NOT EXISTS idx_agent_waits_pending
  ON agent_waits(disposition, session_id, created_at);

CREATE TABLE IF NOT EXISTS agent_wait_members (
  wait_id              TEXT NOT NULL REFERENCES agent_waits(wait_id) ON DELETE CASCADE,
  invocation_id        TEXT NOT NULL,
  ordinal              INTEGER NOT NULL,
  disposition          TEXT NOT NULL DEFAULT 'pending'
    CHECK (disposition IN ('pending','satisfied','ignored')),
  terminal_status      TEXT,
  terminal_evidence    TEXT,
  resolved_at          TEXT,
  PRIMARY KEY(wait_id, invocation_id),
  UNIQUE(wait_id, ordinal)
);

CREATE INDEX IF NOT EXISTS idx_agent_wait_members_invocation
  ON agent_wait_members(invocation_id, disposition, wait_id);

-- First-class coordination messages retain bounded semantic content and
-- provenance before the recipient reaches a provider-safe boundary. Exact
-- materialization then binds the same content to one append-only event; this
-- table remains canonical for ordering, reply correlation, and observation.
CREATE TABLE IF NOT EXISTS agent_message_metadata (
  message_id             TEXT PRIMARY KEY,
  idempotency_key        TEXT NOT NULL UNIQUE,
  channel_id             TEXT NOT NULL,
  channel_sequence       INTEGER NOT NULL CHECK(channel_sequence>=0),
  source_agent_id        TEXT NOT NULL,
  source_session_id      TEXT REFERENCES sessions(id) ON DELETE SET NULL,
  target_agent_id        TEXT NOT NULL,
  target_session_id      TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  kind                   TEXT NOT NULL CHECK(kind IN (
    'instruction','request','question','answer','information','update','result'
  )),
  authority              TEXT NOT NULL CHECK(authority IN ('operator','owner','peer','engine')),
  trace_id               TEXT NOT NULL,
  autonomous_hop         INTEGER NOT NULL CHECK(autonomous_hop>=0 AND autonomous_hop<=4294967295),
  assignment_id          TEXT,
  reply_to_message_id    TEXT REFERENCES agent_message_metadata(message_id),
  content_json           TEXT NOT NULL,
  disposition            TEXT NOT NULL DEFAULT 'pending'
    CHECK(disposition IN ('pending','materialized','observed','cancelled')),
  materialized_event_id  TEXT REFERENCES events(id) ON DELETE SET NULL,
  created_at             TEXT NOT NULL,
  materialized_at        TEXT,
  observed_at            TEXT,
  cancelled_at           TEXT,
  UNIQUE(channel_id,channel_sequence),
  CHECK ((disposition IN ('materialized','observed'))=(materialized_event_id IS NOT NULL)),
  CHECK ((materialized_at IS NULL)=(disposition IN ('pending','cancelled'))),
  CHECK ((observed_at IS NOT NULL)=(disposition='observed')),
  CHECK ((cancelled_at IS NOT NULL)=(disposition='cancelled')),
  CHECK ((kind='answer')=(reply_to_message_id IS NOT NULL)),
  CHECK(length(CAST(content_json AS BLOB)) BETWEEN 2 AND 48000)
);

CREATE INDEX IF NOT EXISTS idx_agent_message_metadata_target
  ON agent_message_metadata(target_agent_id,disposition,created_at,message_id);
CREATE INDEX IF NOT EXISTS idx_agent_message_metadata_source
  ON agent_message_metadata(source_agent_id,created_at,message_id);
CREATE INDEX IF NOT EXISTS idx_agent_message_metadata_session
  ON agent_message_metadata(target_session_id,created_at,message_id);
CREATE INDEX IF NOT EXISTS idx_agent_message_metadata_assignment
  ON agent_message_metadata(assignment_id,created_at,message_id);
CREATE INDEX IF NOT EXISTS idx_agent_message_metadata_trace
  ON agent_message_metadata(trace_id,created_at,message_id);
CREATE INDEX IF NOT EXISTS idx_agent_message_metadata_reply
  ON agent_message_metadata(reply_to_message_id,created_at,message_id);

-- Generalized waits can fan in agent assignments, worker invocations, and
-- correlated replies without overloading the legacy worker-only wait tables.
CREATE TABLE IF NOT EXISTS coordination_waits (
  wait_id               TEXT PRIMARY KEY,
  idempotency_key       TEXT NOT NULL UNIQUE,
  session_id            TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  owner_agent_id        TEXT NOT NULL,
  owner_assignment_id   TEXT,
  trace_id              TEXT NOT NULL,
  autonomous_hop        INTEGER NOT NULL CHECK(autonomous_hop>=0),
  mode                  TEXT NOT NULL CHECK(mode IN ('all','any')),
  disposition           TEXT NOT NULL DEFAULT 'pending'
    CHECK(disposition IN ('pending','satisfied','cancelled')),
  aggregate_message_id  TEXT REFERENCES agent_message_metadata(message_id) ON DELETE SET NULL,
  created_at            TEXT NOT NULL,
  resolved_at           TEXT
);

CREATE INDEX IF NOT EXISTS idx_coordination_waits_pending
  ON coordination_waits(disposition,session_id,created_at,wait_id);
CREATE INDEX IF NOT EXISTS idx_coordination_waits_owner
  ON coordination_waits(owner_assignment_id,disposition,created_at,wait_id);

-- A wait that resolves inside its registering `agent_wait` call is returned
-- by that tool result, so it must never also schedule an aggregate continuation.
-- Keep that resolution binding separate from aggregate_message_id: the latter
-- is an actual durable agent message and therefore retains its foreign key.
CREATE TABLE IF NOT EXISTS coordination_wait_inline_results (
  wait_id       TEXT PRIMARY KEY REFERENCES coordination_waits(wait_id) ON DELETE CASCADE,
  consumer_key  TEXT NOT NULL,
  consumed_at   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS coordination_wait_members (
  wait_id             TEXT NOT NULL REFERENCES coordination_waits(wait_id) ON DELETE CASCADE,
  target_kind         TEXT NOT NULL CHECK(target_kind IN (
    'agent_assignment','worker_invocation','reply'
  )),
  target_id           TEXT NOT NULL,
  ordinal             INTEGER NOT NULL CHECK(ordinal>=0),
  disposition         TEXT NOT NULL DEFAULT 'pending'
    CHECK(disposition IN ('pending','satisfied','released')),
  terminal_status     TEXT,
  evidence_reference_json TEXT,
  resolved_at         TEXT,
  PRIMARY KEY(wait_id,target_kind,target_id),
  UNIQUE(wait_id,ordinal)
);

CREATE INDEX IF NOT EXISTS idx_coordination_wait_members_target
  ON coordination_wait_members(target_kind,target_id,disposition,wait_id);

-- Wait handles live in different canonical stores, so cycle detection uses
-- engine-resolved dependency identities instead of interpreting opaque model
-- handles inside tron.sqlite. Keeping these endpoints in an additive side
-- table lets profiles that created the coordination tables on an earlier
-- build acquire the invariant without rewriting either audit table.
CREATE TABLE IF NOT EXISTS coordination_wait_dependency_nodes (
  wait_id         TEXT NOT NULL REFERENCES coordination_waits(wait_id) ON DELETE CASCADE,
  endpoint_kind   TEXT NOT NULL CHECK(endpoint_kind IN ('owner','member')),
  target_kind     TEXT NOT NULL CHECK(target_kind IN (
    'owner','agent_assignment','worker_invocation','reply'
  )),
  target_id       TEXT NOT NULL,
  dependency_id   TEXT NOT NULL,
  ordinal         INTEGER NOT NULL CHECK(ordinal>=-1),
  PRIMARY KEY(wait_id,endpoint_kind,target_kind,target_id),
  UNIQUE(wait_id,ordinal),
  CHECK(
    (endpoint_kind='owner' AND target_kind='owner' AND ordinal=-1) OR
    (endpoint_kind='member' AND target_kind!='owner' AND ordinal>=0)
  )
);

CREATE INDEX IF NOT EXISTS idx_coordination_wait_dependency_identity
  ON coordination_wait_dependency_nodes(dependency_id,wait_id,endpoint_kind);

-- Seal the complete normalized topology supplied by the registering Engine
-- call, including an empty edge set. A replay must match this canonical set
-- before it can publish any new global dependency edge.
CREATE TABLE IF NOT EXISTS coordination_wait_dependency_topologies (
  wait_id        TEXT PRIMARY KEY REFERENCES coordination_waits(wait_id) ON DELETE CASCADE,
  topology_json  TEXT NOT NULL,
  created_at     TEXT NOT NULL,
  CHECK(length(CAST(topology_json AS BLOB)) BETWEEN 2 AND 1048576)
);

-- Mixed execution parentage is immutable. The runtime resolves exact
-- workers.sqlite execution paths before registration and EventStore retains
-- only their normalized dependency edges. These edges outlive an individual
-- wait so every later transaction sees the same causal topology after restart.
CREATE TABLE IF NOT EXISTS coordination_dependency_edges (
  source_dependency_id TEXT NOT NULL,
  target_dependency_id TEXT NOT NULL,
  edge_kind             TEXT NOT NULL CHECK(edge_kind IN ('causal','executor')),
  created_at            TEXT NOT NULL,
  PRIMARY KEY(source_dependency_id,target_dependency_id,edge_kind),
  CHECK(source_dependency_id!=target_dependency_id)
);

CREATE INDEX IF NOT EXISTS idx_coordination_dependency_edges_source
  ON coordination_dependency_edges(source_dependency_id,target_dependency_id);

CREATE TABLE IF NOT EXISTS events (
  id                    TEXT    PRIMARY KEY,
  session_id            TEXT    NOT NULL REFERENCES sessions(id),
  parent_id             TEXT    REFERENCES events(id),
  sequence              INTEGER NOT NULL,
  depth                 INTEGER NOT NULL DEFAULT 0,
  type                  TEXT    NOT NULL,
  timestamp             TEXT    NOT NULL,
  payload               TEXT    NOT NULL,
  content_blob_id       TEXT    REFERENCES blobs(id),
  workspace_id          TEXT    NOT NULL,
  role                  TEXT,
  tool_name  TEXT,
  invocation_id         TEXT,
  turn                  INTEGER,
  input_tokens          INTEGER,
  output_tokens         INTEGER,
  cache_read_tokens     INTEGER,
  cache_creation_tokens INTEGER,
  checksum              TEXT,
  model                 TEXT,
  latency_ms            INTEGER,
  stop_reason           TEXT,
  has_thinking          INTEGER,
  provider_type         TEXT,
  cost                  REAL,
  CHECK (payload IS NOT NULL OR content_blob_id IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_events_session_sequence_unique
  ON events(session_id, sequence);
CREATE INDEX IF NOT EXISTS idx_events_session_seq ON events(session_id, sequence);
CREATE INDEX IF NOT EXISTS idx_events_session_type_sequence
  ON events(session_id, type, sequence DESC);
CREATE INDEX IF NOT EXISTS idx_events_session_invocation
  ON events(session_id, type, tool_name, invocation_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_events_user_input_answer_unique
  ON events(session_id, invocation_id)
  WHERE type='message.user' AND tool_name='request_user_input_answer';

CREATE TABLE IF NOT EXISTS blobs (
  id              TEXT    PRIMARY KEY,
  hash            TEXT    NOT NULL UNIQUE,
  content         BLOB    NOT NULL,
  mime_type       TEXT    NOT NULL DEFAULT 'text/plain',
  uncompressed_size INTEGER NOT NULL,
  size_compressed INTEGER NOT NULL,
  compression     TEXT    NOT NULL DEFAULT 'none',
  created_at      TEXT    NOT NULL,
  ref_count       INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_blobs_hash      ON blobs(hash);
CREATE INDEX IF NOT EXISTS idx_blobs_ref_count ON blobs(ref_count) WHERE ref_count <= 0;

CREATE TABLE IF NOT EXISTS logs (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp       TEXT    NOT NULL,
  level           TEXT    NOT NULL,
  level_num       INTEGER NOT NULL,
  component       TEXT    NOT NULL,
  message         TEXT    NOT NULL,
  session_id      TEXT,
  workspace_id    TEXT,
  event_id        TEXT,
  turn            INTEGER,
  data            TEXT,
  error_message   TEXT,
  error_stack     TEXT,
  trace_id        TEXT,
  parent_trace_id TEXT,
  depth           INTEGER NOT NULL DEFAULT 0
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_logs_client_dedup
  ON logs(timestamp, component, message)
  WHERE component LIKE 'ios.%';

CREATE TABLE IF NOT EXISTS terminals (
  id                TEXT PRIMARY KEY,
  session_id        TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  generation        INTEGER NOT NULL,
  working_directory TEXT NOT NULL,
  shell             TEXT NOT NULL,
  state             TEXT NOT NULL,
  rows              INTEGER NOT NULL,
  columns           INTEGER NOT NULL,
  earliest_sequence INTEGER NOT NULL DEFAULT 0,
  latest_sequence   INTEGER NOT NULL DEFAULT 0,
  created_at        TEXT NOT NULL,
  updated_at        TEXT NOT NULL,
  exited_at         TEXT,
  exit_code         INTEGER,
  interruption_reason TEXT,
  retained_until    TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_terminals_one_running_per_session
  ON terminals(session_id) WHERE state='running';
CREATE INDEX IF NOT EXISTS idx_terminals_session_updated
  ON terminals(session_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_terminals_retention
  ON terminals(retained_until);
