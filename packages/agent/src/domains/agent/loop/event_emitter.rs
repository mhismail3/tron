//! Broadcast-based event emitter for `TronEvent` dispatch.

use std::sync::Arc;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};

use crate::shared::protocol::events::TronEvent;
use parking_lot::Mutex;
use tokio::sync::broadcast;
use tracing::{error, trace};

/// Default broadcast channel capacity.
const DEFAULT_CAPACITY: usize = 1024;

/// Synchronous state projection owned by the emitter boundary.
pub(crate) trait TronEventObserver: Send + Sync {
    fn observe_tron_event(&self, event: &TronEvent);
}

/// Broadcast-based event emitter.
///
/// Non-blocking: `emit` never awaits. Slow receivers will be dropped
/// (lagged) rather than blocking the sender.
pub struct EventEmitter {
    tx: broadcast::Sender<TronEvent>,
    emit_count: AtomicU64,
    dispatch: Mutex<()>,
    observer: Option<Arc<dyn TronEventObserver>>,
}

impl EventEmitter {
    /// Create a new emitter with the default channel capacity.
    pub fn new() -> Self {
        Self::with_capacity(DEFAULT_CAPACITY)
    }

    /// Create a new emitter with a custom channel capacity.
    pub fn with_capacity(capacity: usize) -> Self {
        Self::with_capacity_and_observer(capacity, None)
    }

    /// Create an emitter whose observer is updated synchronously before each
    /// event becomes visible to broadcast consumers.
    pub(crate) fn with_observer(observer: Arc<dyn TronEventObserver>) -> Self {
        Self::with_capacity_and_observer(DEFAULT_CAPACITY, Some(observer))
    }

    fn with_capacity_and_observer(
        capacity: usize,
        observer: Option<Arc<dyn TronEventObserver>>,
    ) -> Self {
        let (tx, _) = broadcast::channel(capacity);
        Self {
            tx,
            emit_count: AtomicU64::new(0),
            dispatch: Mutex::new(()),
            observer,
        }
    }

    /// Emit an event to all subscribers. Non-blocking.
    ///
    /// Returns the number of receivers that received the event.
    /// Returns 0 if there are no active subscribers.
    pub fn emit(&self, event: TronEvent) -> usize {
        let _dispatch = self.dispatch.lock();
        if let Some(observer) = self.observer.as_ref() {
            observer.observe_tron_event(&event);
        }
        let _ = self.emit_count.fetch_add(1, Ordering::Relaxed);
        self.tx.send(event).unwrap_or(0)
    }

    /// Emit an event with a sequence number from the given counter. Non-blocking.
    ///
    /// Atomically increments the counter and assigns the sequence to the event
    /// before broadcasting. Returns the number of receivers that got the event.
    pub fn emit_sequenced(&self, mut event: TronEvent, counter: &AtomicI64) -> usize {
        // INVARIANT: sequence allocation, state observation, and broadcast are
        // one short synchronous critical section. Concurrent callers using
        // this allocation path cannot expose N+1 before N or advertise a cut
        // that the stream has not accepted. Presequenced events must arrive at
        // this emitter in source order; active-run ownership enforces that.
        let _dispatch = self.dispatch.lock();
        let mut current = counter.load(Ordering::SeqCst);
        let seq = loop {
            let Some(next) = current.checked_add(1) else {
                error!(
                    event_type = event.event_type(),
                    session_id = event.session_id(),
                    "event sequence exhausted; refusing unsequenced broadcast"
                );
                return 0;
            };
            match counter.compare_exchange_weak(current, next, Ordering::SeqCst, Ordering::SeqCst) {
                Ok(_) => break next,
                Err(observed) => current = observed,
            }
        };
        event.set_sequence(seq);
        trace!(
            event_type = event.event_type(),
            session_id = event.session_id(),
            seq,
            "emitting sequenced event"
        );
        if let Some(observer) = self.observer.as_ref() {
            observer.observe_tron_event(&event);
        }
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
    use crate::shared::protocol::events::{BaseEvent, agent_start_event};

    #[derive(Default)]
    struct RecordingObserver {
        sequences: Mutex<Vec<i64>>,
    }

    impl TronEventObserver for RecordingObserver {
        fn observe_tron_event(&self, event: &TronEvent) {
            if let Some(sequence) = event.sequence() {
                self.sequences.lock().push(sequence);
            }
        }
    }

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
    async fn sequenced_emit_fails_closed_at_i64_max() {
        let emitter = EventEmitter::new();
        let mut receiver = emitter.subscribe();
        let counter = AtomicI64::new(i64::MAX);

        assert_eq!(emitter.emit_sequenced(agent_start_event("s1"), &counter), 0);
        assert_eq!(counter.load(Ordering::SeqCst), i64::MAX);
        assert_eq!(emitter.emit_count(), 0);
        assert!(matches!(
            receiver.try_recv(),
            Err(broadcast::error::TryRecvError::Empty)
        ));
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

    #[tokio::test]
    async fn synchronous_observer_remains_complete_when_receiver_lags() {
        let observer = Arc::new(RecordingObserver::default());
        let emitter = EventEmitter::with_capacity_and_observer(2, Some(observer.clone()));
        let mut receiver = emitter.subscribe();
        let counter = AtomicI64::new(0);

        for _ in 0..3 {
            let _ = emitter.emit_sequenced(agent_start_event("s1"), &counter);
        }

        assert_eq!(*observer.sequences.lock(), vec![1, 2, 3]);
        assert!(matches!(
            receiver.recv().await,
            Err(broadcast::error::RecvError::Lagged(1))
        ));
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

    #[tokio::test]
    async fn emit_sequenced_assigns_monotonic_sequence() {
        let emitter = EventEmitter::new();
        let mut rx = emitter.subscribe();
        let counter = AtomicI64::new(0);

        let _ = emitter.emit_sequenced(agent_start_event("s1"), &counter);
        let _ = emitter.emit_sequenced(agent_start_event("s1"), &counter);
        let _ = emitter.emit_sequenced(agent_start_event("s1"), &counter);

        let e1 = rx.recv().await.unwrap();
        let e2 = rx.recv().await.unwrap();
        let e3 = rx.recv().await.unwrap();
        assert_eq!(e1.sequence(), Some(1));
        assert_eq!(e2.sequence(), Some(2));
        assert_eq!(e3.sequence(), Some(3));
    }

    #[test]
    fn concurrent_sequence_allocation_observation_and_broadcast_stay_ordered() {
        let observer = Arc::new(RecordingObserver::default());
        let emitter = Arc::new(EventEmitter::with_observer(observer.clone()));
        let mut receiver = emitter.subscribe();
        let counter = Arc::new(AtomicI64::new(0));

        std::thread::scope(|scope| {
            for _ in 0..64 {
                let emitter = emitter.clone();
                let counter = counter.clone();
                scope.spawn(move || {
                    let _ = emitter.emit_sequenced(agent_start_event("s1"), &counter);
                });
            }
        });

        assert_eq!(
            *observer.sequences.lock(),
            (1..=64).map(i64::from).collect::<Vec<_>>()
        );
        let broadcast_sequences = (0..64)
            .map(|_| receiver.try_recv().unwrap().sequence().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(
            broadcast_sequences,
            (1..=64).map(i64::from).collect::<Vec<_>>()
        );
    }

    #[test]
    fn emit_sequenced_increments_emit_count() {
        let emitter = EventEmitter::new();
        let counter = AtomicI64::new(0);

        let _ = emitter.emit_sequenced(agent_start_event("s1"), &counter);
        assert_eq!(emitter.emit_count(), 1);
    }
}
