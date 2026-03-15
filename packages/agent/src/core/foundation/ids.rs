//! Branded ID newtypes for type safety.
//!
//! Every entity in the Tron system has a distinct ID type implemented as a
//! newtype wrapper around `String`. This prevents accidentally passing a
//! session ID where an event ID is expected.
//!
//! All IDs are UUID v7 (time-ordered) generated via [`uuid::Uuid::now_v7`].

use serde::{Deserialize, Serialize};
use std::fmt;
use uuid::Uuid;

/// Generate a new UUID v7 string (time-ordered).
fn new_v7() -> String {
    Uuid::now_v7().to_string()
}

macro_rules! branded_id {
    ($(#[$meta:meta])* $name:ident) => {
        $(#[$meta])*
        #[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(String);

        impl $name {
            /// Create a new random ID (UUID v7, time-ordered).
            #[must_use]
            pub fn new() -> Self {
                Self(new_v7())
            }

            /// Create from an existing string value.
            #[must_use]
            pub fn from_string(s: String) -> Self {
                Self(s)
            }

            /// Return the inner string as a slice.
            #[must_use]
            pub fn as_str(&self) -> &str {
                &self.0
            }

            /// Consume self and return the inner `String`.
            #[must_use]
            pub fn into_inner(self) -> String {
                self.0
            }
        }

        impl Default for $name {
            fn default() -> Self {
                Self::new()
            }
        }

        impl std::ops::Deref for $name {
            type Target = str;
            fn deref(&self) -> &str {
                &self.0
            }
        }

        impl AsRef<str> for $name {
            fn as_ref(&self) -> &str {
                &self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }

        impl From<String> for $name {
            fn from(s: String) -> Self {
                Self(s)
            }
        }

        impl From<&str> for $name {
            fn from(s: &str) -> Self {
                Self(s.to_owned())
            }
        }

        impl From<$name> for String {
            fn from(id: $name) -> Self {
                id.0
            }
        }
    };
}

branded_id! {
    /// Unique identifier for a persisted event.
    EventId
}

branded_id! {
    /// Unique identifier for a session.
    SessionId
}

branded_id! {
    /// Unique identifier for a workspace (project directory).
    WorkspaceId
}

branded_id! {
    /// Unique identifier for a tool call within a turn.
    ToolCallId
}

branded_id! {
    /// Unique identifier for a branch within a session.
    BranchId
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_id_new_is_uuid_v7() {
        let id = EventId::new();
        let parsed = Uuid::parse_str(id.as_str()).expect("should be valid UUID");
        assert_eq!(parsed.get_version(), Some(uuid::Version::SortRand));
    }

    #[test]
    fn session_id_new_is_uuid_v7() {
        let id = SessionId::new();
        let parsed = Uuid::parse_str(id.as_str()).expect("should be valid UUID");
        assert_eq!(parsed.get_version(), Some(uuid::Version::SortRand));
    }

    #[test]
    fn workspace_id_new_is_uuid_v7() {
        let id = WorkspaceId::new();
        let parsed = Uuid::parse_str(id.as_str()).expect("should be valid UUID");
        assert_eq!(parsed.get_version(), Some(uuid::Version::SortRand));
    }

    #[test]
    fn ids_are_unique() {
        let a = EventId::new();
        let b = EventId::new();
        assert_ne!(a, b);
    }

    #[test]
    fn from_string() {
        let id = EventId::from_string("custom-id".to_owned());
        assert_eq!(id.as_str(), "custom-id");
    }

    #[test]
    fn from_str_ref() {
        let id = SessionId::from("abc-123");
        assert_eq!(id.as_str(), "abc-123");
    }

    #[test]
    fn deref_to_str() {
        let id = EventId::from("hello");
        let s: &str = &id;
        assert_eq!(s, "hello");
    }

    #[test]
    fn display() {
        let id = EventId::from("display-me");
        assert_eq!(format!("{id}"), "display-me");
    }

    #[test]
    fn into_string() {
        let id = SessionId::from("convert");
        let s: String = id.into();
        assert_eq!(s, "convert");
    }

    #[test]
    fn serde_roundtrip() {
        let id = EventId::from("serde-test");
        let json = serde_json::to_string(&id).unwrap();
        assert_eq!(json, "\"serde-test\"");
        let back: EventId = serde_json::from_str(&json).unwrap();
        assert_eq!(back, id);
    }

    #[test]
    fn serde_in_struct() {
        #[derive(Serialize, Deserialize, Debug, PartialEq)]
        struct Envelope {
            id: EventId,
            session_id: SessionId,
        }

        let env = Envelope {
            id: EventId::from("evt-1"),
            session_id: SessionId::from("sess-1"),
        };
        let json = serde_json::to_string(&env).unwrap();
        let back: Envelope = serde_json::from_str(&json).unwrap();
        assert_eq!(env, back);
    }

    #[test]
    fn hash_and_eq() {
        use std::collections::HashSet;
        let mut set = HashSet::new();
        let id = EventId::from("same");
        let _ = set.insert(id.clone());
        let _ = set.insert(id.clone());
        assert_eq!(set.len(), 1);
    }

    #[test]
    fn default_creates_new() {
        let id1 = EventId::default();
        let id2 = EventId::default();
        assert_ne!(id1, id2, "default should create unique IDs");
    }

    #[test]
    fn into_inner() {
        let id = SessionId::from("inner-test");
        let inner = id.into_inner();
        assert_eq!(inner, "inner-test");
    }
}
