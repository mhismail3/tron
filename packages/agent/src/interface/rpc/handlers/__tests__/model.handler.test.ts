/**
 * @fileoverview Tests for Model RPC Handlers
 *
 * Tests model.switch and model.list handlers.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  createModelHandlers,
  handleModelSwitch,
  handleModelList,
} from '../model.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';
import { ANTHROPIC_MODELS } from '@llm/providers/models.js';

describe('Model Handlers', () => {
  let mockContext: RpcContext;
  let mockSwitchModel: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    mockSwitchModel = vi.fn().mockResolvedValue({
      sessionId: 'sess-123',
      previousModel: 'claude-3-sonnet',
      newModel: 'claude-3-opus',
    });

    mockContext = {
      sessionManager: {
        createSession: vi.fn(),
        getSession: vi.fn(),
        resumeSession: vi.fn(),
        listSessions: vi.fn(),
        deleteSession: vi.fn(),
        forkSession: vi.fn(),
        switchModel: mockSwitchModel,
      } as any,
      agentManager: {} as any,
      memoryStore: {} as any,
    };
  });

  describe('handleModelSwitch', () => {
    it('should switch model for a session', async () => {
      const validModel = ANTHROPIC_MODELS[0]?.id || 'claude-sonnet-4-20250514';
      const request: RpcRequest = {
        id: '1',
        method: 'model.switch',
        params: { sessionId: 'sess-123', model: validModel },
      };

      const response = await handleModelSwitch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockSwitchModel).toHaveBeenCalledWith('sess-123', validModel);
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'model.switch',
        params: { model: 'claude-3-opus' },
      };

      const response = await handleModelSwitch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('sessionId');
    });

    it('should return error for missing model', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'model.switch',
        params: { sessionId: 'sess-123' },
      };

      const response = await handleModelSwitch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('model');
    });

    it('should return error for unknown model', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'model.switch',
        params: { sessionId: 'sess-123', model: 'nonexistent-model' },
      };

      const response = await handleModelSwitch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('Unknown model');
    });
  });

  describe('handleModelList', () => {
    it('should return list of models', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'model.list',
      };

      const response = await handleModelList(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as { models: any[] };
      expect(result.models).toBeDefined();
      expect(Array.isArray(result.models)).toBe(true);
      expect(result.models.length).toBeGreaterThan(0);
    });

    it('should include anthropic models', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'model.list',
      };

      const response = await handleModelList(request, mockContext);

      const result = response.result as { models: any[] };
      const anthropicModels = result.models.filter(m => m.provider === 'anthropic');
      expect(anthropicModels.length).toBeGreaterThan(0);
    });

    it('should include model capabilities', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'model.list',
      };

      const response = await handleModelList(request, mockContext);

      const result = response.result as { models: any[] };
      const firstModel = result.models[0];
      expect(firstModel).toHaveProperty('id');
      expect(firstModel).toHaveProperty('name');
      expect(firstModel).toHaveProperty('provider');
      expect(firstModel).toHaveProperty('contextWindow');
      expect(firstModel).toHaveProperty('tier');
    });
  });

  describe('createModelHandlers', () => {
    it('should create handlers for registration', () => {
      const handlers = createModelHandlers();

      expect(handlers).toHaveLength(2);
      expect(handlers.map(h => h.method)).toContain('model.switch');
      expect(handlers.map(h => h.method)).toContain('model.list');
    });

    it('should have correct options for model.switch', () => {
      const handlers = createModelHandlers();
      const switchHandler = handlers.find(h => h.method === 'model.switch');

      expect(switchHandler?.options?.requiredParams).toContain('sessionId');
      expect(switchHandler?.options?.requiredParams).toContain('model');
      expect(switchHandler?.options?.requiredManagers).toContain('sessionManager');
    });
  });

  describe('Registry Integration', () => {
    it('should register and dispatch model handlers', async () => {
      const registry = new MethodRegistry();
      const handlers = createModelHandlers();
      registry.registerAll(handlers);

      expect(registry.has('model.switch')).toBe(true);
      expect(registry.has('model.list')).toBe(true);

      // Test model.list through registry
      const request: RpcRequest = {
        id: '1',
        method: 'model.list',
      };

      const response = await registry.dispatch(request, mockContext);
      expect(response.success).toBe(true);
      expect(response.result).toHaveProperty('models');
    });
  });

  // ===========================================================================
  // Gemini Model Validation Tests
  // ===========================================================================

  describe('Gemini Model Validation', () => {
    it('should accept gemini-3-pro-preview as valid model', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'model.switch',
        params: { sessionId: 'sess-123', model: 'gemini-3-pro-preview' },
      };

      const response = await handleModelSwitch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockSwitchModel).toHaveBeenCalledWith('sess-123', 'gemini-3-pro-preview');
    });

    it('should accept gemini-3-flash-preview as valid model', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'model.switch',
        params: { sessionId: 'sess-123', model: 'gemini-3-flash-preview' },
      };

      const response = await handleModelSwitch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockSwitchModel).toHaveBeenCalledWith('sess-123', 'gemini-3-flash-preview');
    });

    it('should include Gemini models in model.list response', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'model.list',
      };

      const response = await handleModelList(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as { models: any[] };

      // Should have Google/Gemini models
      const geminiModels = result.models.filter(m => m.provider === 'google');
      expect(geminiModels.length).toBeGreaterThan(0);

      // Should include Gemini 3 Pro
      const gemini3Pro = geminiModels.find(m => m.id === 'gemini-3-pro-preview');
      expect(gemini3Pro).toBeDefined();
      expect(gemini3Pro?.contextWindow).toBe(1048576);
      expect(gemini3Pro?.supportsThinking).toBe(true);
      expect(gemini3Pro?.tier).toBe('pro');

      // Should include Gemini 3 Flash
      const gemini3Flash = geminiModels.find(m => m.id === 'gemini-3-flash-preview');
      expect(gemini3Flash).toBeDefined();
      expect(gemini3Flash?.contextWindow).toBe(1048576);
      expect(gemini3Flash?.supportsThinking).toBe(true);
      expect(gemini3Flash?.tier).toBe('flash');
    });

    it('should include preview flag for Gemini 3 models', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'model.list',
      };

      const response = await handleModelList(request, mockContext);

      const result = response.result as { models: any[] };
      const gemini3Pro = result.models.find(m => m.id === 'gemini-3-pro-preview');
      const gemini3Flash = result.models.find(m => m.id === 'gemini-3-flash-preview');

      expect(gemini3Pro?.isPreview).toBe(true);
      expect(gemini3Flash?.isPreview).toBe(true);
    });

    it('should include thinking level information for Gemini models', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'model.list',
      };

      const response = await handleModelList(request, mockContext);

      const result = response.result as { models: any[] };
      const gemini3Pro = result.models.find(m => m.id === 'gemini-3-pro-preview');

      expect(gemini3Pro?.thinkingLevel).toBeDefined();
      expect(gemini3Pro?.supportedThinkingLevels).toBeDefined();
    });
  });
});
