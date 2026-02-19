//! Multi-session browser service.

use std::path::PathBuf;
use std::sync::Arc;

use dashmap::DashMap;
use tokio::sync::broadcast;

use super::error::BrowserError;
use super::session::BrowserSession;
use super::types::{BrowserEvent, BrowserStatus, ScreencastOptions};

/// Manages per-session browser instances with screencast streaming.
pub struct BrowserService {
    chrome_path: PathBuf,
    sessions: DashMap<String, Arc<BrowserSession>>,
    frame_tx: broadcast::Sender<BrowserEvent>,
}

impl BrowserService {
    /// Create a new browser service.
    ///
    /// # Arguments
    /// - `chrome_path`: Path to the Chrome/Chromium executable.
    pub fn new(chrome_path: PathBuf) -> Self {
        let (frame_tx, _) = broadcast::channel(64);
        Self {
            chrome_path,
            sessions: DashMap::new(),
            frame_tx,
        }
    }

    /// Get the Chrome path this service is configured with.
    pub fn chrome_path(&self) -> &std::path::Path {
        &self.chrome_path
    }

    /// Number of active sessions.
    pub fn session_count(&self) -> usize {
        self.sessions.len()
    }

    /// Get or create a browser session for the given session ID.
    pub async fn get_or_create(
        &self,
        session_id: &str,
    ) -> Result<Arc<BrowserSession>, BrowserError> {
        if let Some(session) = self.sessions.get(session_id) {
            return Ok(Arc::clone(session.value()));
        }

        let session = Arc::new(
            BrowserSession::launch(&self.chrome_path, self.frame_tx.clone())
                .await
                .map_err(|e| {
                    tracing::error!(session_id, error = %e, "browser session creation failed");
                    e
                })?,
        );
        let _ = self
            .sessions
            .insert(session_id.to_string(), Arc::clone(&session));
        metrics::gauge!("browser_sessions_active").increment(1.0);
        tracing::info!(session_id, "browser session created");
        Ok(session)
    }

    /// Start screencast streaming for a session.
    ///
    /// Creates the session if it doesn't exist.
    pub async fn start_stream(&self, session_id: &str) -> Result<(), BrowserError> {
        let session = self.get_or_create(session_id).await?;
        session
            .start_screencast(session_id.to_string(), ScreencastOptions::default())
            .await?;
        tracing::info!(session_id, "screencast streaming started");
        Ok(())
    }

    /// Stop screencast streaming for a session.
    ///
    /// No-op if the session doesn't exist.
    pub async fn stop_stream(&self, session_id: &str) -> Result<(), BrowserError> {
        if let Some(session) = self.sessions.get(session_id) {
            session.stop_screencast().await?;
            tracing::info!(session_id, "screencast streaming stopped");
        }
        Ok(())
    }

    /// Get the status of a browser session.
    pub fn get_status(&self, session_id: &str) -> BrowserStatus {
        match self.sessions.get(session_id) {
            Some(session) => BrowserStatus {
                has_browser: true,
                is_streaming: session.is_streaming(),
                current_url: session.current_url(),
            },
            None => BrowserStatus::default(),
        }
    }

    /// Close and remove a browser session.
    pub async fn close_session(&self, session_id: &str) -> Result<(), BrowserError> {
        if let Some((_, session)) = self.sessions.remove(session_id) {
            // Try to extract the session from Arc; if others hold refs, just stop screencast
            match Arc::try_unwrap(session) {
                Ok(owned) => {
                    owned.close().await?;
                }
                Err(shared) => {
                    shared.stop_screencast().await?;
                }
            }
            let _ = self.frame_tx.send(BrowserEvent::Closed {
                session_id: session_id.to_string(),
            });
            metrics::gauge!("browser_sessions_active").decrement(1.0);
            tracing::info!(session_id, "browser session closed");
        }
        Ok(())
    }

    /// Subscribe to browser events (frames, closed).
    pub fn subscribe(&self) -> broadcast::Receiver<BrowserEvent> {
        self.frame_tx.subscribe()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_service() -> BrowserService {
        BrowserService::new(PathBuf::from("/usr/bin/false"))
    }

    #[test]
    fn service_new_creates_empty() {
        let svc = make_service();
        assert_eq!(svc.session_count(), 0);
    }

    #[test]
    fn service_subscribe_returns_receiver() {
        let svc = make_service();
        let _rx = svc.subscribe();
    }

    #[test]
    fn service_status_unknown_session() {
        let svc = make_service();
        let status = svc.get_status("nonexistent");
        assert!(!status.has_browser);
        assert!(!status.is_streaming);
        assert!(status.current_url.is_none());
    }

    #[tokio::test]
    async fn service_stop_stream_unknown_session_is_ok() {
        let svc = make_service();
        let result = svc.stop_stream("nonexistent").await;
        assert!(result.is_ok());
    }

    #[tokio::test]
    async fn service_close_unknown_session_is_ok() {
        let svc = make_service();
        let result = svc.close_session("nonexistent").await;
        assert!(result.is_ok());
    }

    #[test]
    fn service_chrome_path_stored() {
        let svc = BrowserService::new(PathBuf::from("/opt/chrome"));
        assert_eq!(svc.chrome_path(), std::path::Path::new("/opt/chrome"));
    }
}

/// Integration tests that require Chrome installed.
#[cfg(test)]
#[cfg(feature = "browser-integration")]
mod integration_tests {
    use super::*;
    use std::time::Duration;

