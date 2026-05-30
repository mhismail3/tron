use super::support::*;

#[test]
fn orchestration_audit_filters_match_status_phase_and_correction() {
    let matching = json!({
        "eventType": "capability.orchestration",
        "traceId": "trace-a",
        "payload": {
            "orchestrationId": "capability-orchestration:test",
            "status": "executed",
            "intent": "run a command",
            "correctionsApplied": [
                {"kind": "payload_to_arguments", "confidence": 1.0}
            ],
            "phaseDetails": {"phase": "prepare"}
        }
    });
    let different = json!({
        "eventType": "capability.orchestration",
        "traceId": "trace-a",
        "payload": {
            "status": "needs_selection",
            "correctionsApplied": [],
            "phaseDetails": {"phase": "resolve"}
        }
    });

    assert!(audit_event_matches_orchestration_filters(
        &matching,
        Some("executed"),
        Some("payload_to_arguments"),
        Some("prepare")
    ));
    assert!(!audit_event_matches_orchestration_filters(
        &different,
        Some("executed"),
        Some("payload_to_arguments"),
        Some("prepare")
    ));

    let filtered = filter_orchestration_audit_result(
        json!({"events": [different, matching], "redacted": false}),
        Some("executed"),
        Some("payload_to_arguments"),
        Some("prepare"),
        10,
        false,
    )
    .expect("filtered");
    assert_eq!(filtered["events"].as_array().expect("events").len(), 1);
    assert_eq!(filtered["redacted"], json!(true));
    assert_eq!(filtered["events"][0]["payload"]["redacted"], json!(true));
    assert_eq!(
        filtered["events"][0]["payloadSummary"]["status"],
        json!("executed")
    );
    assert_eq!(
        filtered["events"][0]["payloadSummary"]["phase"],
        json!("prepare")
    );
    assert_eq!(
        filtered["events"][0]["payloadSummary"]["correctionKinds"],
        json!(["payload_to_arguments"])
    );
}

#[test]
fn retired_harness_symbols_do_not_reappear_in_runtime_source() {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let src = manifest.join("src");
    let forbidden = [
        concat!("Tron", "ModelCapability"),
        concat!("ModelCapability", "Context"),
        concat!("capability", "_runtime"),
        concat!("builtin", "_function", "_registrations"),
        concat!("Mcp", "Search"),
        concat!("Mcp", "Call"),
        concat!("Engine", "Discover"),
        concat!("Engine", "Inspect"),
        concat!("Engine", "Invoke"),
        concat!("Engine", "Watch"),
        concat!("allowed", "Too", "ls"),
        concat!("denied", "Too", "ls"),
        concat!("inherit", "Too", "ls"),
        concat!("to", "ol", "Policy"),
        concat!("to", "ol", "Policies"),
        concat!("allowed", "_tools"),
        concat!("denied", "_tools"),
        concat!("inherit", "_tools"),
        concat!("PROGRAM", "_RUNTIME", "_NOT", "_LINKED"),
        concat!("Ask", "User", "Question"),
        concat!("Web", "Fetch"),
        concat!("Web", "Search"),
        concat!("Spawn", "Subagent"),
    ];
    let mut failures = Vec::new();
    scan_source_for_forbidden(&src, &forbidden, &mut failures);
    assert!(
        failures.is_empty(),
        "retired harness symbols found:\n{}",
        failures.join("\n")
    );
}

fn scan_source_for_forbidden(
    path: &std::path::Path,
    forbidden: &[&str],
    failures: &mut Vec<String>,
) {
    let Ok(entries) = std::fs::read_dir(path) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            scan_source_for_forbidden(&path, forbidden, failures);
            continue;
        }
        if path.extension().and_then(|ext| ext.to_str()) != Some("rs") {
            continue;
        }
        if path.ends_with("domains/session/event_store/types/generated.rs") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else {
            continue;
        };
        for symbol in forbidden {
            if text.contains(symbol) {
                failures.push(format!("{} contains {symbol}", path.display()));
            }
        }
    }
}
