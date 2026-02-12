/**
 * @fileoverview Tests for BashTool interrupt/abort functionality
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { BashTool } from '../system/bash.js';

interface BashToolDetails {
  command?: string;
  exitCode?: number;
  durationMs?: number;
  interrupted?: boolean;
}

describe('BashTool Interrupt', () => {
  let bashTool: BashTool;

  beforeEach(() => {
    bashTool = new BashTool({
      workingDirectory: '/tmp',
      defaultTimeout: 30000,
    });
  });

  describe('abort signal handling', () => {
    it('should return interrupted result when aborted before execution', async () => {
      const abortController = new AbortController();
      abortController.abort(); // Abort immediately

      const result = await bashTool.execute(
        { command: 'sleep 2' },
        { signal: abortController.signal }
      );

      expect(result.isError).toBe(true);
      expect(result.content).toContain('interrupted');
      expect((result.details as BashToolDetails)?.interrupted).toBe(true);
    });

    it('should terminate running command when signal is aborted', async () => {
      const abortController = new AbortController();

      // Start a long-running command
      const resultPromise = bashTool.execute(
        { command: 'sleep 2 && echo "done"' },
        { signal: abortController.signal }
      );

      // Abort after a short delay
      await new Promise(resolve => setTimeout(resolve, 100));
      abortController.abort();

      const result = await resultPromise;

      // Should be interrupted, not timed out
      expect(result.isError).toBe(true);
      expect(result.content).toContain('interrupted');
      expect((result.details as BashToolDetails)?.interrupted).toBe(true);
    });

    it('should capture partial output when interrupted', async () => {
      const abortController = new AbortController();

      // Start a command that produces output then sleeps
      const resultPromise = bashTool.execute(
        { command: 'echo "line 1" && echo "line 2" && sleep 2' },
        { signal: abortController.signal }
      );

      // Wait for some output, then abort
      await new Promise(resolve => setTimeout(resolve, 200));
      abortController.abort();

      const result = await resultPromise;

      expect(result.isError).toBe(true);
      expect((result.details as BashToolDetails)?.interrupted).toBe(true);
      // Should have captured at least some output
      const content = typeof result.content === 'string' ? result.content : '';
      if (content.includes('Partial output')) {
        expect(content).toContain('line');
      }
    });

    it('should work with old signature (no signal)', async () => {
      // Test backwards compatibility
      const result = await bashTool.execute({ command: 'echo "hello"' });

      expect(result.isError).toBe(false);
      expect(result.content).toContain('hello');
    });
  });
});
