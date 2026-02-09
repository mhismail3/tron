/**
 * @fileoverview Tests for Transcribe RPC Handlers
 *
 * Tests transcribe.audio and transcribe.listModels handlers
 * using the registry dispatch pattern.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { createTranscribeHandlers } from '../transcribe.handler.js';
import type { RpcRequest } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';

describe('Transcribe Handlers', () => {
  let registry: MethodRegistry;
  let mockContext: RpcContext;
  let mockContextWithoutTranscription: RpcContext;
  let mockTranscribeAudio: ReturnType<typeof vi.fn>;
  let mockListModels: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    registry = new MethodRegistry();
    registry.registerAll(createTranscribeHandlers());

    mockTranscribeAudio = vi.fn().mockResolvedValue({
      text: 'Hello world',
      language: 'en',
      durationSeconds: 5.2,
      model: 'parakeet-tdt-0.6b-v3',
    });

    mockListModels = vi.fn().mockResolvedValue({
      models: [
        { id: 'parakeet-tdt-0.6b-v3', name: 'Parakeet TDT', provider: 'mlx' },
      ],
    });

    mockContext = {
      sessionManager: {} as any,
      agentManager: {} as any,
      transcriptionManager: {
        transcribeAudio: mockTranscribeAudio,
        listModels: mockListModels,
      } as any,
    };

    mockContextWithoutTranscription = {
      sessionManager: {} as any,
      agentManager: {} as any,
    };
  });

  describe('transcribe.audio', () => {
    it('should transcribe audio', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'transcribe.audio',
        params: {
          audioBase64: 'base64encodedaudio',
          mimeType: 'audio/mp3',
        },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockTranscribeAudio).toHaveBeenCalledWith({
        audioBase64: 'base64encodedaudio',
        mimeType: 'audio/mp3',
      });
      const result = response.result as { text: string; language: string };
      expect(result.text).toBe('Hello world');
      expect(result.language).toBe('en');
    });

    it('should return error for missing audioBase64', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'transcribe.audio',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('audioBase64');
    });

    it('should return NOT_AVAILABLE when transcription not available', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'transcribe.audio',
        params: { audioBase64: 'base64data' },
      };

      const response = await registry.dispatch(request, mockContextWithoutTranscription);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });

    it('should handle transcription failures', async () => {
      mockTranscribeAudio.mockRejectedValueOnce(new Error('Audio format not supported'));

      const request: RpcRequest = {
        id: '1',
        method: 'transcribe.audio',
        params: { audioBase64: 'invalidaudio' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('TRANSCRIPTION_ERROR');
      expect(response.error?.message).toBe('Audio format not supported');
    });

    it('should pass optional parameters', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'transcribe.audio',
        params: {
          audioBase64: 'base64data',
          mimeType: 'audio/wav',
          fileName: 'recording.wav',
          transcriptionModelId: 'parakeet-tdt-0.6b-v3',
        },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockTranscribeAudio).toHaveBeenCalledWith({
        audioBase64: 'base64data',
        mimeType: 'audio/wav',
        fileName: 'recording.wav',
        transcriptionModelId: 'parakeet-tdt-0.6b-v3',
      });
    });
  });

  describe('transcribe.listModels', () => {
    it('should list transcription models', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'transcribe.listModels',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(mockListModels).toHaveBeenCalled();
      const result = response.result as { models: any[] };
      expect(result.models).toHaveLength(1);
      expect(result.models[0].id).toBe('parakeet-tdt-0.6b-v3');
    });

    it('should return NOT_AVAILABLE when transcription not available', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'transcribe.listModels',
      };

      const response = await registry.dispatch(request, mockContextWithoutTranscription);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });

    it('should handle list models failure', async () => {
      mockListModels.mockRejectedValueOnce(new Error('Service unavailable'));

      const request: RpcRequest = {
        id: '1',
        method: 'transcribe.listModels',
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('TRANSCRIPTION_ERROR');
      expect(response.error?.message).toBe('Service unavailable');
    });
  });

  describe('createTranscribeHandlers', () => {
    it('should create handlers for registration', () => {
      const handlers = createTranscribeHandlers();

      expect(handlers).toHaveLength(2);
      expect(handlers.map(h => h.method)).toContain('transcribe.audio');
      expect(handlers.map(h => h.method)).toContain('transcribe.listModels');
    });

    it('should have correct options for transcribe.audio', () => {
      const handlers = createTranscribeHandlers();
      const audioHandler = handlers.find(h => h.method === 'transcribe.audio');

      expect(audioHandler?.options?.requiredParams).toContain('audioBase64');
      expect(audioHandler?.options?.requiredManagers).toContain('transcriptionManager');
    });

    it('should have transcriptionManager as required for listModels', () => {
      const handlers = createTranscribeHandlers();
      const listHandler = handlers.find(h => h.method === 'transcribe.listModels');

      expect(listHandler?.options?.requiredManagers).toContain('transcriptionManager');
    });
  });
});
