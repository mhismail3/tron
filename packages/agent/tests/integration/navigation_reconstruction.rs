use super::*;

fn navigation_reconstruction_workdir() -> String {
    std::env::temp_dir().to_string_lossy().to_string()
}

#[tokio::test]
async fn e2e_tree_get_ancestors_returns_wire_events() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "m", "workingDirectory": navigation_reconstruction_workdir()})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();

    let resp = rpc_call(
        &mut ws,
        2,
        "events::append",
        Some(json!({
            "sessionId": sid,
            "type": "message.user",
            "payload": {"text": "ancestor payload"}
        })),
    )
    .await;
    assert_eq!(resp["success"], true);
    let event_id = resp["result"]["event"]["id"].as_str().unwrap().to_string();

    let resp = rpc_call(
        &mut ws,
        3,
        "tree::get_ancestors",
        Some(json!({"eventId": event_id})),
    )
    .await;
    assert_eq!(resp["success"], true);
    let events = resp["result"]["events"].as_array().unwrap();
    assert!(
        events.len() >= 2,
        "ancestor wire events should include the session root and target event"
    );
    assert_eq!(events.last().unwrap()["id"], event_id);
    assert!(events.last().unwrap()["sessionId"].is_string());
    assert!(events.last().unwrap()["workspaceId"].is_string());
    assert!(events.last().unwrap()["timestamp"].is_string());
    assert_eq!(
        events.last().unwrap()["payload"]["text"],
        "ancestor payload"
    );
    assert!(resp["result"].get("ancestors").is_none());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn e2e_reconstruct_fork_returns_ordered_ancestor_chain() {
    let (url, server) = boot_server().await;
    let mut ws = connect(&url).await;

    let resp = rpc_call(
        &mut ws,
        1,
        "session::create",
        Some(json!({"model": "m", "workingDirectory": navigation_reconstruction_workdir()})),
    )
    .await;
    let sid = resp["result"]["sessionId"].as_str().unwrap().to_string();

    let resp = rpc_call(
        &mut ws,
        2,
        "events::append",
        Some(json!({
            "sessionId": sid,
            "type": "message.user",
            "payload": {"text": "fork ancestor prompt"}
        })),
    )
    .await;
    assert_eq!(resp["success"], true);
    let source_event_id = resp["result"]["event"]["id"].as_str().unwrap().to_string();

    let resp = rpc_call(
        &mut ws,
        3,
        "session::fork",
        Some(json!({"sessionId": sid, "fromEventId": source_event_id.clone()})),
    )
    .await;
    assert_eq!(resp["success"], true);
    let forked_session_id = resp["result"]["newSessionId"].as_str().unwrap().to_string();
    let fork_root_id = resp["result"]["rootEventId"].as_str().unwrap().to_string();

    let resp = rpc_call(
        &mut ws,
        4,
        "session::reconstruct",
        Some(json!({"sessionId": forked_session_id, "limit": 50})),
    )
    .await;
    assert_eq!(resp["success"], true);
    let events = resp["result"]["events"].as_array().unwrap();
    assert!(
        events.len() >= 3,
        "fork reconstruction should include source root, source prompt, and fork root"
    );

    let ids = events
        .iter()
        .map(|event| event["id"].as_str().unwrap())
        .collect::<Vec<_>>();
    let source_index = ids
        .iter()
        .position(|id| *id == source_event_id)
        .expect("source event should be in fork reconstruction");
    let fork_index = ids
        .iter()
        .position(|id| *id == fork_root_id)
        .expect("fork root should be in fork reconstruction");
    assert!(
        source_index < fork_index,
        "ancestor order should place the source event before the fork root"
    );
    assert_eq!(
        events[source_index]["payload"]["text"],
        "fork ancestor prompt"
    );
    assert_eq!(
        resp["result"]["oldestEventId"],
        events.first().unwrap()["id"]
    );

    let resp = rpc_call(
        &mut ws,
        5,
        "session::reconstruct",
        Some(json!({
            "sessionId": forked_session_id,
            "limit": 1,
            "beforeEventId": fork_root_id.clone()
        })),
    )
    .await;
    assert_eq!(resp["success"], true);
    let events = resp["result"]["events"].as_array().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["id"], source_event_id);
    assert_eq!(resp["result"]["hasMoreEvents"], true);

    server.shutdown().shutdown();
}
