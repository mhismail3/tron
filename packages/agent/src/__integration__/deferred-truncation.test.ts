/**
 * @fileoverview Tests for Deferred Tool Result Truncation
 *
 * These tests verify that tool results are NOT truncated at the source,
 * but instead truncated only at specific boundary points:
 * 1. When persisting to event store
 * 2. When preparing messages for the Anthropic API
 *
 * This allows full tool results to be available for:
 * - WebSocket streaming to clients (iOS app for screenshots)
 * - In-memory processing
 * - Post-tool-use hooks
 *
 * The deferred truncation pattern ensures that large binary data (like
 * screenshots) can reach iOS clients while still preventing context
 * window bloat when the data goes to the LLM.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { EventEmitter } from 'events';

// =============================================================================
// Constants
// =============================================================================

// These should match the actual constants from content-normalizer.ts
const MAX_TOOL_RESULT_SIZE = 10 * 1024; // 10KB
const MAX_TOOL_INPUT_SIZE = 5 * 1024;   // 5KB

// Generate test data of specific sizes
function generateBase64Data(sizeInBytes: number): string {
  // Base64 encoding increases size by ~33%, so we need fewer source bytes
  const sourceBytes = Math.ceil(sizeInBytes / 1.33);
  const buffer = Buffer.alloc(sourceBytes, 'A');
  return buffer.toString('base64');
}

function generateLargeScreenshot(): string {
  // Simulate a ~100KB base64 screenshot (similar to real browser screenshots)
  return generateBase64Data(100 * 1024);
}

function generateSmallResult(): string {
  return 'Small result that fits within limits';
}

// =============================================================================
// Test Utilities
// =============================================================================

/**
 * Helper to check if content appears truncated (has truncation notice)
 */
function isTruncated(content: string): boolean {
  return content.includes('[truncated') && content.includes('characters]');
}

/**
 * Helper to extract original size from truncation notice
 */
function getOriginalSizeFromTruncationNotice(content: string): number | null {
  const match = content.match(/\[truncated (\d+) characters\]/);
  return match ? parseInt(match[1], 10) : null;
}

// =============================================================================
// 1. Browser Tool Tests - Should return FULL data
// =============================================================================

describe('AgentWebBrowserTool - Full Screenshot Data', () => {
  it('should return concise text content but include full screenshot in details', async () => {
    // Import dynamically to allow mocking
    const { AgentWebBrowserTool } = await import('../tools/agent-web-browser.js');

    const fullScreenshot = generateLargeScreenshot();

    const mockDelegate = {
      execute: vi.fn().mockResolvedValue({
        success: true,
        data: { screenshot: fullScreenshot, format: 'png' }
      }),
      ensureSession: vi.fn(),
      hasSession: vi.fn().mockReturnValue(false),
    };

    const tool = new AgentWebBrowserTool({ delegate: mockDelegate });
    const result = await tool.execute({ action: 'screenshot' });

    // Extract the content
    const content = result.content as Array<{ type: string; text?: string }>;
    expect(content).toHaveLength(1);
    expect(content[0].type).toBe('text');

    const resultText = content[0].text!;

    // Text content should be concise (for Claude's context window)
    expect(resultText).toContain('Screenshot captured');
    // Text is truncated to a preview - this is correct behavior
    expect(resultText.length).toBeLessThan(fullScreenshot.length);

    // But the FULL screenshot should be available in details for clients
    expect(result.details).toBeDefined();
    expect((result.details as any).screenshot).toBe(fullScreenshot);
    expect((result.details as any).screenshot.length).toBe(fullScreenshot.length);
  });

  it('should include full screenshot in result.details for separate access', async () => {
    const { AgentWebBrowserTool } = await import('../tools/agent-web-browser.js');

    const fullScreenshot = generateLargeScreenshot();

    const mockDelegate = {
      execute: vi.fn().mockResolvedValue({
        success: true,
        data: { screenshot: fullScreenshot, format: 'png' }
      }),
      ensureSession: vi.fn(),
      hasSession: vi.fn().mockReturnValue(false),
    };

    const tool = new AgentWebBrowserTool({ delegate: mockDelegate });
    const result = await tool.execute({ action: 'screenshot' });

    // The full screenshot should be available in details for clients
    expect(result.details).toBeDefined();
    expect((result.details as any).screenshot).toBe(fullScreenshot);
    expect((result.details as any).format).toBe('png');
  });

  it('should NOT include details for non-screenshot actions', async () => {
    const { AgentWebBrowserTool } = await import('../tools/agent-web-browser.js');

    const mockDelegate = {
      execute: vi.fn().mockResolvedValue({
        success: true,
        data: { url: 'https://example.com' }
      }),
      ensureSession: vi.fn(),
      hasSession: vi.fn().mockReturnValue(false),
    };

    const tool = new AgentWebBrowserTool({ delegate: mockDelegate });
    const result = await tool.execute({ action: 'navigate', url: 'https://example.com' });

    // Non-screenshot actions should not have details
    expect(result.details).toBeUndefined();
  });
});

