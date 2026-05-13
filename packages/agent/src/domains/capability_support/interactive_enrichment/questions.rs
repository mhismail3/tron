use super::ANSWERS_MARKER;
use serde_json::Map;
use serde_json::Value;
use serde_json::json;

/// Extract the list of `(questionId, questionText)` pairs from an
/// agent::ask_user capability.invocation.started event's payload arguments.
pub(super) fn extract_questions(capability_invocation_event: &Value) -> Vec<(String, String)> {
    let Some(payload) = capability_invocation_event.get("payload") else {
        return vec![];
    };
    let parsed = match payload.get("arguments") {
        Some(Value::String(s)) => serde_json::from_str::<Value>(s).unwrap_or(Value::Null),
        Some(v) => v.clone(),
        None => return vec![],
    };
    parsed
        .get("questions")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|q| {
                    let id = q.get("id").and_then(Value::as_str)?.to_string();
                    let text = q.get("question").and_then(Value::as_str)?.to_string();
                    Some((id, text))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Parse an `[Answers to your questions]`-prefixed user message into
/// `{interactionStatus, parsedAnswers: [...]}`.
///
/// Matches the iOS `AnswerParser.parseAnswers` semantics exactly, including:
/// - question text matched by exact string equality against the original
/// - `[Other] value` → `otherValue` path
/// - `(no selection)` → empty selectedValues, nil otherValue
/// - comma-space split (`", "`) for multi-select values
/// - questions that fail to match the original params list are dropped
pub(super) fn parse_answers(
    user_msg: Option<&str>,
    questions: &[(String, String)],
) -> Map<String, Value> {
    let mut out = Map::new();
    let Some(msg) = user_msg else {
        let _ = out.insert("interactionStatus".into(), json!("pending"));
        return out;
    };
    if !msg.contains(ANSWERS_MARKER) {
        let _ = out.insert("interactionStatus".into(), json!("superseded"));
        return out;
    }

    let mut parsed: Vec<Value> = Vec::new();
    let mut current_question: Option<String> = None;
    let mut current_answer: Option<String> = None;

    let flush = |current_question: &mut Option<String>,
                 current_answer: &mut Option<String>,
                 parsed: &mut Vec<Value>| {
        if let (Some(q_text), Some(a_line)) = (current_question.take(), current_answer.take())
            && let Some((q_id, _)) = questions.iter().find(|(_id, text)| text == &q_text)
        {
            parsed.push(build_answer(&a_line, q_id));
        }
    };

    for raw_line in msg.lines() {
        let line = raw_line.trim();
        if line.starts_with("**") && line.ends_with("**") && line.len() > 4 {
            // New question starts — flush any pending question first.
            flush(&mut current_question, &mut current_answer, &mut parsed);
            current_question = Some(line[2..line.len() - 2].to_string());
        } else if let Some(rest) = line.strip_prefix("Answer:") {
            current_answer = Some(rest.trim().to_string());
        }
    }
    flush(&mut current_question, &mut current_answer, &mut parsed);

    let _ = out.insert("interactionStatus".into(), json!("answered"));
    let _ = out.insert("parsedAnswers".into(), Value::Array(parsed));
    out
}

pub(super) fn build_answer(answer_line: &str, question_id: &str) -> Value {
    if answer_line == "(no selection)" {
        return json!({
            "questionId": question_id,
            "selectedValues": [],
            "otherValue": Value::Null,
        });
    }
    if let Some(rest) = answer_line.strip_prefix("[Other]") {
        let trimmed = rest.trim();
        let other_value = if trimmed.is_empty() {
            Value::Null
        } else {
            Value::String(trimmed.to_string())
        };
        return json!({
            "questionId": question_id,
            "selectedValues": [],
            "otherValue": other_value,
        });
    }
    let values: Vec<&str> = answer_line.split(", ").collect();
    json!({
        "questionId": question_id,
        "selectedValues": values,
        "otherValue": Value::Null,
    })
}
