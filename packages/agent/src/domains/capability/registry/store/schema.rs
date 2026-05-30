pub(super) const CAPABILITY_REGISTRY_SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS capability_plugins (
  plugin_id TEXT PRIMARY KEY,
  manifest_json TEXT NOT NULL,
  trust_tier TEXT NOT NULL,
  signature_status TEXT NOT NULL,
  conformance_state TEXT NOT NULL,
  catalog_revision INTEGER NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capability_implementations (
  implementation_id TEXT PRIMARY KEY,
  contract_id TEXT NOT NULL,
  function_id TEXT NOT NULL,
  plugin_id TEXT NOT NULL,
  worker_id TEXT NOT NULL,
  schema_digest TEXT NOT NULL,
  catalog_revision INTEGER NOT NULL,
  trust_tier TEXT NOT NULL,
  health TEXT NOT NULL,
  visibility TEXT NOT NULL,
  conformance_state TEXT NOT NULL,
  signature_status TEXT NOT NULL,
  function_json TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capability_index_documents (
  document_key TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  capability_id TEXT NOT NULL,
  contract_id TEXT NOT NULL,
  implementation_id TEXT NOT NULL,
  plugin_id TEXT NOT NULL,
  worker_id TEXT NOT NULL,
  function_id TEXT NOT NULL,
  catalog_revision INTEGER NOT NULL,
  schema_digest TEXT NOT NULL,
  trust_tier TEXT NOT NULL,
  health TEXT NOT NULL,
  visibility TEXT NOT NULL,
  effect_class TEXT NOT NULL,
  risk_level TEXT NOT NULL,
  text TEXT NOT NULL,
  text_hash TEXT NOT NULL DEFAULT '',
  document_json TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capability_vector_metadata (
  name TEXT PRIMARY KEY,
  dimension INTEGER NOT NULL,
  model_id TEXT NOT NULL,
  state TEXT NOT NULL,
  degraded_reason TEXT,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capability_bindings (
  contract_id TEXT NOT NULL,
  scope_kind TEXT NOT NULL,
  scope_value TEXT NOT NULL,
  selected_implementation TEXT NOT NULL,
  selection_policy TEXT NOT NULL,
  secondary_implementations_json TEXT NOT NULL DEFAULT '[]',
  enabled INTEGER NOT NULL CHECK(enabled IN (0, 1)),
  priority INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  PRIMARY KEY(contract_id, scope_kind, scope_value, selected_implementation)
);

CREATE TABLE IF NOT EXISTS capability_inspection_handles (
  handle TEXT PRIMARY KEY,
  contract_id TEXT NOT NULL,
  implementation_id TEXT NOT NULL,
  function_id TEXT NOT NULL,
  catalog_revision INTEGER NOT NULL,
  function_revision INTEGER NOT NULL,
  schema_digest TEXT NOT NULL,
  binding_decision_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capability_binding_decisions (
  id TEXT PRIMARY KEY,
  contract_id TEXT NOT NULL,
  selected_implementation TEXT NOT NULL,
  selected_function_id TEXT NOT NULL,
  selection_policy TEXT NOT NULL,
  rejected_candidates_json TEXT NOT NULL,
  catalog_revision INTEGER NOT NULL,
  schema_digest TEXT NOT NULL,
  plugin_id TEXT NOT NULL,
  worker_id TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capability_audit_events (
  id TEXT PRIMARY KEY,
  event_type TEXT NOT NULL,
  trace_id TEXT,
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capability_program_runs (
  program_run_id TEXT PRIMARY KEY,
  parent_invocation_id TEXT,
  root_invocation_id TEXT NOT NULL,
  binding_decision_id TEXT,
  status TEXT NOT NULL,
  trace_id TEXT NOT NULL,
  code_hash TEXT NOT NULL,
  args_hash TEXT NOT NULL,
  limits_json TEXT NOT NULL,
  allowed_contracts_json TEXT NOT NULL,
  allowed_implementations_json TEXT NOT NULL,
  child_invocations_json TEXT NOT NULL,
  selected_implementations_json TEXT NOT NULL,
  approval_state_json TEXT NOT NULL,
  artifacts_json TEXT NOT NULL,
  logs_json TEXT NOT NULL,
  error_json TEXT NOT NULL,
  compensation_attempts_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capability_pauses (
  pause_id TEXT PRIMARY KEY,
  invocation_id TEXT NOT NULL,
  contract_id TEXT NOT NULL,
  implementation_id TEXT NOT NULL,
  function_id TEXT NOT NULL,
  plugin_id TEXT,
  worker_id TEXT,
  kind TEXT NOT NULL,
  status TEXT NOT NULL,
  prompt_payload_json TEXT NOT NULL,
  resume_schema_json TEXT NOT NULL,
  answer_authority TEXT NOT NULL,
  expires_at TEXT,
  trace_id TEXT,
  root_invocation_id TEXT,
  binding_decision_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS capability_runs (
  run_id TEXT PRIMARY KEY,
  invocation_id TEXT NOT NULL,
  contract_id TEXT NOT NULL,
  implementation_id TEXT NOT NULL,
  function_id TEXT NOT NULL,
  plugin_id TEXT,
  worker_id TEXT,
  status TEXT NOT NULL,
  stream_topic TEXT,
  child_invocations_json TEXT NOT NULL,
  trace_id TEXT,
  root_invocation_id TEXT,
  binding_decision_id TEXT,
  details_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_capability_documents_contract
  ON capability_index_documents(contract_id);
CREATE INDEX IF NOT EXISTS idx_capability_documents_plugin
  ON capability_index_documents(plugin_id);
CREATE INDEX IF NOT EXISTS idx_capability_documents_kind
  ON capability_index_documents(kind);
CREATE INDEX IF NOT EXISTS idx_capability_program_runs_trace
  ON capability_program_runs(trace_id);
CREATE INDEX IF NOT EXISTS idx_capability_program_runs_status
  ON capability_program_runs(status);
CREATE INDEX IF NOT EXISTS idx_capability_program_runs_binding
  ON capability_program_runs(binding_decision_id);
CREATE INDEX IF NOT EXISTS idx_capability_pauses_invocation
  ON capability_pauses(invocation_id);
CREATE INDEX IF NOT EXISTS idx_capability_pauses_status
  ON capability_pauses(status);
CREATE INDEX IF NOT EXISTS idx_capability_runs_invocation
  ON capability_runs(invocation_id);
CREATE INDEX IF NOT EXISTS idx_capability_runs_status
  ON capability_runs(status);
"#;