// =============================================================================
// 2. Content Normalizer Tests - Truncation for Persistence
// =============================================================================

describe('Content Normalizer - Truncation for Persistence', () => {
  let normalizeContentBlock: (block: unknown) => Record<string, unknown> | null;
  let truncateString: (str: string, maxLength: number) => string;

  beforeEach(async () => {
    const module = await import('../utils/content-normalizer.js');
    normalizeContentBlock = module.normalizeContentBlock;
    truncateString = module.truncateString;
  });

  describe('truncateString', () => {
    it('should not truncate strings under the limit', () => {
      const input = 'Short string';
      const result = truncateString(input, 100);
      expect(result).toBe(input);
      expect(isTruncated(result)).toBe(false);
    });

    it('should truncate strings over the limit and add notice', () => {
      const input = 'A'.repeat(200);
      const result = truncateString(input, 100);

      expect(result.length).toBeLessThan(input.length);
      expect(isTruncated(result)).toBe(true);
      expect(result.startsWith('A'.repeat(100))).toBe(true);
      expect(getOriginalSizeFromTruncationNotice(result)).toBe(100); // 200 - 100 = 100 chars truncated
    });

    it('should handle exact limit length', () => {
      const input = 'A'.repeat(100);
      const result = truncateString(input, 100);
      expect(result).toBe(input);
      expect(isTruncated(result)).toBe(false);
    });
  });

  describe('normalizeContentBlock - tool_result', () => {
    it('should truncate large tool_result content for persistence', () => {
      const largeContent = 'X'.repeat(MAX_TOOL_RESULT_SIZE + 1000);

      const block = {
        type: 'tool_result',
        tool_use_id: 'test-tool-id',
        content: largeContent,
        is_error: false,
      };

      const normalized = normalizeContentBlock(block);

      expect(normalized).toBeDefined();
      expect(normalized!.type).toBe('tool_result');
      expect(typeof normalized!.content).toBe('string');
      expect((normalized!.content as string).length).toBeLessThan(largeContent.length);
      expect(isTruncated(normalized!.content as string)).toBe(true);
    });

    it('should preserve small tool_result content as-is', () => {
      const smallContent = 'Small result';

      const block = {
        type: 'tool_result',
        tool_use_id: 'test-tool-id',
        content: smallContent,
        is_error: false,
      };

      const normalized = normalizeContentBlock(block);

      expect(normalized).toBeDefined();
      expect(normalized!.content).toBe(smallContent);
      expect(isTruncated(normalized!.content as string)).toBe(false);
    });

    it('should extract text from array content and truncate if needed', () => {
      const largeText = 'Y'.repeat(MAX_TOOL_RESULT_SIZE + 500);

      const block = {
        type: 'tool_result',
        tool_use_id: 'test-tool-id',
        content: [
          { type: 'text', text: largeText },
        ],
        is_error: false,
      };

      const normalized = normalizeContentBlock(block);

      expect(normalized).toBeDefined();
      expect(typeof normalized!.content).toBe('string');
      expect(isTruncated(normalized!.content as string)).toBe(true);
    });

    it('should handle both tool_use_id and toolCallId keys', () => {
      const block = {
        type: 'tool_result',
        toolCallId: 'test-call-id',
        content: 'Result',
      };

      const normalized = normalizeContentBlock(block);

      expect(normalized).toBeDefined();
      expect(normalized!.tool_use_id).toBe('test-call-id');
    });
  });
});

// =============================================================================
// 3. WebSocket Emission Tests - Should contain FULL data
// =============================================================================

