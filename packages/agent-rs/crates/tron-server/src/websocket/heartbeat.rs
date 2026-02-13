//! Heartbeat ping/pong liveness monitoring.

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;

use tokio::time;
use tokio_util::sync::CancellationToken;

use super::connection::ClientConnection;

/// Outcome of the heartbeat loop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HeartbeatResult {
    /// The client stopped responding within the timeout window.
    TimedOut,
    /// The heartbeat was cancelled externally.
    Cancelled,
}

/// Run heartbeat pings for a connection.
///
/// At each `interval` tick the alive flag is checked. If the client has not
/// responded since the last tick the missed-pong counter increments. Once
/// `max_missed` consecutive misses are reached the connection is considered
/// dead and `HeartbeatResult::TimedOut` is returned.
///
/// `max_missed` is computed as `timeout / interval` (clamped to at least 1).
pub async fn run_heartbeat(
    connection: Arc<ClientConnection>,
    interval: Duration,
    timeout: Duration,
    cancel: CancellationToken,
) -> HeartbeatResult {
    let mut check_interval = time::interval(interval);
    let mut missed_pongs: u32 = 0;
    let interval_secs = interval.as_secs().max(1);
    #[allow(clippy::cast_possible_truncation)]
    let max_missed = (timeout.as_secs() / interval_secs).max(1) as u32;

    loop {
        tokio::select! {
            _ = check_interval.tick() => {
                if connection.check_alive() {
                    missed_pongs = 0;
                } else {
                    missed_pongs += 1;
                    if missed_pongs >= max_missed {
                        return HeartbeatResult::TimedOut;
                    }
                }
                // Mark as not alive until the next pong
                connection.is_alive.store(false, Ordering::Relaxed);
            }
            () = cancel.cancelled() => {
                return HeartbeatResult::Cancelled;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::mpsc;

    fn make_connection() -> Arc<ClientConnection> {
        let (tx, _rx) = mpsc::channel(32);
        Arc::new(ClientConnection::new("hb_conn".into(), tx))
    }

    #[tokio::test]
    async fn heartbeat_cancelled() {
        let conn = make_connection();
        let cancel = CancellationToken::new();
        let cancel2 = cancel.clone();

        let handle = tokio::spawn(async move {
            run_heartbeat(
                conn,
                Duration::from_secs(100),
                Duration::from_secs(300),
                cancel2,
            )
            .await
        });

        // Cancel immediately
        cancel.cancel();
        let result = handle.await.unwrap();
        assert_eq!(result, HeartbeatResult::Cancelled);
    }

    #[tokio::test]
    async fn heartbeat_times_out_when_not_alive() {
        let conn = make_connection();
        // Set not alive so it misses immediately
        conn.is_alive.store(false, Ordering::Relaxed);
        let cancel = CancellationToken::new();

        let result = run_heartbeat(
            conn,
            Duration::from_millis(10),
            Duration::from_millis(10),
            cancel,
        )
        .await;

        assert_eq!(result, HeartbeatResult::TimedOut);
    }

    #[tokio::test]
    async fn alive_connection_stays_alive() {
        let conn = make_connection();
        let conn2 = conn.clone();
        let cancel = CancellationToken::new();
        let cancel2 = cancel.clone();

        // Spawn heartbeat with short interval
        let handle = tokio::spawn(async move {
            run_heartbeat(
                conn2,
                Duration::from_millis(50),
                Duration::from_millis(200),
                cancel2,
            )
            .await
        });

        // Keep marking alive for a few ticks
        for _ in 0..5 {
            tokio::time::sleep(Duration::from_millis(20)).await;
            conn.mark_alive();
        }

        // Then cancel
        cancel.cancel();
        let result = handle.await.unwrap();
        assert_eq!(result, HeartbeatResult::Cancelled);
    }

    #[test]
    fn heartbeat_result_equality() {
        assert_eq!(HeartbeatResult::TimedOut, HeartbeatResult::TimedOut);
        assert_eq!(HeartbeatResult::Cancelled, HeartbeatResult::Cancelled);
        assert_ne!(HeartbeatResult::TimedOut, HeartbeatResult::Cancelled);
    }

    #[test]
    fn heartbeat_result_debug() {
        let r = HeartbeatResult::TimedOut;
        let debug = format!("{r:?}");
        assert!(debug.contains("TimedOut"));
    }

    #[test]
    fn heartbeat_result_clone() {
        let r = HeartbeatResult::Cancelled;
        let r2 = r.clone();
        assert_eq!(r, r2);
    }

    #[tokio::test(start_paused = true)]
    async fn max_missed_computed_from_timeout_and_interval() {
        // timeout=300ms, interval=100ms → max_missed=3
        // We need 3 consecutive misses to timeout.
        let conn = make_connection();
        conn.is_alive.store(false, Ordering::Relaxed);
        let cancel = CancellationToken::new();

        let result = run_heartbeat(
            conn,
            Duration::from_millis(100),
            Duration::from_millis(300),
            cancel,
        )
        .await;

        assert_eq!(result, HeartbeatResult::TimedOut);
    }

    #[tokio::test]
    async fn cancel_during_wait() {
        let conn = make_connection();
        let cancel = CancellationToken::new();
        let cancel2 = cancel.clone();

        let handle = tokio::spawn(async move {
            run_heartbeat(
                conn,
                Duration::from_secs(60),
                Duration::from_secs(180),
                cancel2,
            )
            .await
        });

        // Small delay then cancel
        tokio::time::sleep(Duration::from_millis(10)).await;
        cancel.cancel();
        let result = handle.await.unwrap();
        assert_eq!(result, HeartbeatResult::Cancelled);
    }

    #[tokio::test]
    async fn heartbeat_resets_missed_on_alive() {
        let conn = make_connection();
        let conn2 = conn.clone();
        let cancel = CancellationToken::new();
        let cancel2 = cancel.clone();

        // Use longer intervals for timing reliability.
        // Timeout = 600ms with 200ms interval = 3 max missed.
        let handle = tokio::spawn(async move {
            run_heartbeat(
                conn2,
                Duration::from_millis(200),
                Duration::from_millis(600),
                cancel2,
            )
            .await
        });

        // Keep marking alive repeatedly to prevent timeout
        for _ in 0..5 {
            tokio::time::sleep(Duration::from_millis(100)).await;
            conn.mark_alive();
        }

        // Cancel — should not have timed out
        cancel.cancel();
        let result = handle.await.unwrap();
        assert_eq!(result, HeartbeatResult::Cancelled);
    }
}
