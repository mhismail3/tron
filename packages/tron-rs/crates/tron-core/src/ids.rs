use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;
use uuid::Uuid;

macro_rules! branded_id {
    ($name:ident, $prefix:expr) => {
        #[derive(Clone, Debug, Hash, Eq, PartialEq, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(String);

        impl $name {
            pub fn new() -> Self {
                Self(format!("{}_{}", $prefix, Uuid::now_v7()))
            }

            pub fn from_raw(s: impl Into<String>) -> Self {
                Self(s.into())
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl Default for $name {
            fn default() -> Self {
                Self::new()
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }

        impl FromStr for $name {
            type Err = std::convert::Infallible;
            fn from_str(s: &str) -> Result<Self, Self::Err> {
                Ok(Self(s.to_owned()))
            }
        }

        impl AsRef<str> for $name {
            fn as_ref(&self) -> &str {
                &self.0
            }
        }
    };
}

branded_id!(SessionId, "sess");
branded_id!(EventId, "evt");
branded_id!(ToolCallId, "toolu");
branded_id!(AgentId, "agent");
branded_id!(WorkspaceId, "ws");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_id_has_prefix() {
        let id = SessionId::new();
        assert!(id.as_str().starts_with("sess_"), "got: {id}");
    }

    #[test]
    fn event_id_has_prefix() {
        let id = EventId::new();
        assert!(id.as_str().starts_with("evt_"), "got: {id}");
    }

    #[test]
    fn tool_call_id_has_prefix() {
        let id = ToolCallId::new();
        assert!(id.as_str().starts_with("toolu_"), "got: {id}");
    }

    #[test]
    fn agent_id_has_prefix() {
        let id = AgentId::new();
        assert!(id.as_str().starts_with("agent_"), "got: {id}");
    }

    #[test]
    fn workspace_id_has_prefix() {
        let id = WorkspaceId::new();
        assert!(id.as_str().starts_with("ws_"), "got: {id}");
    }

    #[test]
    fn ids_are_unique() {
        let a = SessionId::new();
        let b = SessionId::new();
        assert_ne!(a, b);
    }

    #[test]
    fn display_and_from_str_roundtrip() {
        let id = SessionId::new();
        let s = id.to_string();
        let parsed: SessionId = s.parse().unwrap();
        assert_eq!(id, parsed);
    }

    #[test]
    fn serde_roundtrip() {
        let id = SessionId::new();
        let json = serde_json::to_string(&id).unwrap();
        let parsed: SessionId = serde_json::from_str(&json).unwrap();
        assert_eq!(id, parsed);
    }

    #[test]
    fn from_raw_preserves_value() {
        let id = SessionId::from_raw("custom-id-123");
        assert_eq!(id.as_str(), "custom-id-123");
    }

    #[test]
    fn monotonic_ordering() {
        let ids: Vec<SessionId> = (0..100).map(|_| SessionId::new()).collect();
        for w in ids.windows(2) {
            assert!(w[0].as_str() < w[1].as_str(), "not monotonic: {} >= {}", w[0], w[1]);
        }
    }
}
