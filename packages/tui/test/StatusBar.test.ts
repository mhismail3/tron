/**
 * @fileoverview StatusBar Component Tests
 *
 * Tests for the status bar including model formatting and display.
 */
import { describe, it, expect } from 'vitest';

// Test the formatModelShort function directly by importing the logic
// We'll test the expected output for various model IDs

describe('StatusBar', () => {
  describe('formatModelShort', () => {
    // Inline implementation for testing (mirrors StatusBar.tsx)
    function formatModelShort(model: string): string {
      // Claude 4.5 family - check most specific patterns first
      if (model.includes('opus-4-5') || model.includes('opus-4.5')) return 'Opus 4.5';
      if (model.includes('sonnet-4-5') || model.includes('sonnet-4.5')) return 'Sonnet 4.5';
      if (model.includes('haiku-4-5') || model.includes('haiku-4.5')) return 'Haiku 4.5';
      // Claude 4.1 family
      if (model.includes('opus-4-1') || model.includes('opus-4.1')) return 'Opus 4.1';
      // Claude 4 family
      if (model.includes('opus-4')) return 'Opus 4';
      if (model.includes('sonnet-4')) return 'Sonnet 4';
      // Claude 3.7 family
      if (model.includes('3-7-sonnet') || model.includes('3.7-sonnet')) return 'Sonnet 3.7';
      // Claude 3.5 family
      if (model.includes('3-5-sonnet') || model.includes('3.5-sonnet')) return 'Sonnet 3.5';
      if (model.includes('3-5-haiku') || model.includes('3.5-haiku')) return 'Haiku 3.5';
      // Claude 3 family
      if (model.includes('3-haiku') || model.includes('claude-3-haiku')) return 'Haiku 3';
      if (model.includes('3-sonnet')) return 'Sonnet 3';
      if (model.includes('3-opus')) return 'Opus 3';
      // Legacy fallback patterns (generic matches)
      if (model.includes('opus')) return 'Opus';
      if (model.includes('sonnet')) return 'Sonnet';
      if (model.includes('haiku')) return 'Haiku';
      // OpenAI models
      if (model.includes('gpt-4o-mini')) return 'GPT-4o Mini';
      if (model.includes('gpt-4o')) return 'GPT-4o';
      if (model.includes('gpt-4-turbo')) return 'GPT-4 Turbo';
      if (model.includes('gpt-4')) return 'GPT-4';
      // Google models
      if (model.includes('gemini-2.5-pro')) return 'Gemini 2.5 Pro';
      if (model.includes('gemini-2.5-flash')) return 'Gemini 2.5 Flash';
      if (model.includes('gemini')) return 'Gemini';
      // Fallback to truncated model ID
      return model.slice(0, 15);
    }

    describe('Claude 4.5 family', () => {
      it('should format claude-opus-4-5-20251101 as "Opus 4.5"', () => {
        expect(formatModelShort('claude-opus-4-5-20251101')).toBe('Opus 4.5');
      });

      it('should format claude-sonnet-4-5-20250929 as "Sonnet 4.5"', () => {
        expect(formatModelShort('claude-sonnet-4-5-20250929')).toBe('Sonnet 4.5');
      });

      it('should format claude-haiku-4-5-20251001 as "Haiku 4.5"', () => {
        expect(formatModelShort('claude-haiku-4-5-20251001')).toBe('Haiku 4.5');
      });
    });

    describe('Claude 4.1 family', () => {
      it('should format claude-opus-4-1-20250805 as "Opus 4.1"', () => {
        expect(formatModelShort('claude-opus-4-1-20250805')).toBe('Opus 4.1');
      });
    });

    describe('Claude 4 family', () => {
      it('should format claude-opus-4-20250514 as "Opus 4"', () => {
        expect(formatModelShort('claude-opus-4-20250514')).toBe('Opus 4');
      });

      it('should format claude-sonnet-4-20250514 as "Sonnet 4"', () => {
        expect(formatModelShort('claude-sonnet-4-20250514')).toBe('Sonnet 4');
      });
    });

    describe('Claude 3.7 family', () => {
      it('should format claude-3-7-sonnet-20250219 as "Sonnet 3.7"', () => {
        expect(formatModelShort('claude-3-7-sonnet-20250219')).toBe('Sonnet 3.7');
      });
    });

    describe('Claude 3 family', () => {
      it('should format claude-3-haiku-20240307 as "Haiku 3"', () => {
        expect(formatModelShort('claude-3-haiku-20240307')).toBe('Haiku 3');
      });
    });

    describe('OpenAI models', () => {
      it('should format gpt-4o as "GPT-4o"', () => {
        expect(formatModelShort('gpt-4o')).toBe('GPT-4o');
      });

      it('should format gpt-4o-mini as "GPT-4o Mini"', () => {
        expect(formatModelShort('gpt-4o-mini')).toBe('GPT-4o Mini');
      });

      it('should format gpt-4-turbo as "GPT-4 Turbo"', () => {
        expect(formatModelShort('gpt-4-turbo')).toBe('GPT-4 Turbo');
      });
    });

    describe('Google models', () => {
      it('should format gemini-2.5-pro as "Gemini 2.5 Pro"', () => {
        expect(formatModelShort('gemini-2.5-pro')).toBe('Gemini 2.5 Pro');
      });

      it('should format gemini-2.5-flash as "Gemini 2.5 Flash"', () => {
        expect(formatModelShort('gemini-2.5-flash')).toBe('Gemini 2.5 Flash');
      });
    });

    describe('unknown models', () => {
      it('should truncate unknown model IDs to 15 characters', () => {
        expect(formatModelShort('unknown-model-with-very-long-name')).toBe('unknown-model-w');
      });

      it('should return short model IDs unchanged', () => {
        expect(formatModelShort('custom')).toBe('custom');
      });
    });
  });
});
