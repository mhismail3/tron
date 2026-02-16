//! Broadcast-based event emitter for `TronEvent` dispatch.

use std::sync::atomic::{AtomicU64, Ordering};

use tokio::sync::broadcast;
use tron_core::events::TronEvent;

/// Default broadcast channel capacity.
const DEFAULT_CAPACITY: usize = 1024;

/// Broadcast-based event emitter.
///
/// Non-blocking: `emit` never awaits. Slow receivers will be dropped
/// (lagged) rather than blocking the sender.
pub struct EventEmitter {
    tx: broadcast::Sender<TronEvent>,
    emit_count: AtomicU64,
}

impl EventEmitter {
    /// Create a new emitter with the default channel capacity.
    pub fn new() -> Self {
        Self::with_capacity(DEFAULT_CAPACITY)
    }

    /// Create a new emitter with a custom channel capacity.
    pub fn with_capacity(capacity: usize) -> Self {
        let (tx, _) = broadcast::channel(capacity);
        Self {
            tx,
            emit_count: AtomicU64::new(0),
        }
    }

    /// Emit an event to all subscribers. Non-blocking.
    ///
    /// Returns the number of receivers that received the event.
    /// Returns 0 if there are no active subscribers.
    pub fn emit(&self, event: TronEvent) -> usize {
        let _ = self.emit_count.fetch_add(1, Ordering::Relaxed);
        self.tx.send(event).unwrap_or(0)
    }

    /// Subscribe to events. Returns a receiver that will receive
    /// all events emitted after this call.
    pub fn subscribe(&self) -> broadcast::Receiver<TronEvent> {
        self.tx.subscribe()
    }

    /// Get the number of active subscribers.
    pub fn subscriber_count(&self) -> usize {
        self.tx.receiver_count()
    }

    /// Get the total number of events emitted.
    pub fn emit_count(&self) -> u64 {
        self.emit_count.load(Ordering::Relaxed)
    }
}

impl Default for EventEmitter {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_core::events::{BaseEvent, agent_start_event};

    #[test]
    fn emit_with_no_subscribers() {
        let emitter = EventEmitter::new();
        let count = emitter.emit(agent_start_event("s1"));
        assert_eq!(count, 0);
        assert_eq!(emitter.emit_count(), 1);
    }

    #[tokio::test]
    async fn emit_and_receive() {
        let emitter = EventEmitter::new();
        let mut rx = emitter.subscribe();

        let event = agent_start_event("s1");
        let count = emitter.emit(event.clone());
        assert_eq!(count, 1);

        let received = rx.recv().await.unwrap();
        assert_eq!(received.session_id(), "s1");
        assert_eq!(received.event_type(), "agent_start");
    }

    #[tokio::test]
    async fn multiple_subscribers() {
        let emitter = EventEmitter::new();
        let mut rx1 = emitter.subscribe();
        let mut rx2 = emitter.subscribe();

        assert_eq!(emitter.subscriber_count(), 2);

        let event = agent_start_event("s1");
        let count = emitter.emit(event);
        assert_eq!(count, 2);

        let r1 = rx1.recv().await.unwrap();
        let r2 = rx2.recv().await.unwrap();
        assert_eq!(r1.session_id(), "s1");
        assert_eq!(r2.session_id(), "s1");
    }

    #[tokio::test]
    async fn dropped_slow_receiver() {
        let emitter = EventEmitter::with_capacity(2);
        let mut rx = emitter.subscribe();

        // Emit 3 events into a capacity-2 channel
        let _ = emitter.emit(agent_start_event("s1"));
        let _ = emitter.emit(agent_start_event("s2"));
        let _ = emitter.emit(agent_start_event("s3"));

        // Receiver should be lagged
        let result = rx.recv().await;
        assert!(result.is_err());
    }

    #[test]
    fn subscriber_count_tracks_drops() {
        let emitter = EventEmitter::new();
        assert_eq!(emitter.subscriber_count(), 0);

        let rx1 = emitter.subscribe();
        assert_eq!(emitter.subscriber_count(), 1);

        let rx2 = emitter.subscribe();
        assert_eq!(emitter.subscriber_count(), 2);

        drop(rx1);
        assert_eq!(emitter.subscriber_count(), 1);

        drop(rx2);
        assert_eq!(emitter.subscriber_count(), 0);
    }

    #[tokio::test]
    async fn session_id_filtering() {
        let emitter = EventEmitter::new();
        let mut rx = emitter.subscribe();

        let _ = emitter.emit(agent_start_event("s1"));
        let _ = emitter.emit(agent_start_event("s2"));
        let _ = emitter.emit(agent_start_event("s1"));

        let mut s1_events = vec![];
        for _ in 0..3 {
            let event = rx.recv().await.unwrap();
            if event.session_id() == "s1" {
                s1_events.push(event);
            }
        }
        assert_eq!(s1_events.len(), 2);
    }

    #[test]
    fn emit_count_increments() {
        let emitter = EventEmitter::new();
        assert_eq!(emitter.emit_count(), 0);

        let _ = emitter.emit(agent_start_event("s1"));
        assert_eq!(emitter.emit_count(), 1);

        let _ = emitter.emit(agent_start_event("s2"));
        assert_eq!(emitter.emit_count(), 2);
    }

    #[tokio::test]
    async fn receives_various_event_types() {
        let emitter = EventEmitter::new();
        let mut rx = emitter.subscribe();

        let _ = emitter.emit(TronEvent::TurnStart {
            base: BaseEvent::now("s1"),
            turn: 1,
        });
        let _ = emitter.emit(TronEvent::MessageUpdate {
            base: BaseEvent::now("s1"),
            content: "hello".into(),
        });

        let e1 = rx.recv().await.unwrap();
        assert_eq!(e1.event_type(), "turn_start");

        let e2 = rx.recv().await.unwrap();
        assert_eq!(e2.event_type(), "message_update");
    }

    #[test]
    fn default_creates_valid_emitter() {
        let emitter = EventEmitter::default();
        assert_eq!(emitter.subscriber_count(), 0);
        assert_eq!(emitter.emit_count(), 0);
    }
}
