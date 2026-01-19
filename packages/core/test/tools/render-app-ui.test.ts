/**
 * @fileoverview Tests for RenderAppUI tool auto-retry on validation failure
 *
 * TDD: These tests validate the retry behavior when UI validation fails.
 * The tool should return stopTurn: false to allow the turn to continue
 * so the LLM can retry with fixed UI.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { RenderAppUITool } from '../../src/tools/render-app-ui.js';

describe('RenderAppUITool', () => {
  let tool: RenderAppUITool;

  beforeEach(() => {
    tool = new RenderAppUITool({ workingDirectory: '/test' });
  });

  describe('tool definition', () => {
    it('should have correct name', () => {
      expect(tool.name).toBe('RenderAppUI');
    });

    it('should require canvasId and ui parameters', () => {
      expect(tool.parameters.required).toContain('canvasId');
      expect(tool.parameters.required).toContain('ui');
    });

    it('should have label and category', () => {
      expect(tool.label).toBe('Render App UI');
      expect(tool.category).toBe('custom');
    });
  });

  describe('validation success', () => {
    it('should return success with stopTurn=true for valid UI', async () => {
      const result = await tool.execute({
        canvasId: 'test-canvas',
        ui: { $tag: 'VStack', $children: [{ $tag: 'Text', $children: 'Hello' }] },
      });

      expect(result.isError).toBe(false);
      expect(result.stopTurn).toBe(true);
      expect(result.details?.canvasId).toBe('test-canvas');
    });

    it('should return success for valid Button with required props', async () => {
      const result = await tool.execute({
        canvasId: 'button-test',
        ui: {
          $tag: 'Button',
          $props: { label: 'Click me', actionId: 'btn-click' },
        },
      });

      expect(result.isError).toBe(false);
      expect(result.stopTurn).toBe(true);
    });

    it('should return success for valid Toggle with required props', async () => {
      const result = await tool.execute({
        canvasId: 'toggle-test',
        ui: {
          $tag: 'Toggle',
          $props: { label: 'Enable', bindingId: 'toggle1' },
        },
      });

      expect(result.isError).toBe(false);
      expect(result.stopTurn).toBe(true);
    });

    it('should clear retry count after successful validation', async () => {
      // First call with invalid UI
      await tool.execute({
        canvasId: 'retry-test',
        ui: { $tag: 'Button' }, // Missing required props
      });

      // Second call with valid UI
      const result = await tool.execute({
        canvasId: 'retry-test',
        ui: { $tag: 'Button', $props: { label: 'OK', actionId: 'ok' } },
      });

      expect(result.isError).toBe(false);
      expect(result.stopTurn).toBe(true);
      expect(result.details?.needsRetry).toBeUndefined();
    });

    it('should include component counts in summary', async () => {
      const result = await tool.execute({
        canvasId: 'count-test',
        ui: {
          $tag: 'VStack',
          $children: [
            { $tag: 'Button', $props: { label: 'OK', actionId: 'ok' } },
            { $tag: 'Toggle', $props: { label: 'On', bindingId: 'toggle1' } },
          ],
        },
      });

      expect(result.content).toContain('1 button');
      expect(result.content).toContain('1 toggle');
    });

    it('should include ui and state in details', async () => {
      const ui = { $tag: 'Text', $children: 'Hello' };
      const state = { key: 'value' };
      const result = await tool.execute({ canvasId: 'test', ui, state });

      expect(result.details?.ui).toEqual(ui);
      expect(result.details?.state).toEqual(state);
    });
  });

  describe('validation failure - retry behavior', () => {
    it('should return stopTurn=false on first validation failure', async () => {
      const result = await tool.execute({
        canvasId: 'test',
        ui: { $tag: 'Button' }, // Missing label and actionId
      });

      expect(result.isError).toBe(false); // NOT an error - allow retry
      expect(result.stopTurn).toBe(false); // Allow turn to continue
      expect(result.details?.needsRetry).toBe(true);
      expect(result.content).toContain('validation failed');
    });

    it('should track retry attempts per canvasId', async () => {
      const result1 = await tool.execute({
        canvasId: 'canvas-a',
        ui: { $tag: 'Button' },
      });
      expect(result1.content).toContain('attempt 1');

      const result2 = await tool.execute({
        canvasId: 'canvas-a',
        ui: { $tag: 'Button' },
      });
      expect(result2.content).toContain('attempt 2');

      // Different canvasId should have independent counter
      const resultB = await tool.execute({
        canvasId: 'canvas-b',
        ui: { $tag: 'Button' },
      });
      expect(resultB.content).toContain('attempt 1');
    });

    it('should return actual error after MAX_RETRIES (3)', async () => {
      // Exhaust retries (3 attempts max)
      for (let i = 0; i < 3; i++) {
        await tool.execute({ canvasId: 'max-test', ui: { $tag: 'Button' } });
      }

      // Fourth attempt should be actual error
      const result = await tool.execute({
        canvasId: 'max-test',
        ui: { $tag: 'Button' },
      });

      expect(result.isError).toBe(true);
      expect(result.stopTurn).toBe(true);
      expect(result.content).toContain('Failed to render valid UI after');
    });

    it('should include validation errors in content', async () => {
      const result = await tool.execute({
        canvasId: 'test',
        ui: { $tag: 'Button' },
      });

      expect(result.content).toContain('label');
      expect(result.content).toContain('actionId');
    });

    it('should include canvasId in retry details', async () => {
      const result = await tool.execute({
        canvasId: 'canvas-123',
        ui: { $tag: 'Button' },
      });

      expect(result.details?.canvasId).toBe('canvas-123');
    });

    it('should prompt to use same canvasId for retry', async () => {
      const result = await tool.execute({
        canvasId: 'keep-this-id',
        ui: { $tag: 'Button' },
      });

      expect(result.content).toContain('same canvasId');
    });
  });

  describe('regression tests - existing behavior preserved', () => {
    it('should still return stopTurn=true on successful render', async () => {
      const result = await tool.execute({
        canvasId: 'test',
        ui: { $tag: 'Text', $children: 'Hello' },
      });
      expect(result.stopTurn).toBe(true);
    });

    it('should still handle title parameter', async () => {
      const result = await tool.execute({
        canvasId: 'test',
        title: 'My UI',
        ui: { $tag: 'Text', $children: 'Hello' },
      });
      expect(result.content).toContain('My UI');
      expect(result.details?.title).toBe('My UI');
    });

    it('should include async marker in details', async () => {
      const result = await tool.execute({
        canvasId: 'test',
        ui: { $tag: 'Text', $children: 'Hello' },
      });
      expect(result.details?.async).toBe(true);
    });

    it('should log warnings without failing', async () => {
      // UI with warnings but no errors should still succeed
      const result = await tool.execute({
        canvasId: 'test',
        ui: { $tag: 'VStack', $children: [] }, // Empty children - warning
      });
      expect(result.isError).toBe(false);
      expect(result.stopTurn).toBe(true);
    });
  });
});
