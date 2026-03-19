use serde_json::Value;

pub(crate) fn get_canvas(canvas_id: &str) -> Value {
    let home = crate::core::paths::home_dir();
    let canvas_path = format!("{home}/.tron/workspace/canvases/{canvas_id}.json");

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
