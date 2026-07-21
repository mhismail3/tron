//! Error types for the live capability engine.

/// Result alias for engine operations.
pub type Result<T> = std::result::Result<T, EngineError>;

/// Structured failures returned by engine registration, discovery, and
/// invocation operations.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum EngineError {
    /// A typed id failed validation.
    #[error("invalid {kind} id: {value:?}")]
    InvalidId {
        /// ID kind.
        kind: &'static str,
        /// Rejected value.
        value: String,
    },

    /// A function id was not in namespace::operation form.
    #[error("function id must be in namespace::operation form: {0:?}")]
    InvalidFunctionId(String),

    /// A referenced catalog item does not exist.
    #[error("{kind} not found: {id}")]
    NotFound {
        /// Item kind.
        kind: &'static str,
        /// Missing id.
        id: String,
    },

    /// A registration/update/remove was attempted by the wrong owner.
    #[error("{kind} {id} is owned by {owner}, not {attempted_owner}")]
    OwnerMismatch {
        /// Item kind.
        kind: &'static str,
        /// Item id.
        id: String,
        /// Current owner id.
        owner: String,
        /// Attempted owner id.
        attempted_owner: String,
    },

    /// A worker tried to register outside its namespace claims.
    #[error("worker {worker_id} cannot register function {function_id}; namespace is not claimed")]
    NamespaceDenied {
        /// Worker id.
        worker_id: String,
        /// Function id.
        function_id: String,
    },

    /// A duplicate idempotency key cannot be replayed safely.
    #[error("idempotency conflict for {function_id} key {key:?}: {reason}")]
    IdempotencyConflict {
        /// Function id.
        function_id: String,
        /// Idempotency key.
        key: String,
        /// Conflict reason.
        reason: String,
    },

    /// Durable ledger operation failed.
    #[error("engine ledger operation {operation} failed: {message}")]
    LedgerFailure {
        /// Ledger operation.
        operation: &'static str,
        /// Failure detail.
        message: String,
    },

    /// A stored invocation error was replayed from the ledger.
    #[error("stored invocation error {kind}: {message}")]
    StoredInvocationError {
        /// Stable stored error kind.
        kind: String,
        /// Stable stored message.
        message: String,
    },

    /// A declared schema is unsupported or malformed.
    #[error("invalid {direction} schema for {function_id}: {message}")]
    InvalidSchema {
        /// Function id.
        function_id: String,
        /// Schema direction.
        direction: &'static str,
        /// Validation failure.
        message: String,
    },

    /// A payload did not match a declared schema.
    #[error("{direction} schema violation for {function_id} at {path}: {message}")]
    SchemaViolation {
        /// Function id.
        function_id: String,
        /// Schema direction.
        direction: &'static str,
        /// JSON path.
        path: String,
        /// Validation failure.
        message: String,
    },

    /// A caller attempted to execute a function contract older or newer than
    /// the exact contract it was previously shown.
    #[error(
        "stale function surface for {function_id}: advertised revision {expected_revision}, current revision {actual_revision}"
    )]
    StaleFunctionSurface {
        /// Function selected from the advertised surface.
        function_id: String,
        /// Revision shown to the caller.
        expected_revision: u64,
        /// Revision currently registered.
        actual_revision: u64,
        /// Immutable worker version shown to the caller, for projected workers.
        expected_worker_version: Option<String>,
        /// Immutable worker version currently registered, for projected workers.
        actual_worker_version: Option<String>,
    },

    /// A registration or invocation violates engine policy.
    #[error("policy violation: {0}")]
    PolicyViolation(String),

    /// A domain capability preserved its native error envelope.
    #[error("domain {domain} failed with {code}: {message}")]
    DomainFailure {
        /// Domain namespace.
        domain: String,
        /// Stable domain error code.
        code: String,
        /// Domain error message.
        message: String,
        /// Domain-specific structured details.
        details: Option<serde_json::Value>,
    },

    /// A cooperative in-process invocation was cancelled while its handler ran.
    #[error("invocation cancelled")]
    InvocationCancelled,

    /// The handler returned an application failure.
    #[error("handler failed: {0}")]
    HandlerFailed(String),
}
