/**
 * @fileoverview AskUserQuestion Tool Types
 *
 * Types for the AskUserQuestion tool that allows the agent to ask
 * interactive questions with multiple choice options and free-form input.
 */

/**
 * A single option in a question
 */
export interface AskUserQuestionOption {
  /** Display label for the option */
  label: string;
  /** Optional value (defaults to label if not provided) */
  value?: string;
  /** Optional description providing more context */
  description?: string;
}

/**
 * A single question with options
 */
export interface AskUserQuestion {
  /** Unique identifier for this question */
  id: string;
  /** The question text */
  question: string;
  /** Available options to choose from */
  options: AskUserQuestionOption[];
  /** Selection mode: single choice or multiple choice */
  mode: 'single' | 'multi';
  /** Whether to allow a free-form "Other" option */
  allowOther?: boolean;
  /** Placeholder text for the "Other" input field */
  otherPlaceholder?: string;
}

/**
 * Parameters for the AskUserQuestion tool call
 */
export interface AskUserQuestionParams {
  /** Array of questions (1-5) */
  questions: AskUserQuestion[];
  /** Optional context to provide alongside the questions */
  context?: string;
}

/**
 * A user's answer to a single question
 */
export interface AskUserQuestionAnswer {
  /** ID of the question being answered */
  questionId: string;
  /** Selected option values (labels or explicit values) */
  selectedValues: string[];
  /** Free-form response if allowOther was true */
  otherValue?: string;
}

/**
 * The complete result from the AskUserQuestion tool
 */
export interface AskUserQuestionResult {
  /** All answers provided by the user */
  answers: AskUserQuestionAnswer[];
  /** Whether all questions were answered */
  complete: boolean;
  /** ISO 8601 timestamp of when the result was submitted */
  submittedAt: string;
}

/**
 * Validation result for AskUserQuestionParams
 */
export interface ValidationResult {
  valid: boolean;
  error?: string;
}

/**
 * Validates AskUserQuestionParams for correctness
 *
 * @param params - The parameters to validate
 * @returns Validation result with error message if invalid
 */
export function validateAskUserQuestionParams(params: AskUserQuestionParams): ValidationResult {
  // Check question count
  if (params.questions.length === 0) {
    return { valid: false, error: 'Must have at least 1 question' };
  }

  if (params.questions.length > 5) {
    return { valid: false, error: 'Must have at most 5 questions' };
  }

  // Check for unique IDs
  const ids = params.questions.map(q => q.id);
  const uniqueIds = new Set(ids);
  if (ids.length !== uniqueIds.size) {
    return { valid: false, error: 'Question IDs must be unique' };
  }

  // Check each question has at least 2 options
  for (const question of params.questions) {
    if (question.options.length < 2) {
      return { valid: false, error: `Question "${question.id}" must have at least 2 options` };
    }
  }

  return { valid: true };
}

/**
 * Checks if all questions have been answered
 *
 * @param questions - The questions that need answering
 * @param answers - The answers provided so far
 * @returns true if all questions have been answered
 */
export function isAskUserQuestionComplete(
  questions: AskUserQuestion[],
  answers: AskUserQuestionAnswer[]
): boolean {
  // Every question must have a corresponding answer
  for (const question of questions) {
    const answer = answers.find(a => a.questionId === question.id);

    if (!answer) {
      return false;
    }

    // Answer must have either selected values or an other value
    const hasSelectedValues = answer.selectedValues.length > 0;
    const hasOtherValue = answer.otherValue !== undefined && answer.otherValue.length > 0;

    if (!hasSelectedValues && !hasOtherValue) {
      return false;
    }
  }

  return true;
}

/**
 * Creates an AskUserQuestionResult from answers
 *
 * @param questions - The questions that were asked
 * @param answers - The answers provided
 * @returns The result object
 */
export function createAskUserQuestionResult(
  questions: AskUserQuestion[],
  answers: AskUserQuestionAnswer[]
): AskUserQuestionResult {
  return {
    answers,
    complete: isAskUserQuestionComplete(questions, answers),
    submittedAt: new Date().toISOString(),
  };
}
