//! `/health` and `/health/deep` endpoints.

use std::path::Path;
use std::time::Instant;

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::json;

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
pub fn health_check(start_time: Instant, connections: usize, sessions: usize) -> HealthResponse {
    HealthResponse {
        status: "ok".into(),
        uptime_secs: start_time.elapsed().as_secs(),
        connections,
        active_sessions: sessions,
    }
}

// ── Deep health ───────────────────────────────────────────────────────────

/// Deep health check response with per-subsystem checks.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeepHealthResponse {
    /// Overall status: "healthy", "degraded", or "unhealthy".
    pub status: String,
    /// Seconds since the server started.
    pub uptime_secs: u64,
    /// Current WebSocket connection count.
    pub connections: usize,
    /// Number of active sessions.
    pub active_sessions: usize,
    /// Per-subsystem check results.
    pub checks: Vec<DeepHealthCheck>,
}

/// A single deep health check result.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeepHealthCheck {
    /// Check name.
    pub name: String,
    /// "ok", "warn", or "fail".
    pub status: String,
    /// Optional detail.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<serde_json::Value>,
}

/// Run all deep health checks.
pub fn deep_health_check(
    start_time: Instant,
    connections: usize,
    sessions: usize,
    pool: &crate::events::ConnectionPool,
    tron_home: &Path,
    deploy_dir: &Path,
) -> DeepHealthResponse {
    let checks = vec![
        // 1. Database
        check_database(pool),
        // 2. Settings
        check_settings(&tron_home.join("settings.json")),
        // 3. Auth
        check_auth(&tron_home.join("auth.json")),
        // 4. Skills
        check_skills(&tron_home.join("skills")),
        // 5. Binary
        check_binary(&tron_home.join("tron")),
        // 6. Deploy
        check_deploy(deploy_dir),
        // 7. Disk
        check_disk(tron_home),
    ];

    let has_fail = checks.iter().any(|c| c.status == "fail");
    let has_warn = checks.iter().any(|c| c.status == "warn");
    let status = if has_fail {
        "unhealthy"
    } else if has_warn {
        "degraded"
    } else {
        "healthy"
    };

    DeepHealthResponse {
        status: status.into(),
        uptime_secs: start_time.elapsed().as_secs(),
        connections,
        active_sessions: sessions,
        checks,
    }
}

fn check_database(pool: &crate::events::ConnectionPool) -> DeepHealthCheck {
    match pool.get() {
        Ok(conn) => match conn.query_row("SELECT COUNT(*) FROM sessions", [], |row| {
            row.get::<_, i64>(0)
        }) {
            Ok(session_count) => DeepHealthCheck {
                name: "database".into(),
                status: "ok".into(),
                detail: Some(json!({ "sessions": session_count })),
            },
            Err(error) => DeepHealthCheck {
                name: "database".into(),
                status: "fail".into(),
                detail: Some(json!({ "error": error.to_string() })),
            },
        },
        Err(e) => DeepHealthCheck {
            name: "database".into(),
            status: "fail".into(),
            detail: Some(json!({ "error": e.to_string() })),
        },
    }
}

fn check_settings(path: &Path) -> DeepHealthCheck {
    if !path.exists() {
        return DeepHealthCheck {
            name: "settings".into(),
            status: "ok".into(),
            detail: Some(json!("using defaults")),
        };
    }
    match std::fs::read_to_string(path) {
        Ok(content) => match serde_json::from_str::<serde_json::Value>(&content) {
            Ok(_) => DeepHealthCheck {
                name: "settings".into(),
                status: "ok".into(),
                detail: None,
            },
            Err(e) => DeepHealthCheck {
                name: "settings".into(),
                status: "fail".into(),
                detail: Some(json!({ "error": e.to_string() })),
            },
        },
        Err(e) => DeepHealthCheck {
            name: "settings".into(),
            status: "fail".into(),
            detail: Some(json!({ "error": e.to_string() })),
        },
    }
}

fn check_auth(path: &Path) -> DeepHealthCheck {
    match std::fs::read_to_string(path) {
        Ok(content) => match serde_json::from_str::<serde_json::Value>(&content) {
            Ok(v) => {
                let count = v.as_object().map_or(0, serde_json::Map::len);
                if count == 0 {
                    DeepHealthCheck {
                        name: "auth".into(),
                        status: "warn".into(),
                        detail: Some(json!("empty auth.json")),
                    }
                } else {
                    DeepHealthCheck {
                        name: "auth".into(),
                        status: "ok".into(),
                        detail: Some(json!({ "providers": count })),
                    }
                }
            }
            Err(e) => DeepHealthCheck {
                name: "auth".into(),
                status: "fail".into(),
                detail: Some(json!({ "error": e.to_string() })),
            },
        },
        Err(_) => DeepHealthCheck {
            name: "auth".into(),
            status: "warn".into(),
            detail: Some(json!("auth.json not found")),
        },
    }
}