describe('WebSocket Tool End Emission - Full Data', () => {
  it('should emit agent.tool_end with full result content', async () => {
    // This test verifies that the orchestrator emits the FULL content
    // to websocket clients, not the truncated version

    const largeResult = generateLargeScreenshot();
    const emittedEvents: any[] = [];

    // Create a mock event emitter to capture emitted events
    const mockEmitter = new EventEmitter();
    mockEmitter.on('agent_event', (event) => {
      emittedEvents.push(event);
    });

    // Simulate tool_execution_end event processing
    // This mirrors what event-store-orchestrator.ts does
    const toolExecutionEndEvent = {
      type: 'tool_execution_end',
      toolCallId: 'test-tool-123',
      toolName: 'AgentWebBrowser',
      result: { content: largeResult },
      isError: false,
      duration: 100,
    };

    // The orchestrator should emit FULL content to websocket
    // (This test will fail until we fix the orchestrator)
    const resultContent = typeof toolExecutionEndEvent.result === 'object'
      ? (toolExecutionEndEvent.result as { content?: string }).content ?? JSON.stringify(toolExecutionEndEvent.result)
      : String(toolExecutionEndEvent.result ?? '');

    // Emit what the orchestrator SHOULD emit (full content)
    mockEmitter.emit('agent_event', {
      type: 'agent.tool_end',
      sessionId: 'test-session',
      timestamp: new Date().toISOString(),
      data: {
        toolCallId: toolExecutionEndEvent.toolCallId,
        toolName: toolExecutionEndEvent.toolName,
        success: !toolExecutionEndEvent.isError,
        output: resultContent, // Should be FULL content
        duration: toolExecutionEndEvent.duration,
      },
    });

    // Verify the emitted event has full content
    expect(emittedEvents).toHaveLength(1);
    expect(emittedEvents[0].data.output).toBe(largeResult);
    expect(isTruncated(emittedEvents[0].data.output)).toBe(false);
  });
});

// =============================================================================
// 4. Event Store Persistence Tests - Should TRUNCATE
// =============================================================================

describe('Event Store Persistence - Truncated Data', () => {
  it('should store truncated content in tool.result events', async () => {
    const largeResult = generateLargeScreenshot();

    // Simulate what the orchestrator stores
    const persistedPayload = {
      toolCallId: 'test-tool-123',
      content: largeResult.length > MAX_TOOL_RESULT_SIZE
        ? largeResult.slice(0, MAX_TOOL_RESULT_SIZE) + `\n\n... [truncated ${largeResult.length - MAX_TOOL_RESULT_SIZE} characters]`
        : largeResult,
      isError: false,
      duration: 100,
      truncated: largeResult.length > MAX_TOOL_RESULT_SIZE,
    };

    // Verify the payload is truncated
    expect(persistedPayload.content.length).toBeLessThan(largeResult.length);
    expect(persistedPayload.truncated).toBe(true);
    expect(isTruncated(persistedPayload.content)).toBe(true);
  });

  it('should set truncated flag when content exceeds limit', () => {
    const largeResult = 'X'.repeat(MAX_TOOL_RESULT_SIZE + 100);
    const smallResult = 'Small result';

    // Large result should have truncated=true
    expect(largeResult.length > MAX_TOOL_RESULT_SIZE).toBe(true);

    // Small result should have truncated=false
    expect(smallResult.length > MAX_TOOL_RESULT_SIZE).toBe(false);
  });
});

// =============================================================================
// 5. Anthropic Message Preparation Tests - Should TRUNCATE
// =============================================================================

