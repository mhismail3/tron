//! `/health` and `/health/deep` endpoints.

use std::path::Path;
use std::time::Instant;

use serde::Serialize;
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
    pool: &tron_events::ConnectionPool,
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

fn check_database(pool: &tron_events::ConnectionPool) -> DeepHealthCheck {
    match pool.get() {
        Ok(conn) => {
            let session_count: i64 = conn
                .query_row("SELECT COUNT(*) FROM sessions", [], |row| row.get(0))
                .unwrap_or(-1);
            DeepHealthCheck {
                name: "database".into(),
                status: "ok".into(),
                detail: Some(json!({ "sessions": session_count })),
            }
        }
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
    let count = std::fs::read_dir(path)
        .map(|entries| {
            entries
                .filter_map(Result::ok)
                .filter(|e| e.path().is_dir())
                .count()
        })
        .unwrap_or(0);
    DeepHealthCheck {
        name: "skills".into(),
        status: "ok".into(),
        detail: Some(json!({ "count": count })),
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
    let sentinel = crate::deploy::read_sentinel(deploy_dir);
    let last_deploy = std::fs::read_to_string(deploy_dir.join("last-deployment.json"))
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok());

    let status = sentinel
        .as_ref()
        .map_or("none", |s| s.status.as_str());

    let check_status = if status == "restarting" { "warn" } else { "ok" };

    DeepHealthCheck {
        name: "deploy".into(),
        status: check_status.into(),
        detail: Some(json!({
            "sentinelStatus": status,
            "lastDeployment": last_deploy,
        })),
    }
}

fn check_disk(tron_home: &Path) -> DeepHealthCheck {
    let dir = tron_home.to_string_lossy();
    match std::process::Command::new("df")
        .args(["-m", &dir])
        .output()
    {
        Ok(output) if output.status.success() => {
            let text = String::from_utf8_lossy(&output.stdout);
            let free_mb: Option<u64> = text
                .lines()
                .nth(1)
                .and_then(|line| line.split_whitespace().nth(3))
                .and_then(|s| s.parse().ok());
            match free_mb {
                Some(mb) if mb < 100 => DeepHealthCheck {
                    name: "disk".into(),
                    status: "fail".into(),
                    detail: Some(json!({ "freeMb": mb })),
                },
                Some(mb) if mb < 500 => DeepHealthCheck {
                    name: "disk".into(),
                    status: "warn".into(),
                    detail: Some(json!({ "freeMb": mb })),
                },
                Some(mb) => DeepHealthCheck {
                    name: "disk".into(),
                    status: "ok".into(),
                    detail: Some(json!({ "freeMb": mb })),
                },
                None => DeepHealthCheck {
                    name: "disk".into(),
                    status: "ok".into(),
                    detail: Some(json!("could not parse df output")),
                },
            }
        }
        _ => DeepHealthCheck {
            name: "disk".into(),
            status: "ok".into(),
            detail: Some(json!("df command failed")),
        },
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
        let checks = vec![DeepHealthCheck {
            name: "test".into(),
            status: "ok".into(),
            detail: None,
        }];
        assert!(checks.iter().all(|c| c.status != "fail" && c.status != "warn"));

        // Any warn = degraded
        let checks = vec![
            DeepHealthCheck { name: "a".into(), status: "ok".into(), detail: None },
            DeepHealthCheck { name: "b".into(), status: "warn".into(), detail: None },
        ];
        let has_fail = checks.iter().any(|c| c.status == "fail");
        let has_warn = checks.iter().any(|c| c.status == "warn");
        assert!(!has_fail);
        assert!(has_warn);

        // Any fail = unhealthy
        let checks = vec![
            DeepHealthCheck { name: "a".into(), status: "ok".into(), detail: None },
            DeepHealthCheck { name: "b".into(), status: "fail".into(), detail: None },
        ];
        let has_fail = checks.iter().any(|c| c.status == "fail");
        assert!(has_fail);
    }
}
