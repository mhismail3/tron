/**
 * @fileoverview Tests for Model RPC Handlers
 *
 * Tests model.switch and model.list handlers
 * using the registry dispatch pattern.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createModelHandlers } from '../model.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';
import { ANTHROPIC_MODELS } from '@llm/providers/models.js';
import { OPENAI_MODELS } from '@llm/providers/openai/index.js';
import { GEMINI_MODELS } from '@llm/providers/google/index.js';

describe('Model Handlers', () => {
  let registry: MethodRegistry;
  let mockContext: RpcContext;
  let mockContextWithoutSessionManager: RpcContext;
  let mockSwitchModel: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    registry = new MethodRegistry();
    registry.registerAll(createModelHandlers());

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
    };

    mockContextWithoutSessionManager = {
      agentManager: {} as any,
    };
  });

  describe('model.switch', () => {
    it('should switch model for a session', async () => {
      const validModel = ANTHROPIC_MODELS[0]?.id || 'claude-sonnet-4-20250514';
      const request: RpcRequest = {
        id: '1',
        method: 'model.switch',
        params: { sessionId: 'sess-123', model: validModel },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockSwitchModel).toHaveBeenCalledWith('sess-123', validModel);
    });

    it('should return error for missing sessionId', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'model.switch',
        params: { model: 'claude-3-opus' },
      };

      const response = await registry.dispatch(request, mockContext);

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

      const response = await registry.dispatch(request, mockContext);

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

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('Unknown model');
    });

    it('should return NOT_AVAILABLE without sessionManager', async () => {
      const validModel = ANTHROPIC_MODELS[0]?.id || 'claude-sonnet-4-20250514';
      const request: RpcRequest = {
        id: '1',
        method: 'model.switch',
        params: { sessionId: 'sess-123', model: validModel },
      };

      const response = await registry.dispatch(request, mockContextWithoutSessionManager);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });
  });

  describe('model.list', () => {
    it('should return list of models', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'model.list',
      };

      const response = await registry.dispatch(request, mockContext);

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

      const response = await registry.dispatch(request, mockContext);

      const result = response.result as { models: any[] };
      const anthropicModels = result.models.filter(m => m.provider === 'anthropic');
      expect(anthropicModels.length).toBeGreaterThan(0);
    });

    it('should include model capabilities', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'model.list',
      };

      const response = await registry.dispatch(request, mockContext);

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

  // ===========================================================================
  // Opus 4.6 Model List Tests
  // ===========================================================================

  describe('Opus 4.6 in Model List', () => {
    it('includes claude-opus-4-6 with supportsReasoning=true', async () => {
      const request: RpcRequest = { id: '1', method: 'model.list' };
      const response = await registry.dispatch(request, mockContext);
      const result = response.result as { models: any[] };
      const opus46 = result.models.find(m => m.id === 'claude-opus-4-6');
      expect(opus46).toBeDefined();
      expect(opus46?.supportsReasoning).toBe(true);
    });

    it('includes reasoningLevels [low, medium, high, max] for opus 4.6', async () => {
      const request: RpcRequest = { id: '1', method: 'model.list' };
      const response = await registry.dispatch(request, mockContext);
      const result = response.result as { models: any[] };
      const opus46 = result.models.find(m => m.id === 'claude-opus-4-6');
      expect(opus46?.reasoningLevels).toEqual(['low', 'medium', 'high', 'max']);
      expect(opus46?.defaultReasoningLevel).toBe('high');
    });

    // REGRESSION
    it('does NOT include supportsReasoning for opus 4.5 (regression)', async () => {
      const request: RpcRequest = { id: '1', method: 'model.list' };
      const response = await registry.dispatch(request, mockContext);
      const result = response.result as { models: any[] };
      const opus45 = result.models.find(m => m.id === 'claude-opus-4-5-20251101');
      expect(opus45).toBeDefined();
      expect(opus45?.supportsReasoning).toBeFalsy();
      expect(opus45?.reasoningLevels).toBeUndefined();
    });

    it('model.switch accepts claude-opus-4-6', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'model.switch',
        params: { sessionId: 'sess-123', model: 'claude-opus-4-6' },
      };
      const response = await registry.dispatch(request, mockContext);
      expect(response.success).toBe(true);
      expect(mockSwitchModel).toHaveBeenCalledWith('sess-123', 'claude-opus-4-6');
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

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockSwitchModel).toHaveBeenCalledWith('sess-123', 'gemini-3-pro-preview');
    });

    it('should accept gemini-3-flash-preview as valid model', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'model.switch',
        params: { sessionId: 'sess-123', model: 'gemini-3-flash-preview' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockSwitchModel).toHaveBeenCalledWith('sess-123', 'gemini-3-flash-preview');
    });

    it('should include Gemini models in model.list response', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'model.list',
      };

      const response = await registry.dispatch(request, mockContext);

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

      const response = await registry.dispatch(request, mockContext);

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

      const response = await registry.dispatch(request, mockContext);

      const result = response.result as { models: any[] };
      const gemini3Pro = result.models.find(m => m.id === 'gemini-3-pro-preview');

      expect(gemini3Pro?.thinkingLevel).toBeDefined();
      expect(gemini3Pro?.supportedThinkingLevels).toBeDefined();
    });
  });

  // ===========================================================================
  // Model Metadata Tests (family, pricing, description, etc.)
  // ===========================================================================

  describe('Model Metadata Fields', () => {
    let models: any[];

    beforeEach(async () => {
      const request: RpcRequest = { id: '1', method: 'model.list' };
      const response = await registry.dispatch(request, mockContext);
      models = (response.result as { models: any[] }).models;
    });

    describe('Anthropic metadata', () => {
      it('includes family for all Anthropic models', () => {
        const anthropic = models.filter(m => m.provider === 'anthropic');
        expect(anthropic.length).toBe(ANTHROPIC_MODELS.length);
        for (const model of anthropic) {
          expect(model.family).toBeDefined();
          expect(model.family).toMatch(/^Claude/);
        }
      });

      it('includes pricing for all Anthropic models', () => {
        const anthropic = models.filter(m => m.provider === 'anthropic');
        for (const model of anthropic) {
          expect(typeof model.inputCostPerMillion).toBe('number');
          expect(typeof model.outputCostPerMillion).toBe('number');
          expect(model.inputCostPerMillion).toBeGreaterThan(0);
          expect(model.outputCostPerMillion).toBeGreaterThan(0);
        }
      });

      it('includes maxOutput, description, releaseDate for Anthropic', () => {
        const opus46 = models.find(m => m.id === 'claude-opus-4-6');
        expect(opus46?.maxOutput).toBe(128000);
        expect(opus46?.description).toContain('capable');
        expect(opus46?.releaseDate).toMatch(/^\d{4}-\d{2}-\d{2}$/);
        expect(opus46?.recommended).toBe(true);
        expect(opus46?.family).toBe('Claude 4.6');
      });

      it('marks legacy Anthropic models correctly', () => {
        const opus41 = models.find(m => m.id === 'claude-opus-4-1-20250805');
        expect(opus41?.isLegacy).toBe(true);
        expect(opus41?.family).toBe('Claude 4.1');
      });
    });

    describe('OpenAI Codex metadata', () => {
      it('includes family for all OpenAI models', () => {
        const openai = models.filter(m => m.provider === 'openai-codex');
        expect(openai.length).toBe(Object.keys(OPENAI_MODELS).length);
        for (const model of openai) {
          expect(model.family).toBeDefined();
          expect(model.family).toMatch(/^GPT-5/);
        }
      });

      it('includes pricing for OpenAI models', () => {
        const gpt52 = models.find(m => m.id === 'gpt-5.2-codex');
        expect(gpt52?.inputCostPerMillion).toBe(1.75);
        expect(gpt52?.outputCostPerMillion).toBe(14);
      });

      it('includes maxOutput and description for OpenAI', () => {
        const gpt53 = models.find(m => m.id === 'gpt-5.3-codex');
        expect(gpt53?.maxOutput).toBe(128000);
        expect(gpt53?.description).toBeDefined();
        expect(gpt53?.recommended).toBe(true);
        expect(gpt53?.family).toBe('GPT-5.3');
      });
    });

    describe('Gemini metadata', () => {
      it('includes derived family for all Gemini models', () => {
        const gemini = models.filter(m => m.provider === 'google');
        expect(gemini.length).toBe(Object.keys(GEMINI_MODELS).length);

        const gemini3Pro = gemini.find(m => m.id === 'gemini-3-pro-preview');
        expect(gemini3Pro?.family).toBe('Gemini 3');

        const gemini25Pro = gemini.find(m => m.id === 'gemini-2.5-pro');
        expect(gemini25Pro?.family).toBe('Gemini 2.5');
      });

      it('normalizes Gemini pricing from per-1k to per-million', () => {
        const gemini3Pro = models.find(m => m.id === 'gemini-3-pro-preview');
        // inputCostPer1k: 0.00125 → inputCostPerMillion: 1.25
        expect(gemini3Pro?.inputCostPerMillion).toBeCloseTo(1.25);
        // outputCostPer1k: 0.005 → outputCostPerMillion: 5
        expect(gemini3Pro?.outputCostPerMillion).toBeCloseTo(5);
      });

      it('includes maxOutput and description for Gemini', () => {
        const gemini3Pro = models.find(m => m.id === 'gemini-3-pro-preview');
        expect(gemini3Pro?.maxOutput).toBe(65536);
        expect(gemini3Pro?.description).toContain('Gemini 3 Pro');
        expect(gemini3Pro?.recommended).toBe(true);
      });

      it('marks only Gemini 3 Pro as recommended', () => {
        const gemini = models.filter(m => m.provider === 'google');
        const recommended = gemini.filter(m => m.recommended === true);
        expect(recommended.length).toBe(1);
        expect(recommended[0].id).toBe('gemini-3-pro-preview');
      });
    });

    describe('Cross-provider consistency', () => {
      it('all models have family, maxOutput, description, and pricing', () => {
        for (const model of models) {
          expect(model.family).toBeDefined();
          expect(typeof model.maxOutput).toBe('number');
          expect(model.maxOutput).toBeGreaterThan(0);
          expect(model.description).toBeDefined();
          expect(typeof model.inputCostPerMillion).toBe('number');
          expect(typeof model.outputCostPerMillion).toBe('number');
        }
      });
    });
  });
});