fn check_skills(path: &Path) -> DeepHealthCheck {
    if !path.is_dir() {
        return DeepHealthCheck {
            name: "skills".into(),
            status: "warn".into(),
            detail: Some(json!("skills directory not found")),
        };
    }
    match std::fs::read_dir(path) {
        Ok(entries) => {
            let count = entries
                .filter_map(Result::ok)
                .filter(|e| e.path().is_dir())
                .count();
            DeepHealthCheck {
                name: "skills".into(),
                status: "ok".into(),
                detail: Some(json!({ "count": count })),
            }
        }
        Err(error) => DeepHealthCheck {
            name: "skills".into(),
            status: "warn".into(),
            detail: Some(json!({ "error": error.to_string() })),
        },
    }
}

fn check_binary(path: &Path) -> DeepHealthCheck {
    use std::os::unix::fs::PermissionsExt;
    match std::fs::metadata(path) {
        Ok(meta) => {
            let executable = meta.permissions().mode() & 0o111 != 0;
            if executable {
                DeepHealthCheck {
                    name: "binary".into(),
                    status: "ok".into(),
                    detail: None,
                }
            } else {
                DeepHealthCheck {
                    name: "binary".into(),
                    status: "fail".into(),
                    detail: Some(json!("not executable")),
                }
            }
        }
        Err(_) => DeepHealthCheck {
            name: "binary".into(),
            status: "warn".into(),
            detail: Some(json!("binary not found")),
        },
    }
}

