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

    /// A function revision expectation was stale.
    #[error("function {function_id} revision mismatch: expected {expected}, actual {actual}")]
    StaleFunctionRevision {
        /// Function id.
        function_id: String,
        /// Expected revision.
        expected: u64,
        /// Actual revision.
        actual: u64,
    },

    /// A delivery mode is not implemented for execution in Phase 1.
    #[error("delivery mode {mode} is not executable in phase 1")]
    UnsupportedDeliveryMode {
        /// Requested delivery mode.
        mode: &'static str,
    },

    /// A delivery mode is not allowed by a definition.
    #[error("delivery mode {mode} is not allowed for {function_id}")]
    DeliveryModeNotAllowed {
        /// Function id.
        function_id: String,
        /// Requested delivery mode.
        mode: &'static str,
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

    /// A historical stored invocation error was replayed from the ledger.
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

    /// A visibility promotion is not allowed.
    #[error("invalid visibility promotion for {function_id} to {target}: {reason}")]
    InvalidVisibilityPromotion {
        /// Function id.
        function_id: String,
        /// Requested visibility target.
        target: String,
        /// Rejection reason.
        reason: String,
    },

    /// A registration or invocation violates engine policy.
    #[error("policy violation: {0}")]
    PolicyViolation(String),

    /// A function is present but cannot currently be routed.
    #[error("function {function_id} is not routable: {reason}")]
    NotRoutable {
        /// Function id.
        function_id: String,
        /// Reason it cannot be called.
        reason: String,
    },

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

    /// The transport to a worker failed before the engine received a function result.
    #[error("worker transport failed with {code}: {message}")]
    WorkerTransportFailure {
        /// Stable transport failure code.
        code: String,
        /// Transport failure detail.
        message: String,
    },

    /// The handler returned an application failure.
    #[error("handler failed: {0}")]
    HandlerFailed(String),
}
