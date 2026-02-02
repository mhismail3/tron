/**
 * @fileoverview Tests for AskUserQuestion Types
 *
 * TDD: Tests for AskUserQuestion tool types, validation, and result handling.
 * These tests are written FIRST before implementation (RED phase).
 */

import { describe, it, expect } from 'vitest';
import type {
  AskUserQuestionOption,
  AskUserQuestion,
  AskUserQuestionParams,
  AskUserQuestionAnswer,
  AskUserQuestionResult,
} from '../ask-user-question.js';
import {
  validateAskUserQuestionParams,
  isAskUserQuestionComplete,
} from '../ask-user-question.js';

describe('AskUserQuestion Types', () => {
  describe('AskUserQuestionOption', () => {
    it('should require label', () => {
      const option: AskUserQuestionOption = {
        label: 'Option A',
      };

      expect(option.label).toBe('Option A');
    });

    it('should use label as value when value not provided', () => {
      const option: AskUserQuestionOption = {
        label: 'Option A',
      };

      // When value is not provided, it should default to label
      expect(option.value ?? option.label).toBe('Option A');
    });

    it('should use explicit value when provided', () => {
      const option: AskUserQuestionOption = {
        label: 'Option A',
        value: 'option_a',
      };

      expect(option.value).toBe('option_a');
    });

    it('should accept optional description', () => {
      const optionWithDesc: AskUserQuestionOption = {
        label: 'Option A',
        description: 'This is option A with extra details',
      };

      expect(optionWithDesc.description).toBe('This is option A with extra details');

      const optionWithoutDesc: AskUserQuestionOption = {
        label: 'Option B',
      };

      expect(optionWithoutDesc.description).toBeUndefined();
    });
  });

  describe('AskUserQuestion', () => {
    it('should require id and question', () => {
      const question: AskUserQuestion = {
        id: 'q1',
        question: 'What is your preferred approach?',
        options: [
          { label: 'Approach A' },
          { label: 'Approach B' },
        ],
        mode: 'single',
      };

      expect(question.id).toBe('q1');
      expect(question.question).toBe('What is your preferred approach?');
    });

    it('should accept single mode', () => {
      const question: AskUserQuestion = {
        id: 'q1',
        question: 'Choose one',
        options: [{ label: 'A' }, { label: 'B' }],
        mode: 'single',
      };

      expect(question.mode).toBe('single');
    });

    it('should accept multi mode', () => {
      const question: AskUserQuestion = {
        id: 'q1',
        question: 'Choose many',
        options: [{ label: 'A' }, { label: 'B' }, { label: 'C' }],
        mode: 'multi',
      };

      expect(question.mode).toBe('multi');
    });

    it('should default allowOther to false', () => {
      const question: AskUserQuestion = {
        id: 'q1',
        question: 'Choose one',
        options: [{ label: 'A' }, { label: 'B' }],
        mode: 'single',
      };

      // allowOther should be optional and default to false
      expect(question.allowOther).toBeUndefined();
    });

    it('should accept allowOther with otherPlaceholder', () => {
      const question: AskUserQuestion = {
        id: 'q1',
        question: 'Choose one',
        options: [{ label: 'A' }, { label: 'B' }],
        mode: 'single',
        allowOther: true,
        otherPlaceholder: 'Enter your own answer...',
      };

      expect(question.allowOther).toBe(true);
      expect(question.otherPlaceholder).toBe('Enter your own answer...');
    });
  });

  describe('AskUserQuestionParams validation', () => {
    it('should accept 1-5 questions', () => {
      const paramsWithOne: AskUserQuestionParams = {
        questions: [
          { id: 'q1', question: 'Q1?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
        ],
      };

      const paramsWithFive: AskUserQuestionParams = {
        questions: [
          { id: 'q1', question: 'Q1?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q2', question: 'Q2?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q3', question: 'Q3?', options: [{ label: 'A' }, { label: 'B' }], mode: 'multi' },
          { id: 'q4', question: 'Q4?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q5', question: 'Q5?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
        ],
      };

      expect(validateAskUserQuestionParams(paramsWithOne).valid).toBe(true);
      expect(validateAskUserQuestionParams(paramsWithFive).valid).toBe(true);
    });

    it('should reject 0 questions', () => {
      const params: AskUserQuestionParams = {
        questions: [],
      };

      const result = validateAskUserQuestionParams(params);
      expect(result.valid).toBe(false);
      expect(result.error).toContain('at least 1');
    });

    it('should reject more than 5 questions', () => {
      const params: AskUserQuestionParams = {
        questions: [
          { id: 'q1', question: 'Q1?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q2', question: 'Q2?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q3', question: 'Q3?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q4', question: 'Q4?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q5', question: 'Q5?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q6', question: 'Q6?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
        ],
      };

      const result = validateAskUserQuestionParams(params);
      expect(result.valid).toBe(false);
      expect(result.error).toContain('at most 5');
    });

    it('should require question.id to be unique', () => {
      const params: AskUserQuestionParams = {
        questions: [
          { id: 'q1', question: 'Q1?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
          { id: 'q1', question: 'Q2?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' }, // duplicate id
        ],
      };

      const result = validateAskUserQuestionParams(params);
      expect(result.valid).toBe(false);
      expect(result.error).toContain('unique');
    });

    it('should require at least 2 options per question', () => {
      const paramsWithOne: AskUserQuestionParams = {
        questions: [
          { id: 'q1', question: 'Q1?', options: [{ label: 'A' }], mode: 'single' },
        ],
      };

      const result = validateAskUserQuestionParams(paramsWithOne);
      expect(result.valid).toBe(false);
      expect(result.error).toContain('at least 2 options');
    });

    it('should accept optional context', () => {
      const params: AskUserQuestionParams = {
        questions: [
          { id: 'q1', question: 'Q1?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
        ],
        context: 'Additional context about the questions',
      };

      expect(params.context).toBe('Additional context about the questions');
    });
  });

  describe('AskUserQuestionAnswer', () => {
    it('should require questionId', () => {
      const answer: AskUserQuestionAnswer = {
        questionId: 'q1',
        selectedValues: ['Option A'],
      };

      expect(answer.questionId).toBe('q1');
    });

    it('should require selectedValues array', () => {
      const answer: AskUserQuestionAnswer = {
        questionId: 'q1',
        selectedValues: ['Option A', 'Option B'],
      };

      expect(answer.selectedValues).toEqual(['Option A', 'Option B']);
    });

    it('should accept empty selectedValues for unanswered', () => {
      const answer: AskUserQuestionAnswer = {
        questionId: 'q1',
        selectedValues: [],
      };

      expect(answer.selectedValues).toEqual([]);
    });

    it('should accept otherValue when allowOther is true', () => {
      const answer: AskUserQuestionAnswer = {
        questionId: 'q1',
        selectedValues: [],
        otherValue: 'My custom answer',
      };

      expect(answer.otherValue).toBe('My custom answer');
    });
  });

  describe('AskUserQuestionResult', () => {
    it('should mark complete when all questions answered', () => {
      const questions: AskUserQuestion[] = [
        { id: 'q1', question: 'Q1?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
        { id: 'q2', question: 'Q2?', options: [{ label: 'A' }, { label: 'B' }], mode: 'multi' },
      ];

      const answers: AskUserQuestionAnswer[] = [
        { questionId: 'q1', selectedValues: ['A'] },
        { questionId: 'q2', selectedValues: ['A', 'B'] },
      ];

      expect(isAskUserQuestionComplete(questions, answers)).toBe(true);
    });

    it('should mark incomplete when questions unanswered', () => {
      const questions: AskUserQuestion[] = [
        { id: 'q1', question: 'Q1?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
        { id: 'q2', question: 'Q2?', options: [{ label: 'A' }, { label: 'B' }], mode: 'multi' },
      ];

      const answers: AskUserQuestionAnswer[] = [
        { questionId: 'q1', selectedValues: ['A'] },
        // q2 not answered
      ];

      expect(isAskUserQuestionComplete(questions, answers)).toBe(false);
    });

    it('should mark incomplete when answer has empty selectedValues and no otherValue', () => {
      const questions: AskUserQuestion[] = [
        { id: 'q1', question: 'Q1?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single' },
      ];

      const answers: AskUserQuestionAnswer[] = [
        { questionId: 'q1', selectedValues: [] },
      ];

      expect(isAskUserQuestionComplete(questions, answers)).toBe(false);
    });

    it('should mark complete when otherValue provided instead of selectedValues', () => {
      const questions: AskUserQuestion[] = [
        { id: 'q1', question: 'Q1?', options: [{ label: 'A' }, { label: 'B' }], mode: 'single', allowOther: true },
      ];

      const answers: AskUserQuestionAnswer[] = [
        { questionId: 'q1', selectedValues: [], otherValue: 'My custom answer' },
      ];

      expect(isAskUserQuestionComplete(questions, answers)).toBe(true);
    });

    it('should include submittedAt timestamp in ISO format', () => {
      const result: AskUserQuestionResult = {
        answers: [{ questionId: 'q1', selectedValues: ['A'] }],
        complete: true,
        submittedAt: new Date().toISOString(),
      };

      expect(result.submittedAt).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/);
    });
  });

  describe('Edge cases', () => {
    it('should handle questions with special characters in labels', () => {
      const question: AskUserQuestion = {
        id: 'q1',
        question: 'Which approach?',
        options: [
          { label: 'Option with "quotes"' },
          { label: "Option with 'apostrophe'" },
          { label: 'Option with <html> & entities' },
        ],
        mode: 'single',
      };

      expect(question.options[0].label).toBe('Option with "quotes"');
      expect(question.options[1].label).toBe("Option with 'apostrophe'");
      expect(question.options[2].label).toBe('Option with <html> & entities');
    });

    it('should handle unicode in questions and options', () => {
      const question: AskUserQuestion = {
        id: 'q1',
        question: 'どのアプローチ？ 🤔',
        options: [
          { label: '选项 A 🅰️', description: '中文描述' },
          { label: 'Option B with émojis 🎉' },
        ],
        mode: 'single',
      };

      expect(question.question).toBe('どのアプローチ？ 🤔');
      expect(question.options[0].label).toBe('选项 A 🅰️');
    });

    it('should handle very long question text', () => {
      const longQuestion = 'A'.repeat(1000);
      const question: AskUserQuestion = {
        id: 'q1',
        question: longQuestion,
        options: [{ label: 'A' }, { label: 'B' }],
        mode: 'single',
      };

      expect(question.question.length).toBe(1000);
    });
  });
});
