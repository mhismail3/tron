use super::*;

fn speech_transcription_bundle(worker_id: &str) -> WorkerBundle {
    let mut bundle = command_bundle(vec![
        "printf".to_owned(),
        r#"{"text":"hello from worker"}"#.to_owned(),
    ]);
    bundle.worker_id = Some(worker_id.to_owned());
    bundle.name = format!("Speech transcription {worker_id}");
    bundle.description = "Transcribes native client audio into draft text".to_owned();
    bundle.tool_name = Some(format!("worker_{worker_id}"));
    bundle.input_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["audioBase64","mimeType","fileName"],
        "properties":{
            "audioBase64":{"type":"string","minLength":1},
            "mimeType":{"type":"string","minLength":1},
            "fileName":{"type":"string","minLength":1}
        }
    });
    bundle.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["text"],
        "properties":{"text":{"type":"string"}}
    });
    bundle.client_actions = vec![WorkerClientAction::SpeechTranscription];
    bundle
}

#[tokio::test]
async fn atomic_upsert_exposes_current_healthy_speech_transcription_owner() {
    let (runtime, _home) = test_runtime(None);
    let outcome = runtime
        .upsert(speech_transcription_bundle("speech-one"), None)
        .await
        .unwrap();

    assert_eq!(
        runtime.client_action_inventory().unwrap(),
        vec![json!({
            "action":"speech_transcription",
            "workerId":outcome.worker.worker_id,
            "workerVersion":outcome.worker.active_version,
        })]
    );
    let surface = runtime.engine_surface_snapshot(None, None).await.unwrap();
    assert_eq!(
        surface["activeClientActions"],
        json!([{
            "action":"speech_transcription",
            "workerId":outcome.worker.worker_id,
            "workerVersion":outcome.worker.active_version,
        }])
    );
}

#[tokio::test]
async fn incompatible_speech_transcription_schema_is_rejected_before_activation() {
    let (runtime, _home) = test_runtime(None);
    let mut bundle = speech_transcription_bundle("speech-invalid");
    bundle.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["transcript"],
        "properties":{"transcript":{"type":"string"}}
    });

    let error = runtime.upsert(bundle, None).await.unwrap_err();

    assert!(error.contains("client action 'speech_transcription' output"));
    assert!(runtime.store().list(true).unwrap().is_empty());
}

#[tokio::test]
async fn unhealthy_current_action_does_not_silently_reactivate_older_owner() {
    let (runtime, _home) = test_runtime(None);
    let older = runtime
        .upsert(speech_transcription_bundle("speech-older"), None)
        .await
        .unwrap();
    let mut current_bundle = speech_transcription_bundle("speech-current");
    current_bundle.name = "Current speech transcription".to_owned();
    current_bundle.description = "Owns the current native speech seam".to_owned();
    let current = runtime.upsert(current_bundle, None).await.unwrap();
    assert_ne!(older.worker.worker_id, current.worker.worker_id);

    runtime
        .store()
        .set_enabled(&current.worker.worker_id, false)
        .unwrap();

    assert!(runtime.client_action_inventory().unwrap().is_empty());
    assert!(
        runtime
            .store()
            .summary(&older.worker.worker_id)
            .unwrap()
            .unwrap()
            .enabled
    );
}
