/**
 * @fileoverview Tests for RenderAppUI tool auto-retry on validation failure
 *
 * TDD: These tests validate the retry behavior when UI validation fails.
 * The tool should return stopTurn: false to allow the turn to continue
 * so the LLM can retry with fixed UI.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { RenderAppUITool } from '../ui/render-app-ui.js';

describe('RenderAppUITool', () => {
  let tool: RenderAppUITool;

  beforeEach(() => {
    tool = new RenderAppUITool({ workingDirectory: '/test' });
  });

  describe('tool definition', () => {
    it('should have correct name', () => {
      expect(tool.name).toBe('RenderAppUI');
    });

    it('should require only ui parameter (canvasId is optional)', () => {
      expect(tool.parameters.required).not.toContain('canvasId');
      expect(tool.parameters.required).toContain('ui');
    });

    it('should have label and category', () => {
      expect(tool.label).toBe('Render App UI');
      expect(tool.category).toBe('custom');
    });

    it('should be marked as interactive', () => {
      expect(tool.interactive).toBe(true);
    });
  });

  describe('canvasId auto-generation', () => {
    it('should auto-generate canvasId when not provided', async () => {
      const result = await tool.execute({
        ui: { $tag: 'VStack', $children: [{ $tag: 'Text', $children: 'Hello' }] },
      });

      const details = result.details as { canvasId?: string };
      expect(result.isError).toBe(false);
      expect(result.stopTurn).toBe(true);
      expect(details.canvasId).toBeDefined();
      expect(typeof details.canvasId).toBe('string');
      // Should have format: canvas-vstack-<8-char-random>
      expect(details.canvasId).toMatch(/^canvas-vstack-[a-f0-9]{8}$/);
    });

    it('should use title for canvasId generation', async () => {
      const result = await tool.execute({
        title: 'Settings Panel',
        ui: { $tag: 'VStack', $children: [] },
      });

      const details = result.details as { canvasId?: string };
      expect(details.canvasId).toBeDefined();
      // Should have format: settings-panel-<8-char-random>
      expect(details.canvasId).toMatch(/^settings-panel-[a-f0-9]{8}$/);
    });

    it('should handle multi-word titles', async () => {
      const result = await tool.execute({
        title: 'User Registration Form',
        ui: { $tag: 'VStack', $children: [] },
      });

      const details = result.details as { canvasId?: string };
      // Should only use first 3 words: user-registration-form-<8-char-random>
      expect(details.canvasId).toMatch(/^user-registration-form-[a-f0-9]{8}$/);
    });

    it('should strip special characters from title', async () => {
      const result = await tool.execute({
        title: 'My App!!! @#$%',
        ui: { $tag: 'VStack', $children: [] },
      });

      const details = result.details as { canvasId?: string };
      expect(details.canvasId).toMatch(/^my-app-[a-f0-9]{8}$/);
    });

    it('should preserve provided canvasId', async () => {
      const result = await tool.execute({
        canvasId: 'my-custom-id',
        ui: { $tag: 'VStack', $children: [] },
      });

      const details = result.details as { canvasId?: string };
      expect(details.canvasId).toBe('my-custom-id');
    });

    it('should generate unique IDs for each call', async () => {
      const result1 = await tool.execute({
        ui: { $tag: 'Text', $children: 'Hello' },
      });
      const result2 = await tool.execute({
        ui: { $tag: 'Text', $children: 'World' },
      });

      const details1 = result1.details as { canvasId?: string };
      const details2 = result2.details as { canvasId?: string };
      expect(details1.canvasId).not.toBe(details2.canvasId);
    });
  });

  describe('validation success', () => {
    it('should return success with stopTurn=true for valid UI', async () => {
      const result = await tool.execute({
        canvasId: 'test-canvas',
        ui: { $tag: 'VStack', $children: [{ $tag: 'Text', $children: 'Hello' }] },
      });

      const details = result.details as { canvasId?: string };
      expect(result.isError).toBe(false);
      expect(result.stopTurn).toBe(true);
      expect(details.canvasId).toBe('test-canvas');
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

      const details = result.details as { needsRetry?: boolean };
      expect(result.isError).toBe(false);
      expect(result.stopTurn).toBe(true);
      expect(details.needsRetry).toBeUndefined();
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

      const details = result.details as { ui?: unknown; state?: unknown };
      expect(details.ui).toEqual(ui);
      expect(details.state).toEqual(state);
    });
  });

  describe('validation failure - retry behavior', () => {
    it('should return stopTurn=false on first validation failure', async () => {
      const result = await tool.execute({
        canvasId: 'test',
        ui: { $tag: 'Button' }, // Missing label and actionId
      });

      const details = result.details as { needsRetry?: boolean };
      expect(result.isError).toBe(false); // NOT an error - allow retry
      expect(result.stopTurn).toBe(false); // Allow turn to continue
      expect(details.needsRetry).toBe(true);
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

      const details = result.details as { canvasId?: string };
      expect(details.canvasId).toBe('canvas-123');
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
      const details = result.details as { title?: string };
      expect(result.content).toContain('My UI');
      expect(details.title).toBe('My UI');
    });

    it('should include async marker in details', async () => {
      const result = await tool.execute({
        canvasId: 'test',
        ui: { $tag: 'Text', $children: 'Hello' },
      });
      const details = result.details as { async?: boolean };
      expect(details.async).toBe(true);
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
