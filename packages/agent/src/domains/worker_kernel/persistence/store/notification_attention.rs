//! Sanitized notification transport failures projected into Engine Attention.

use rusqlite::{Transaction, params};
use serde_json::json;

pub(super) fn insert_notification_attention(
    transaction: &Transaction<'_>,
    invocation_id: &str,
    worker_id: &str,
    delivery_id: &str,
    target_id: Option<&str>,
    error_code: &str,
    created_at: &str,
) -> Result<(), String> {
    let result = json!({
        "status":"notification_delivery_blocked",
        "deliveryId":delivery_id,
        "targetId":target_id,
        "errorCode":error_code,
        "message":"Native notification delivery needs attention. Inspect notification delivery status for durable transport evidence.",
    });
    transaction
        .execute(
            "INSERT INTO worker_inbox(
                inbox_id,invocation_id,worker_id,severity,result_json,created_at
             )
             SELECT ?1,?2,?3,'error',?4,?5
             WHERE NOT EXISTS (
                SELECT 1 FROM worker_inbox
                WHERE worker_id=?3
                  AND json_extract(result_json,'$.deliveryId')=?6
                  AND COALESCE(json_extract(result_json,'$.targetId'),'')=COALESCE(?7,'')
                  AND json_extract(result_json,'$.errorCode')=?8
             )",
            params![
                format!("worker_inbox_{}", uuid::Uuid::now_v7()),
                invocation_id,
                worker_id,
                serde_json::to_string(&result)
                    .map_err(|error| format!("encode notification attention: {error}"))?,
                created_at,
                delivery_id,
                target_id,
                error_code,
            ],
        )
        .map_err(|error| format!("record notification attention: {error}"))?;
    Ok(())
}
