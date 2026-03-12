use serde_json::Value;

pub(crate) fn get_canvas(canvas_id: &str) -> Value {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let canvas_path = format!("{home}/.tron/artifacts/canvases/{canvas_id}.json");

    if let Ok(content) = std::fs::read_to_string(&canvas_path)
        && let Ok(canvas) = serde_json::from_str::<Value>(&content)
    {
        return serde_json::json!({
            "found": true,
            "canvas": canvas,
        });
    }

    serde_json::json!({
        "found": false,
        "canvas": null,
    })
}
