/**
 * @fileoverview Tests for AgentToolExecutor
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { AgentToolExecutor, createToolExecutor } from '../tool-executor.js';
import { createEventEmitter } from '../event-emitter.js';
import { HookEngine } from '../../hooks/engine.js';
import type { TronTool } from '../../types/tools.js';
import type { ContextManager } from '../../context/context-manager.js';

describe('AgentToolExecutor', () => {
  let executor: AgentToolExecutor;
  let eventEmitter: ReturnType<typeof createEventEmitter>;
  let hookEngine: HookEngine;
  let mockContextManager: Partial<ContextManager>;
  let mockTools: Map<string, TronTool>;
  let mockAbortController: AbortController;

  beforeEach(() => {
    eventEmitter = createEventEmitter();
    hookEngine = new HookEngine();
    mockAbortController = new AbortController();

    mockContextManager = {
      processToolResult: vi.fn().mockImplementation(({ content }) => ({
        toolCallId: 'call_123',
        content,
        truncated: false,
        originalSize: content.length,
      })),
    };

    mockTools = new Map();

    executor = createToolExecutor({
      tools: mockTools,
      hookEngine,
      contextManager: mockContextManager as ContextManager,
      eventEmitter,
      sessionId: 'sess_test',
      getAbortSignal: () => mockAbortController.signal,
    });
  });

  describe('getActiveTool', () => {
    it('should return null initially', () => {
      expect(executor.getActiveTool()).toBeNull();
    });
  });

  describe('clearActiveTool', () => {
    it('should clear the active tool', async () => {
      const tool: TronTool = {
        name: 'TestTool',
        description: 'Test tool',
        parameters: { type: 'object' },
        execute: vi.fn().mockResolvedValue({ content: 'result' }),
      };
      mockTools.set('TestTool', tool);

      // Execute to set active tool
      const promise = executor.execute({
        toolCallId: 'call_123',
        toolName: 'TestTool',
        arguments: {},
      });

      executor.clearActiveTool();
      expect(executor.getActiveTool()).toBeNull();

      await promise;
    });
  });

  describe('execute', () => {
    it('should execute a tool and return result', async () => {
      const tool: TronTool = {
        name: 'TestTool',
        description: 'Test tool',
        parameters: { type: 'object' },
        execute: vi.fn().mockResolvedValue({ content: 'Tool result' }),
      };
      mockTools.set('TestTool', tool);

      const result = await executor.execute({
        toolCallId: 'call_123',
        toolName: 'TestTool',
        arguments: { arg1: 'value1' },
      });

      expect(result.result.content).toBe('Tool result');
      expect(result.result.isError).toBe(false);
      expect(result.duration).toBeGreaterThanOrEqual(0);
    });

    it('should return error for non-existent tool', async () => {
      const result = await executor.execute({
        toolCallId: 'call_123',
        toolName: 'NonExistent',
        arguments: {},
      });

      expect(result.result.isError).toBe(true);
      expect(result.result.content).toContain('Tool not found');
    });

    it('should handle tool execution errors', async () => {
      const tool: TronTool = {
        name: 'ErrorTool',
        description: 'Tool that throws',
        parameters: { type: 'object' },
        execute: vi.fn().mockRejectedValue(new Error('Tool failed')),
      };
      mockTools.set('ErrorTool', tool);

      const result = await executor.execute({
        toolCallId: 'call_123',
        toolName: 'ErrorTool',
        arguments: {},
      });

      expect(result.result.isError).toBe(true);
      expect(result.result.content).toContain('Tool failed');
    });

    it('should emit tool_execution_start and tool_execution_end events', async () => {
      const listener = vi.fn();
      eventEmitter.addListener(listener);

      const tool: TronTool = {
        name: 'TestTool',
        description: 'Test tool',
        parameters: { type: 'object' },
        execute: vi.fn().mockResolvedValue({ content: 'result' }),
      };
      mockTools.set('TestTool', tool);

      await executor.execute({
        toolCallId: 'call_123',
        toolName: 'TestTool',
        arguments: {},
      });

      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'tool_execution_start',
          toolName: 'TestTool',
        })
      );

      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'tool_execution_end',
          toolName: 'TestTool',
        })
      );
    });

    it('should pass arguments to tool execute function', async () => {
      const executeFn = vi.fn().mockResolvedValue({ content: 'result' });
      const tool: TronTool = {
        name: 'TestTool',
        description: 'Test tool',
        parameters: { type: 'object' },
        execute: executeFn,
      };
      mockTools.set('TestTool', tool);

      await executor.execute({
        toolCallId: 'call_123',
        toolName: 'TestTool',
        arguments: { file_path: '/test.txt', line: 42 },
      });

      expect(executeFn).toHaveBeenCalledWith(
        expect.objectContaining({ file_path: '/test.txt', line: 42 })
      );
    });

    it('should use new signature for tools with 3+ parameters', async () => {
      const executeFn = vi.fn(
        async (id: string, args: Record<string, unknown>, signal: AbortSignal) => ({
          content: `ID: ${id}, hasSignal: ${!!signal}`,
        })
      );
      const tool: TronTool = {
        name: 'NewTool',
        description: 'Tool with new signature',
        parameters: { type: 'object' },
        execute: executeFn,
      };
      mockTools.set('NewTool', tool);

      const result = await executor.execute({
        toolCallId: 'call_456',
        toolName: 'NewTool',
        arguments: { arg: 'value' },
      });

      expect(result.result.content).toContain('call_456');
      expect(result.result.content).toContain('hasSignal: true');
    });

    it('should handle stopTurn in tool result', async () => {
      const tool: TronTool = {
        name: 'StopTool',
        description: 'Tool that stops turn',
        parameters: { type: 'object' },
        execute: vi.fn().mockResolvedValue({
          content: 'Waiting for user input',
          stopTurn: true,
        }),
      };
      mockTools.set('StopTool', tool);

      const result = await executor.execute({
        toolCallId: 'call_123',
        toolName: 'StopTool',
        arguments: {},
      });

      expect(result.result.stopTurn).toBe(true);
    });

    it('should process result through context manager safety net', async () => {
      const truncatedContent = 'truncated...';
      mockContextManager.processToolResult = vi.fn().mockReturnValue({
        toolCallId: 'call_123',
        content: truncatedContent,
        truncated: true,
        originalSize: 10000,
      });

      const tool: TronTool = {
        name: 'LargeTool',
        description: 'Tool with large output',
        parameters: { type: 'object' },
        execute: vi.fn().mockResolvedValue({ content: 'x'.repeat(10000) }),
      };
      mockTools.set('LargeTool', tool);

      const result = await executor.execute({
        toolCallId: 'call_123',
        toolName: 'LargeTool',
        arguments: {},
      });

      expect(result.result.content).toBe(truncatedContent);
    });

    it('should handle array content in tool result', async () => {
      const tool: TronTool = {
        name: 'ImageTool',
        description: 'Tool with image output',
        parameters: { type: 'object' },
        execute: vi.fn().mockResolvedValue({
          content: [
            { type: 'text', text: 'Here is an image:' },
            { type: 'image', data: 'base64data' },
          ],
        }),
      };
      mockTools.set('ImageTool', tool);

      const result = await executor.execute({
        toolCallId: 'call_123',
        toolName: 'ImageTool',
        arguments: {},
      });

      expect(result.result.content).toContain('Here is an image:');
      expect(result.result.content).toContain('[image]');
    });
  });

  describe('pre-tool hooks', () => {
    it('should execute pre-tool hooks', async () => {
      const hookHandler = vi.fn().mockResolvedValue({ action: 'continue' });
      hookEngine.register({
        name: 'TestPreHook',
        type: 'PreToolUse',
        handler: hookHandler,
      });

      const tool: TronTool = {
        name: 'TestTool',
        description: 'Test tool',
        parameters: { type: 'object' },
        execute: vi.fn().mockResolvedValue({ content: 'result' }),
      };
      mockTools.set('TestTool', tool);

      await executor.execute({
        toolCallId: 'call_123',
        toolName: 'TestTool',
        arguments: { arg: 'value' },
      });

      expect(hookHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          hookType: 'PreToolUse',
          toolName: 'TestTool',
          toolArguments: { arg: 'value' },
        })
      );
    });

    it('should block tool execution when hook returns block', async () => {
      hookEngine.register({
        name: 'BlockHook',
        type: 'PreToolUse',
        handler: async () => ({ action: 'block', reason: 'Blocked by hook' }),
      });

      const tool: TronTool = {
        name: 'TestTool',
        description: 'Test tool',
        parameters: { type: 'object' },
        execute: vi.fn().mockResolvedValue({ content: 'result' }),
      };
      mockTools.set('TestTool', tool);

      const result = await executor.execute({
        toolCallId: 'call_123',
        toolName: 'TestTool',
        arguments: {},
      });

      expect(result.result.isError).toBe(true);
      expect(result.result.content).toContain('blocked');
      expect(tool.execute).not.toHaveBeenCalled();
    });

    it('should modify arguments when hook returns modify', async () => {
      hookEngine.register({
        name: 'ModifyHook',
        type: 'PreToolUse',
        handler: async () => ({
          action: 'modify',
          modifications: { extra: 'modified' },
        }),
      });

      const executeFn = vi.fn().mockResolvedValue({ content: 'result' });
      const tool: TronTool = {
        name: 'TestTool',
        description: 'Test tool',
        parameters: { type: 'object' },
        execute: executeFn,
      };
      mockTools.set('TestTool', tool);

      await executor.execute({
        toolCallId: 'call_123',
        toolName: 'TestTool',
        arguments: { original: 'value' },
      });

      expect(executeFn).toHaveBeenCalledWith(
        expect.objectContaining({ original: 'value', extra: 'modified' })
      );
    });

    it('should emit hook events', async () => {
      const listener = vi.fn();
      eventEmitter.addListener(listener);

      hookEngine.register({
        name: 'TestHook',
        type: 'PreToolUse',
        handler: async () => ({ action: 'continue' }),
      });

      const tool: TronTool = {
        name: 'TestTool',
        description: 'Test tool',
        parameters: { type: 'object' },
        execute: vi.fn().mockResolvedValue({ content: 'result' }),
      };
      mockTools.set('TestTool', tool);

      await executor.execute({
        toolCallId: 'call_123',
        toolName: 'TestTool',
        arguments: {},
      });

      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'hook_triggered',
          hookEvent: 'PreToolUse',
        })
      );

      expect(listener).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'hook_completed',
          hookEvent: 'PreToolUse',
        })
      );
    });
  });

  describe('post-tool hooks', () => {
    it('should execute post-tool hooks', async () => {
      const hookHandler = vi.fn().mockResolvedValue({ action: 'continue' });
      hookEngine.register({
        name: 'TestPostHook',
        type: 'PostToolUse',
        handler: hookHandler,
      });

      const tool: TronTool = {
        name: 'TestTool',
        description: 'Test tool',
        parameters: { type: 'object' },
        execute: vi.fn().mockResolvedValue({ content: 'result' }),
      };
      mockTools.set('TestTool', tool);

      await executor.execute({
        toolCallId: 'call_123',
        toolName: 'TestTool',
        arguments: {},
      });

      expect(hookHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          hookType: 'PostToolUse',
          toolName: 'TestTool',
          result: expect.objectContaining({ content: 'result' }),
        })
      );
    });

    it('should include duration in post-hook context', async () => {
      const hookHandler = vi.fn().mockResolvedValue({ action: 'continue' });
      hookEngine.register({
        name: 'TestPostHook',
        type: 'PostToolUse',
        handler: hookHandler,
      });

      const tool: TronTool = {
        name: 'TestTool',
        description: 'Test tool',
        parameters: { type: 'object' },
        execute: vi.fn().mockResolvedValue({ content: 'result' }),
      };
      mockTools.set('TestTool', tool);

      await executor.execute({
        toolCallId: 'call_123',
        toolName: 'TestTool',
        arguments: {},
      });

      expect(hookHandler).toHaveBeenCalledWith(
        expect.objectContaining({
          duration: expect.any(Number),
        })
      );
    });
  });
});

describe('createToolExecutor', () => {
  it('should create a new instance', () => {
    const executor = createToolExecutor({
      tools: new Map(),
      hookEngine: new HookEngine(),
      contextManager: { processToolResult: () => ({ content: '', truncated: false, originalSize: 0 }) } as unknown as ContextManager,
      eventEmitter: createEventEmitter(),
      sessionId: 'sess_test',
      getAbortSignal: () => undefined,
    });

    expect(executor).toBeInstanceOf(AgentToolExecutor);
  });
});
