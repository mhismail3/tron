use serde_json::{Map, Value, json};

pub(super) fn insert_media_request_fields(properties: &mut Map<String, Value>) {
    insert_string(
        properties,
        "mediaResourceId",
        "Durable media_artifact resource id for media_inspect or media_archive.",
    );
    insert_string(
        properties,
        "expectedMediaVersionId",
        "Expected current media_artifact version id for media_archive freshness.",
    );
    insert_string(
        properties,
        "mediaId",
        "Optional caller-visible media id for media_create idempotent resource identity.",
    );
    insert_string(
        properties,
        "mediaKind",
        "Media kind for media_create or media_list: voice_note, audio, image, or document.",
    );
    insert_string(
        properties,
        "mimeType",
        "Allowed media MIME type for media_create.",
    );
    insert_integer(
        properties,
        "sizeBytes",
        1,
        Some(157_286_400),
        Some(
            "Declared media byte size for media_create; enforced by media kind and MIME allow-list.",
        ),
    );
    insert_string(
        properties,
        "blobRef",
        "Durable blob/storage reference for media_create; raw bytes and base64 are not accepted.",
    );
    insert_string(
        properties,
        "contentHash",
        "Optional content hash for the media blob reference.",
    );
    insert_integer(
        properties,
        "durationMs",
        0,
        Some(86_400_000),
        Some("Optional audio or voice-note duration in milliseconds."),
    );
    insert_string(
        properties,
        "summary",
        "Bounded media summary for media_create.",
    );
    insert_string(
        properties,
        "transcriptionState",
        "Existing local transcription state for media_create: not_requested, local_completed, or local_failed.",
    );
    insert_string(
        properties,
        "transcriptionText",
        "Bounded text from existing local composer transcription output for media_create.",
    );
    insert_string(
        properties,
        "transcriptionLanguage",
        "Optional language token for existing local transcription metadata.",
    );
    insert_string(
        properties,
        "transcriptionModel",
        "Optional local transcription model token for metadata only.",
    );
}

fn insert_string(properties: &mut Map<String, Value>, name: &str, description: &str) {
    properties.insert(
        name.to_owned(),
        json!({"type": "string", "description": description}),
    );
}

fn insert_integer(
    properties: &mut Map<String, Value>,
    name: &str,
    minimum: u64,
    maximum: Option<u64>,
    description: Option<&str>,
) {
    let mut property = Map::new();
    property.insert("type".to_owned(), json!("integer"));
    property.insert("minimum".to_owned(), json!(minimum));
    if let Some(maximum) = maximum {
        property.insert("maximum".to_owned(), json!(maximum));
    }
    if let Some(description) = description {
        property.insert("description".to_owned(), json!(description));
    }
    properties.insert(name.to_owned(), Value::Object(property));
}