    fn make_real_service() -> BrowserService {
        let chrome = super::chrome::find_chrome().expect("Chrome required for integration tests");
        BrowserService::new(chrome)
    }

    #[tokio::test]
    async fn service_get_or_create_launches_browser() {
        let svc = make_real_service();
        let session = svc.get_or_create("s1").await;
        assert!(session.is_ok());
        assert_eq!(svc.session_count(), 1);
        svc.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn service_get_or_create_idempotent() {
        let svc = make_real_service();
        let s1 = svc.get_or_create("s1").await.unwrap();
        let s2 = svc.get_or_create("s1").await.unwrap();
        assert!(Arc::ptr_eq(&s1, &s2));
        assert_eq!(svc.session_count(), 1);
        svc.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn service_status_after_create() {
        let svc = make_real_service();
        let _ = svc.get_or_create("s1").await.unwrap();
        let status = svc.get_status("s1");
        assert!(status.has_browser);
        assert!(!status.is_streaming);
        svc.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn service_close_removes_session() {
        let svc = make_real_service();
        let _ = svc.get_or_create("s1").await.unwrap();
        assert_eq!(svc.session_count(), 1);
        svc.close_session("s1").await.unwrap();
        assert_eq!(svc.session_count(), 0);
        let status = svc.get_status("s1");
        assert!(!status.has_browser);
    }

    #[tokio::test]
    async fn service_close_emits_closed_event() {
        let svc = make_real_service();
        let mut rx = svc.subscribe();
        let _ = svc.get_or_create("s1").await.unwrap();
        svc.close_session("s1").await.unwrap();

        let event = tokio::time::timeout(std::time::Duration::from_secs(2), rx.recv())
            .await
            .unwrap()
            .unwrap();
        match event {
            BrowserEvent::Closed { session_id } => assert_eq!(session_id, "s1"),
            other => panic!("expected Closed, got: {other:?}"),
        }
    }

    #[tokio::test]
    async fn service_multiple_sessions_independent() {
        let svc = make_real_service();
        let _ = svc.get_or_create("s1").await.unwrap();
        let _ = svc.get_or_create("s2").await.unwrap();
        assert_eq!(svc.session_count(), 2);
        svc.close_session("s1").await.unwrap();
        assert_eq!(svc.session_count(), 1);
        assert!(svc.get_status("s2").has_browser);
        svc.close_session("s2").await.unwrap();
    }

    #[tokio::test]
    async fn service_start_stream_creates_and_streams() {
        let svc = make_real_service();
        svc.start_stream("s1").await.unwrap();
        let status = svc.get_status("s1");
        assert!(status.has_browser);
        assert!(status.is_streaming);
        svc.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn service_start_stream_then_stop() {
        let svc = make_real_service();
        svc.start_stream("s1").await.unwrap();
        assert!(svc.get_status("s1").is_streaming);
        svc.stop_stream("s1").await.unwrap();
        assert!(!svc.get_status("s1").is_streaming);
        svc.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn service_start_stream_delivers_frames() {
        let svc = make_real_service();
        let mut rx = svc.subscribe();
        svc.start_stream("s1").await.unwrap();

        let session = svc.get_or_create("s1").await.unwrap();
        session
            .navigate("data:text/html,<h1 style='font-size:72px'>FRAME TEST</h1>")
            .await
            .unwrap();

        let event = tokio::time::timeout(Duration::from_secs(5), rx.recv())
            .await
            .expect("timeout waiting for frame")
            .expect("channel error");

        match event {
            BrowserEvent::Frame { session_id, frame } => {
                assert_eq!(session_id, "s1");
                assert!(!frame.data.is_empty());
                assert!(frame.frame_id >= 1);
                assert!(frame.timestamp > 0);
            }
            other => panic!("expected Frame, got: {other:?}"),
        }

        svc.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn service_stop_stream_stops_frames() {
        let svc = make_real_service();
        let mut rx = svc.subscribe();
        svc.start_stream("s1").await.unwrap();

        let session = svc.get_or_create("s1").await.unwrap();
        session
            .navigate("data:text/html,<h1>STOP TEST</h1>")
            .await
            .unwrap();

        // Drain one frame
        let _ = tokio::time::timeout(Duration::from_secs(5), rx.recv()).await;

        svc.stop_stream("s1").await.unwrap();
        tokio::time::sleep(Duration::from_millis(500)).await;

        // Clear buffered frames
        while rx.try_recv().is_ok() {}

        // No more frames should arrive
        let result = tokio::time::timeout(Duration::from_secs(2), rx.recv()).await;
        assert!(result.is_err(), "should not receive frames after stop");

        svc.close_session("s1").await.unwrap();
    }

    #[tokio::test]
    async fn service_frame_ids_increment() {
        let svc = make_real_service();
        let mut rx = svc.subscribe();
        svc.start_stream("s1").await.unwrap();

        let session = svc.get_or_create("s1").await.unwrap();
        session
            .navigate("data:text/html,<h1>COUNTER TEST</h1>")
            .await
            .unwrap();

        let mut ids = vec![];
        for _ in 0..3 {
            if let Ok(Ok(BrowserEvent::Frame { frame, .. })) =
                tokio::time::timeout(Duration::from_secs(5), rx.recv()).await
            {
                ids.push(frame.frame_id);
            }
        }

        assert!(ids.len() >= 2, "need at least 2 frames, got {}", ids.len());
        for window in ids.windows(2) {
            assert!(
                window[1] > window[0],
                "frame_ids should increment: {ids:?}"
            );
        }

        svc.close_session("s1").await.unwrap();
    }
}