fn check_deploy(deploy_dir: &Path) -> DeepHealthCheck {
    let sentinel = read_optional_json::<crate::server::deploy::RestartSentinel>(
        &deploy_dir.join("restart-sentinel.json"),
    );
    let last_deploy =
        read_optional_json::<serde_json::Value>(&deploy_dir.join("last-deployment.json"));

    let mut status = CheckLevel::Ok;
    let mut detail = serde_json::Map::new();

    match sentinel {
        OptionalJsonArtifact::Missing => {
            let _ = detail.insert("sentinelStatus".into(), json!("none"));
        }
        OptionalJsonArtifact::Present(sentinel) => {
            let _ = detail.insert("sentinelStatus".into(), json!(sentinel.status));
            status = match sentinel.status.as_str() {
                "completed" => CheckLevel::Ok,
                "failed" | "rolled_back" => CheckLevel::Fail,
                _ => CheckLevel::Warn,
            };
        }
        OptionalJsonArtifact::Invalid(error) => {
            let _ = detail.insert("sentinelStatus".into(), json!("invalid"));
            let _ = detail.insert("sentinelError".into(), json!(error));
            status = CheckLevel::Fail;
        }
    }

    match last_deploy {
        OptionalJsonArtifact::Missing => {
            let _ = detail.insert("lastDeployment".into(), serde_json::Value::Null);
        }
        OptionalJsonArtifact::Present(last_deployment) => {
            let _ = detail.insert("lastDeployment".into(), last_deployment);
        }
        OptionalJsonArtifact::Invalid(error) => {
            let _ = detail.insert("lastDeployment".into(), serde_json::Value::Null);
            let _ = detail.insert("lastDeploymentError".into(), json!(error));
            status = status.max(CheckLevel::Warn);
        }
    }

    DeepHealthCheck {
        name: "deploy".into(),
        status: status.as_str().into(),
        detail: Some(serde_json::Value::Object(detail)),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum CheckLevel {
    Ok,
    Warn,
    Fail,
}

impl CheckLevel {
    fn as_str(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Warn => "warn",
            Self::Fail => "fail",
        }
    }
}

enum OptionalJsonArtifact<T> {
    Missing,
    Present(T),
    Invalid(String),
}

fn read_optional_json<T>(path: &Path) -> OptionalJsonArtifact<T>
where
    T: DeserializeOwned,
{
    match std::fs::read_to_string(path) {
        Ok(contents) => match serde_json::from_str(&contents) {
            Ok(value) => OptionalJsonArtifact::Present(value),
            Err(error) => OptionalJsonArtifact::Invalid(error.to_string()),
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => OptionalJsonArtifact::Missing,
        Err(error) => OptionalJsonArtifact::Invalid(error.to_string()),
    }
}

fn check_disk(tron_home: &Path) -> DeepHealthCheck {
    disk_check_from_result(crate::server::disk::available_megabytes(tron_home))
}

fn disk_check_from_result(result: std::io::Result<u64>) -> DeepHealthCheck {
    match result {
        Ok(mb) if mb < 100 => DeepHealthCheck {
            name: "disk".into(),
            status: "fail".into(),
            detail: Some(json!({ "freeMb": mb })),
        },
        Ok(mb) if mb < 500 => DeepHealthCheck {
            name: "disk".into(),
            status: "warn".into(),
            detail: Some(json!({ "freeMb": mb })),
        },
        Ok(mb) => DeepHealthCheck {
            name: "disk".into(),
            status: "ok".into(),
            detail: Some(json!({ "freeMb": mb })),
        },
        Err(error) => DeepHealthCheck {
            name: "disk".into(),
            status: "warn".into(),
            detail: Some(json!({ "error": error.to_string() })),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::deploy::{RestartSentinel, write_sentinel};

    fn sample_restart_sentinel(status: &str) -> RestartSentinel {
        RestartSentinel {
            action: "deploy".into(),
            timestamp: "2026-03-12T10:00:00.000Z".into(),
            commit: "abc123".into(),
            previous_commit: "def456".into(),
            status: status.into(),
            completed_at: None,
            initiated_by: Some("api".into()),
            self_test: None,
        }
    }

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

    #[test]
    fn deep_health_serialization() {
        let resp = DeepHealthResponse {
            status: "healthy".into(),
            uptime_secs: 100,
            connections: 2,
            active_sessions: 1,
            checks: vec![
                DeepHealthCheck {
                    name: "database".into(),
                    status: "ok".into(),
                    detail: Some(json!({"sessions": 5})),
                },
                DeepHealthCheck {
                    name: "disk".into(),
                    status: "ok".into(),
                    detail: None,
                },
            ],
        };
        let json_str = serde_json::to_string(&resp).unwrap();
        let v: serde_json::Value = serde_json::from_str(&json_str).unwrap();
        assert_eq!(v["status"], "healthy");
        assert_eq!(v["checks"][0]["name"], "database");
        assert_eq!(v["checks"][0]["status"], "ok");
        assert!(!json_str.contains("detail\":null")); // skip_serializing_if
    }

    #[test]
    fn deep_health_status_logic() {
        // All ok = healthy
        let checks = [DeepHealthCheck {
            name: "test".into(),
            status: "ok".into(),
            detail: None,
        }];
        assert!(
            checks
                .iter()
                .all(|c| c.status != "fail" && c.status != "warn")
        );

        // Any warn = degraded
        let checks = [
            DeepHealthCheck {
                name: "a".into(),
                status: "ok".into(),
                detail: None,
            },
            DeepHealthCheck {
                name: "b".into(),
                status: "warn".into(),
                detail: None,
            },
        ];
        let has_fail = checks.iter().any(|c| c.status == "fail");
        let has_warn = checks.iter().any(|c| c.status == "warn");
        assert!(!has_fail);
        assert!(has_warn);

        // Any fail = unhealthy
        let checks = [
            DeepHealthCheck {
                name: "a".into(),
                status: "ok".into(),
                detail: None,
            },
            DeepHealthCheck {
                name: "b".into(),
                status: "fail".into(),
                detail: None,
            },
        ];
        let has_fail = checks.iter().any(|c| c.status == "fail");
        assert!(has_fail);
    }

    #[test]
    fn database_check_fails_when_sessions_query_fails() {
        let pool = crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
        let check = check_database(&pool);
        assert_eq!(check.name, "database");
        assert_eq!(check.status, "fail");
        assert!(
            check
                .detail
                .as_ref()
                .and_then(|detail| detail.get("error"))
                .is_some()
        );
    }

    #[test]
    fn deploy_check_fails_when_sentinel_reports_failed() {
        let dir = tempfile::tempdir().unwrap();
        write_sentinel(dir.path(), &sample_restart_sentinel("failed")).unwrap();

        let check = check_deploy(dir.path());
        assert_eq!(check.name, "deploy");
        assert_eq!(check.status, "fail");
        assert_eq!(
            check.detail.as_ref().unwrap()["sentinelStatus"],
            serde_json::Value::String("failed".into())
        );
    }

    #[test]
    fn deploy_check_warns_on_invalid_last_deployment_json() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("last-deployment.json"), "{ not valid json").unwrap();

        let check = check_deploy(dir.path());
        assert_eq!(check.name, "deploy");
        assert_eq!(check.status, "warn");
        assert!(
            check
                .detail
                .as_ref()
                .and_then(|detail| detail.get("lastDeploymentError"))
                .is_some()
        );
    }

    #[test]
    fn deploy_check_fails_on_invalid_sentinel_json() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("restart-sentinel.json"), "{ not valid json").unwrap();

        let check = check_deploy(dir.path());
        assert_eq!(check.name, "deploy");
        assert_eq!(check.status, "fail");
        assert_eq!(
            check.detail.as_ref().unwrap()["sentinelStatus"],
            serde_json::Value::String("invalid".into())
        );
        assert!(
            check
                .detail
                .as_ref()
                .and_then(|detail| detail.get("sentinelError"))
                .is_some()
        );
    }

    #[test]
    fn disk_check_warns_on_probe_error() {
        let check = disk_check_from_result(Err(std::io::Error::other("statvfs failed")));
        assert_eq!(check.name, "disk");
        assert_eq!(check.status, "warn");
        assert!(check.detail.is_some());
    }

    #[test]
    fn disk_check_classifies_free_space_thresholds() {
        assert_eq!(disk_check_from_result(Ok(99)).status, "fail");
        assert_eq!(disk_check_from_result(Ok(250)).status, "warn");
        assert_eq!(disk_check_from_result(Ok(900)).status, "ok");
    }
}
