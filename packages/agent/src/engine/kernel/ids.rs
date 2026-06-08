//! Typed string IDs used by the engine.

use std::fmt;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use super::errors::{EngineError, Result};

fn new_v7() -> String {
    Uuid::now_v7().to_string()
}

fn validate_non_empty(kind: &'static str, value: &str) -> Result<()> {
    if value.trim().is_empty() {
        return Err(EngineError::InvalidId {
            kind,
            value: value.to_owned(),
        });
    }
    Ok(())
}

macro_rules! engine_id {
    ($name:ident, $kind:literal) => {
        #[doc = concat!("Validated engine id for ", $kind, " entries.")]
        #[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(String);

        impl $name {
            /// Generate a UUIDv7-backed id.
            #[must_use]
            pub fn generate() -> Self {
                Self(new_v7())
            }

            /// Create a validated id from a string.
            pub fn new(value: impl Into<String>) -> Result<Self> {
                let value = value.into();
                validate_non_empty($kind, &value)?;
                Ok(Self(value))
            }

            /// Return the inner string.
            #[must_use]
            pub fn as_str(&self) -> &str {
                &self.0
            }

            /// Consume the id.
            #[must_use]
            pub fn into_inner(self) -> String {
                self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }
    };
}

engine_id!(WorkerId, "worker");
engine_id!(TriggerId, "trigger");
engine_id!(TriggerTypeId, "trigger_type");
engine_id!(InvocationId, "invocation");
engine_id!(ActorId, "actor");
engine_id!(AuthorityGrantId, "authority_grant");
engine_id!(TraceId, "trace");

/// Stable function identifier in `namespace::operation` form.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct FunctionId(String);

impl FunctionId {
    /// Create a validated function id.
    pub fn new(value: impl Into<String>) -> Result<Self> {
        let value = value.into();
        validate_non_empty("function", &value)?;
        let Some((namespace, operation)) = value.split_once("::") else {
            return Err(EngineError::InvalidFunctionId(value));
        };
        if namespace.is_empty() || operation.is_empty() || operation.contains("::") {
            return Err(EngineError::InvalidFunctionId(value));
        }
        Ok(Self(value))
    }

    /// Return the namespace prefix before `::`.
    #[must_use]
    pub fn namespace(&self) -> &str {
        self.0
            .split_once("::")
            .map_or("", |(namespace, _)| namespace)
    }

    /// Return the inner string.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Consume the id.
    #[must_use]
    pub fn into_inner(self) -> String {
        self.0
    }
}

impl fmt::Display for FunctionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}
