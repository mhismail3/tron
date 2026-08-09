//! Authenticated native notification registration, inbox, and responses.

use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::engine::Invocation;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::ToolError;

use super::Deps;

pub(super) async fn device_upsert(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let request = decode(&invocation.payload)?;
    let runtime = deps.runtime.clone();
    run_notification_store("worker_kernel.notification_device_upsert", move || {
        runtime.notification_device_upsert(request)
    })
    .await
}

pub(super) async fn device_disable(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let request = decode(&invocation.payload)?;
    let runtime = deps.runtime.clone();
    run_notification_store("worker_kernel.notification_device_disable", move || {
        runtime.notification_device_disable(request)
    })
    .await
}

pub(super) async fn deliveries(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let request = decode(&invocation.payload)?;
    let runtime = deps.runtime.clone();
    run_notification_store("worker_kernel.notification_deliveries", move || {
        runtime.notification_deliveries(request)
    })
    .await
}

pub(super) async fn acknowledge(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let request = decode(&invocation.payload)?;
    let runtime = deps.runtime.clone();
    let response = run_notification_store(
        "worker_kernel.notification_delivery_acknowledge",
        move || runtime.acknowledge_notification_delivery(request),
    )
    .await?;
    deps.runtime
        .publish_notification_acknowledgement(&response)
        .await;
    Ok(response)
}

pub(super) async fn status(invocation: &Invocation, deps: &Deps) -> Result<Value, String> {
    let request = decode(&invocation.payload)?;
    let runtime = deps.runtime.clone();
    run_notification_store("worker_kernel.notification_delivery_status", move || {
        runtime.notification_delivery_status(request)
    })
    .await
}

fn decode<T: DeserializeOwned>(value: &Value) -> Result<T, String> {
    serde_json::from_value(value.clone()).map_err(|error| error.to_string())
}

async fn run_notification_store<F>(task_name: &'static str, operation: F) -> Result<Value, String>
where
    F: FnOnce() -> Result<Value, String> + Send + 'static,
{
    run_blocking_task(task_name, move || {
        operation().map_err(|message| ToolError::Internal { message })
    })
    .await
    .map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Condvar, Mutex};

    use serde_json::json;

    use super::run_notification_store;

    #[tokio::test]
    async fn notification_store_work_does_not_block_the_async_runtime() {
        let gate = Arc::new((Mutex::new(false), Condvar::new()));
        let gate_for_work = Arc::clone(&gate);
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let task = tokio::spawn(run_notification_store(
            "worker_kernel.notification_test",
            move || {
                let _ = started_tx.send(());
                let (lock, condition) = &*gate_for_work;
                let released = lock.lock().unwrap();
                let _released = condition
                    .wait_while(released, |released| !*released)
                    .unwrap();
                Ok(json!({"ok": true}))
            },
        ));

        tokio::time::timeout(std::time::Duration::from_secs(1), started_rx)
            .await
            .expect("blocking operation should start")
            .expect("blocking operation start signal");
        tokio::time::timeout(std::time::Duration::from_secs(1), tokio::task::yield_now())
            .await
            .expect("async executor must remain responsive");

        let (lock, condition) = &*gate;
        *lock.lock().unwrap() = true;
        condition.notify_one();
        assert_eq!(task.await.unwrap().unwrap(), json!({"ok": true}));
    }
}
