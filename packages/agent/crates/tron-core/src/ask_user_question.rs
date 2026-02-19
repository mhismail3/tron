//! `AskUserQuestion` tool types.
//!
//! Types for the interactive question tool that lets the agent ask
//! the user multiple-choice or free-form questions.

use serde::{Deserialize, Serialize};

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

/// A single option in a question.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct QuestionOption {
    /// Display label.
    pub label: String,
    /// Optional value (defaults to label if absent).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    /// Optional description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// Selection mode for a question.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SelectionMode {
    /// Single choice.
    Single,
    /// Multiple choice.
    Multi,
}

/// A single question with options.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AskUserQuestion {
    /// Unique identifier.
    pub id: String,
    /// The question text.
    pub question: String,
    /// Available options.
    pub options: Vec<QuestionOption>,
    /// Selection mode.
    pub mode: SelectionMode,
    /// Whether to allow a free-form "Other" option.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub allow_other: Option<bool>,
    /// Placeholder text for the "Other" input.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub other_placeholder: Option<String>,
}

/// Parameters for the `AskUserQuestion` tool call.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AskUserQuestionParams {
    /// Array of questions (1–5).
    pub questions: Vec<AskUserQuestion>,
    /// Optional context.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context: Option<String>,
}

/// A user's answer to a single question.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuestionAnswer {
    /// ID of the question being answered.
    pub question_id: String,
    /// Selected option values.
    pub selected_values: Vec<String>,
    /// Free-form response if `allow_other` was true.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub other_value: Option<String>,
}

/// The complete result from the `AskUserQuestion` tool.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AskUserQuestionResult {
    /// All answers.
    pub answers: Vec<QuestionAnswer>,
    /// Whether all questions were answered.
    pub complete: bool,
    /// ISO 8601 timestamp.
    pub submitted_at: String,
}

// ─────────────────────────────────────────────────────────────────────────────
// Validation
// ─────────────────────────────────────────────────────────────────────────────

/// Validation result.
#[derive(Clone, Debug, PartialEq)]
pub struct ValidationResult {
    /// Whether the params are valid.
    pub valid: bool,
    /// Error message if invalid.
    pub error: Option<String>,
}

/// Validate [`AskUserQuestionParams`].
#[must_use]
pub fn validate_params(params: &AskUserQuestionParams) -> ValidationResult {
    if params.questions.is_empty() {
        return ValidationResult {
            valid: false,
            error: Some("Must have at least 1 question".into()),
        };
    }
    if params.questions.len() > 5 {
        return ValidationResult {
            valid: false,
            error: Some("Must have at most 5 questions".into()),
        };
    }

    // Check for unique IDs
    let mut seen = std::collections::HashSet::new();
    for q in &params.questions {
        if !seen.insert(&q.id) {
            return ValidationResult {
                valid: false,
                error: Some("Question IDs must be unique".into()),
            };
        }
    }

    // Each question needs at least 2 options
    for q in &params.questions {
        if q.options.len() < 2 {
            return ValidationResult {
                valid: false,
                error: Some(format!(
                    "Question \"{}\" must have at least 2 options",
                    q.id
                )),
            };
        }
    }

    ValidationResult {
        valid: true,
        error: None,
    }
}