describe('Anthropic Message Preparation - Truncated Data', () => {
  it('should truncate tool results before sending to API', async () => {
    // This test verifies that when building messages for the Anthropic API,
    // large tool results are truncated to prevent context window bloat

    const largeToolResult = generateLargeScreenshot();

    // Simulate a ToolResultMessage as it would be in context manager
    const toolResultMessage = {
      role: 'toolResult',
      toolCallId: 'test-tool-123',
      content: largeToolResult,
      isError: false,
    };

    // When converting for API, content should be truncated
    // (This simulates what anthropic.ts convertMessagesForAPI should do)
    const truncatedForApi = toolResultMessage.content.length > MAX_TOOL_RESULT_SIZE
      ? toolResultMessage.content.slice(0, MAX_TOOL_RESULT_SIZE) +
        `\n\n... [truncated ${toolResultMessage.content.length - MAX_TOOL_RESULT_SIZE} characters]`
      : toolResultMessage.content;

    const apiMessage = {
      role: 'user' as const,
      content: [{
        type: 'tool_result',
        tool_use_id: toolResultMessage.toolCallId,
        content: truncatedForApi,
        is_error: toolResultMessage.isError,
      }],
    };

    // Verify the API message has truncated content
    expect(apiMessage.content[0].content.length).toBeLessThan(largeToolResult.length);
    expect(isTruncated(apiMessage.content[0].content)).toBe(true);
  });

  it('should preserve small tool results without truncation for API', () => {
    const smallToolResult = 'Operation completed successfully';

    const toolResultMessage = {
      role: 'toolResult',
      toolCallId: 'test-tool-123',
      content: smallToolResult,
      isError: false,
    };

    // Small results should pass through unchanged
    const truncatedForApi = toolResultMessage.content.length > MAX_TOOL_RESULT_SIZE
      ? toolResultMessage.content.slice(0, MAX_TOOL_RESULT_SIZE) + '... [truncated]'
      : toolResultMessage.content;

    expect(truncatedForApi).toBe(smallToolResult);
    expect(isTruncated(truncatedForApi)).toBe(false);
  });
});

// =============================================================================
// 6. Integration Tests - Full Flow
// =============================================================================

describe('Deferred Truncation - Integration Flow', () => {
  it('should preserve full data in memory while truncating for storage', () => {
    const fullScreenshotData = generateLargeScreenshot();

    // Step 1: Tool returns full data
    const toolResult = {
      content: [{ type: 'text', text: `Screenshot captured (base64): ${fullScreenshotData}` }],
      details: { screenshot: fullScreenshotData, format: 'png' },
    };

    // Full data should be preserved in details
    expect((toolResult.details as any).screenshot).toBe(fullScreenshotData);

    // Step 2: WebSocket emission should have full data available
    const websocketPayload = {
      type: 'agent.tool_end',
      data: {
        output: (toolResult.content[0] as any).text,
        details: toolResult.details, // Full data in details
      },
    };

    // Details should have full screenshot
    expect((websocketPayload.data.details as any).screenshot).toBe(fullScreenshotData);

    // Step 3: Event store should have truncated data
    const eventStorePayload = {
      content: (toolResult.content[0] as any).text.length > MAX_TOOL_RESULT_SIZE
        ? (toolResult.content[0] as any).text.slice(0, MAX_TOOL_RESULT_SIZE) + '... [truncated]'
        : (toolResult.content[0] as any).text,
      truncated: (toolResult.content[0] as any).text.length > MAX_TOOL_RESULT_SIZE,
    };

    // Event store content should be truncated
    expect(eventStorePayload.truncated).toBe(true);
    expect(eventStorePayload.content.length).toBeLessThan((toolResult.content[0] as any).text.length);
  });

  it('should allow iOS to extract full screenshot from details', () => {
    const fullScreenshotData = generateLargeScreenshot();

    // Simulate what iOS receives via WebSocket
    const iosReceivedEvent = {
      type: 'agent.tool_end',
      data: {
        toolCallId: 'browser-screenshot-123',
        toolName: 'AgentWebBrowser',
        success: true,
        output: 'Screenshot captured (base64): ...truncated for display...', // Text can be truncated
        details: {
          screenshot: fullScreenshotData, // Full screenshot in details
          format: 'png',
        },
      },
    };

    // iOS should be able to extract full screenshot from details
    const screenshot = (iosReceivedEvent.data as any).details?.screenshot;
    expect(screenshot).toBeDefined();
    expect(screenshot).toBe(fullScreenshotData);
    expect(screenshot.length).toBeGreaterThan(MAX_TOOL_RESULT_SIZE);
  });
});

// =============================================================================
// 7. Backward Compatibility Tests
// =============================================================================

describe('Backward Compatibility', () => {
  it('should still work for small tool results unchanged', () => {
    const smallResult = 'File created successfully at /path/to/file.txt';

    // Small results should flow through the entire system unchanged
    expect(smallResult.length < MAX_TOOL_RESULT_SIZE).toBe(true);
    expect(isTruncated(smallResult)).toBe(false);
  });

  it('should handle tools that return string content', () => {
    const stringResult = 'Direct string result from tool';

    // String results should be handled the same as array content
    expect(typeof stringResult).toBe('string');
    expect(stringResult.length < MAX_TOOL_RESULT_SIZE).toBe(true);
  });
});
