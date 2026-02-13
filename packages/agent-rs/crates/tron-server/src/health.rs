//! `/health` endpoint.

use serde::Serialize;
use std::time::Instant;

/// Health check response body.
#[derive(Debug, Clone, Serialize)]
pub struct HealthResponse {
    /// Always `"ok"` when the server is running.
    pub status: String,
    /// Seconds since the server started.
    pub uptime_secs: u64,
    /// Current WebSocket connection count.
    pub connections: usize,
    /// Number of active sessions.
    pub active_sessions: usize,
}

/// Build a health response from live counters.
pub fn health_check(
    start_time: Instant,
    connections: usize,
    sessions: usize,
) -> HealthResponse {
    HealthResponse {
        status: "ok".into(),
        uptime_secs: start_time.elapsed().as_secs(),
        connections,
        active_sessions: sessions,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_is_ok() {
        let resp = health_check(Instant::now(), 0, 0);
        assert_eq!(resp.status, "ok");
    }

    #[test]
    fn uptime_starts_at_zero() {
        let resp = health_check(Instant::now(), 0, 0);
        assert!(resp.uptime_secs < 2);
    }

    #[test]
    fn uptime_increases() {
        let start = Instant::now()
            .checked_sub(std::time::Duration::from_secs(60))
            .unwrap();
        let resp = health_check(start, 0, 0);
        assert!(resp.uptime_secs >= 59);
    }

    #[test]
    fn connections_and_sessions_tracked() {
        let resp = health_check(Instant::now(), 5, 3);
        assert_eq!(resp.connections, 5);
        assert_eq!(resp.active_sessions, 3);
    }

    #[test]
    fn serialization() {
        let resp = health_check(Instant::now(), 2, 1);
        let json = serde_json::to_string(&resp).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["status"], "ok");
        assert_eq!(parsed["connections"], 2);
        assert_eq!(parsed["active_sessions"], 1);
        assert!(parsed["uptime_secs"].is_number());
    }

    #[test]
    fn zero_counters() {
        let resp = health_check(Instant::now(), 0, 0);
        assert_eq!(resp.connections, 0);
        assert_eq!(resp.active_sessions, 0);
    }
}