/// Check if all questions have been answered.
#[must_use]
pub fn is_complete(questions: &[AskUserQuestion], answers: &[QuestionAnswer]) -> bool {
    for question in questions {
        let answer = answers.iter().find(|a| a.question_id == question.id);
        match answer {
            None => return false,
            Some(a) => {
                let has_selected = !a.selected_values.is_empty();
                let has_other = a.other_value.as_ref().is_some_and(|v| !v.is_empty());
                if !has_selected && !has_other {
                    return false;
                }
            }
        }
    }
    true
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn make_option(label: &str) -> QuestionOption {
        QuestionOption {
            label: label.into(),
            value: None,
            description: None,
        }
    }

    fn make_question(id: &str) -> AskUserQuestion {
        AskUserQuestion {
            id: id.into(),
            question: format!("Question {id}?"),
            options: vec![make_option("A"), make_option("B")],
            mode: SelectionMode::Single,
            allow_other: None,
            other_placeholder: None,
        }
    }

    // -- validate_params --

    #[test]
    fn validate_empty_questions() {
        let params = AskUserQuestionParams {
            questions: vec![],
            context: None,
        };
        let result = validate_params(&params);
        assert!(!result.valid);
        assert!(result.error.unwrap().contains("at least 1"));
    }

    #[test]
    fn validate_too_many_questions() {
        let params = AskUserQuestionParams {
            questions: (0..6).map(|i| make_question(&i.to_string())).collect(),
            context: None,
        };
        let result = validate_params(&params);
        assert!(!result.valid);
        assert!(result.error.unwrap().contains("at most 5"));
    }

    #[test]
    fn validate_duplicate_ids() {
        let params = AskUserQuestionParams {
            questions: vec![make_question("q1"), make_question("q1")],
            context: None,
        };
        let result = validate_params(&params);
        assert!(!result.valid);
        assert!(result.error.unwrap().contains("unique"));
    }

    #[test]
    fn validate_too_few_options() {
        let mut q = make_question("q1");
        q.options = vec![make_option("only-one")];
        let params = AskUserQuestionParams {
            questions: vec![q],
            context: None,
        };
        let result = validate_params(&params);
        assert!(!result.valid);
        assert!(result.error.unwrap().contains("at least 2 options"));
    }

    #[test]
    fn validate_valid_params() {
        let params = AskUserQuestionParams {
            questions: vec![make_question("q1"), make_question("q2")],
            context: Some("context".into()),
        };
        let result = validate_params(&params);
        assert!(result.valid);
        assert!(result.error.is_none());
    }

    // -- is_complete --

    #[test]
    fn complete_all_answered() {
        let questions = vec![make_question("q1"), make_question("q2")];
        let answers = vec![
            QuestionAnswer {
                question_id: "q1".into(),
                selected_values: vec!["A".into()],
                other_value: None,
            },
            QuestionAnswer {
                question_id: "q2".into(),
                selected_values: vec!["B".into()],
                other_value: None,
            },
        ];
        assert!(is_complete(&questions, &answers));
    }

    #[test]
    fn complete_missing_answer() {
        let questions = vec![make_question("q1"), make_question("q2")];
        let answers = vec![QuestionAnswer {
            question_id: "q1".into(),
            selected_values: vec!["A".into()],
            other_value: None,
        }];
        assert!(!is_complete(&questions, &answers));
    }

    #[test]
    fn complete_empty_selected_values() {
        let questions = vec![make_question("q1")];
        let answers = vec![QuestionAnswer {
            question_id: "q1".into(),
            selected_values: vec![],
            other_value: None,
        }];
        assert!(!is_complete(&questions, &answers));
    }

    #[test]
    fn complete_with_other_value() {
        let questions = vec![make_question("q1")];
        let answers = vec![QuestionAnswer {
            question_id: "q1".into(),
            selected_values: vec![],
            other_value: Some("custom answer".into()),
        }];
        assert!(is_complete(&questions, &answers));
    }

    #[test]
    fn complete_empty_other_value() {
        let questions = vec![make_question("q1")];
        let answers = vec![QuestionAnswer {
            question_id: "q1".into(),
            selected_values: vec![],
            other_value: Some(String::new()),
        }];
        assert!(!is_complete(&questions, &answers));
    }

    // -- Serde --

    #[test]
    fn question_option_serde() {
        let opt = QuestionOption {
            label: "Option A".into(),
            value: Some("a".into()),
            description: Some("First option".into()),
        };
        let json = serde_json::to_value(&opt).unwrap();
        let back: QuestionOption = serde_json::from_value(json).unwrap();
        assert_eq!(opt, back);
    }

    #[test]
    fn selection_mode_serde() {
        assert_eq!(
            serde_json::to_string(&SelectionMode::Single).unwrap(),
            "\"single\""
        );
        assert_eq!(
            serde_json::to_string(&SelectionMode::Multi).unwrap(),
            "\"multi\""
        );
    }

    #[test]
    fn ask_user_question_serde_roundtrip() {
        let q = make_question("q1");
        let json = serde_json::to_string(&q).unwrap();
        let back: AskUserQuestion = serde_json::from_str(&json).unwrap();
        assert_eq!(q, back);
    }

    #[test]
    fn question_answer_serde() {
        let answer = QuestionAnswer {
            question_id: "q1".into(),
            selected_values: vec!["A".into(), "B".into()],
            other_value: Some("custom".into()),
        };
        let json = serde_json::to_value(&answer).unwrap();
        assert_eq!(json["questionId"], "q1");
        assert_eq!(json["selectedValues"].as_array().unwrap().len(), 2);
    }
}
