/**
 * @fileoverview Tests for Voice Notes RPC Handlers
 *
 * Tests voiceNotes.save, voiceNotes.list, voiceNotes.delete handlers
 * using the registry dispatch pattern.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs/promises';
import * as path from 'path';
import { createVoiceNotesHandlers } from '../voiceNotes.handler.js';
import type { RpcRequest, VoiceNotesSaveResult, VoiceNotesListResult } from '../../types.js';
import type { RpcContext } from '../../handler.js';
import { MethodRegistry } from '../../registry.js';

// Mock fs module
vi.mock('fs/promises');

// Mock getNotesDir
vi.mock('@infrastructure/settings/loader.js', () => ({
  getNotesDir: vi.fn(() => '/mock/notes/dir'),
}));

import { getNotesDir } from '@infrastructure/settings/loader.js';

describe('Voice Notes Handlers', () => {
  let registry: MethodRegistry;
  let mockContext: RpcContext;
  let mockContextWithoutTranscription: RpcContext;

  beforeEach(() => {
    registry = new MethodRegistry();
    registry.registerAll(createVoiceNotesHandlers());

    mockContext = {
      transcriptionManager: {
        transcribeAudio: vi.fn(),
      },
    } as unknown as RpcContext;

    mockContextWithoutTranscription = {} as RpcContext;

    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe('voiceNotes.save', () => {
    it('should return error when audioBase64 is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'voiceNotes.save',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('audioBase64');
    });

    it('should return NOT_AVAILABLE when transcriptionManager is not available', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'voiceNotes.save',
        params: { audioBase64: 'base64data' },
      };

      const response = await registry.dispatch(request, mockContextWithoutTranscription);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('NOT_AVAILABLE');
    });

    it('should save voice note successfully', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'voiceNotes.save',
        params: {
          audioBase64: 'base64audiodata',
          mimeType: 'audio/mp3',
          fileName: 'recording.mp3',
        },
      };

      const transcribeResult = {
        text: 'Hello, this is a test transcription.',
        rawText: 'Hello, this is a test transcription.',
        durationSeconds: 15.5,
        language: 'en',
        model: 'parakeet-tdt-0.6b-v3',
        processingTimeMs: 1500,
        device: 'cpu',
        computeType: 'cpu',
        cleanupMode: 'basic',
      };
      vi.mocked(mockContext.transcriptionManager!.transcribeAudio).mockResolvedValue(transcribeResult);
      vi.mocked(fs.mkdir).mockResolvedValue(undefined);
      vi.mocked(fs.writeFile).mockResolvedValue(undefined);

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toMatchObject({
        success: true,
        transcription: {
          text: 'Hello, this is a test transcription.',
          durationSeconds: 15.5,
          language: 'en',
        },
      });
      const result = response.result as VoiceNotesSaveResult;
      expect(result.filename).toMatch(/^\d{4}-\d{2}-\d{2}-\d{6}-voice-note\.md$/);
      expect(fs.mkdir).toHaveBeenCalledWith('/mock/notes/dir', { recursive: true });
      expect(fs.writeFile).toHaveBeenCalled();
    });

    it('should handle transcription errors', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'voiceNotes.save',
        params: { audioBase64: 'base64data' },
      };

      vi.mocked(mockContext.transcriptionManager!.transcribeAudio).mockRejectedValue(
        new Error('Transcription service unavailable')
      );

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('VOICE_NOTE_SAVE_FAILED');
      expect(response.error?.message).toBe('Transcription service unavailable');
    });
  });

  describe('voiceNotes.list', () => {
    it('should return empty list when notes directory does not exist', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'voiceNotes.list',
        params: {},
      };

      vi.mocked(fs.access).mockRejectedValue(new Error('ENOENT'));

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual({
        notes: [],
        totalCount: 0,
        hasMore: false,
      });
    });

    it('should list voice notes with pagination', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'voiceNotes.list',
        params: { limit: 2, offset: 0 },
      };

      const mockFiles = [
        '2025-01-15-120000-voice-note.md',
        '2025-01-14-100000-voice-note.md',
        '2025-01-13-080000-voice-note.md',
      ];

      const mockContent = `---
type: voice-note
created: 2025-01-15T12:00:00.000Z
duration: 30
language: en
model: parakeet-tdt-0.6b-v3
---

# Voice Note - January 15, 2025 at 12:00 PM

This is a test transcription.
`;

      vi.mocked(fs.access).mockResolvedValue(undefined);
      vi.mocked(fs.readdir).mockResolvedValue(mockFiles as any);
      vi.mocked(fs.readFile).mockResolvedValue(mockContent);

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as VoiceNotesListResult;
      expect(result.notes).toHaveLength(2);
      expect(result.totalCount).toBe(3);
      expect(result.hasMore).toBe(true);
    });

    it('should parse voice note metadata correctly', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'voiceNotes.list',
        params: { limit: 1 },
      };

      const mockContent = `---
type: voice-note
created: 2025-01-15T12:00:00.000Z
duration: 45.5
language: es
model: parakeet-tdt-0.6b-v3
---

# Voice Note - January 15, 2025 at 12:00 PM

Hola, esto es una prueba.
`;

      vi.mocked(fs.access).mockResolvedValue(undefined);
      vi.mocked(fs.readdir).mockResolvedValue(['2025-01-15-120000-voice-note.md'] as any);
      vi.mocked(fs.readFile).mockResolvedValue(mockContent);

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as VoiceNotesListResult;
      const note = result.notes[0];
      expect(note.createdAt).toBe('2025-01-15T12:00:00.000Z');
      expect(note.durationSeconds).toBe(45.5);
      expect(note.language).toBe('es');
      expect(note.transcript).toBe('Hola, esto es una prueba.');
      expect(note.preview).toBe('Hola, esto es una prueba.');
    });

    it('should handle read errors gracefully', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'voiceNotes.list',
        params: {},
      };

      vi.mocked(fs.access).mockResolvedValue(undefined);
      vi.mocked(fs.readdir).mockRejectedValue(new Error('Permission denied'));

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('VOICE_NOTES_LIST_FAILED');
    });

    it('should skip files that cannot be read', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'voiceNotes.list',
        params: {},
      };

      vi.mocked(fs.access).mockResolvedValue(undefined);
      vi.mocked(fs.readdir).mockResolvedValue(['file1.md', 'file2.md'] as any);
      vi.mocked(fs.readFile)
        .mockRejectedValueOnce(new Error('Cannot read'))
        .mockResolvedValueOnce(`---
created: 2025-01-15
---

Content`);

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      const result = response.result as VoiceNotesListResult;
      expect(result.notes).toHaveLength(1);
    });
  });

  describe('voiceNotes.delete', () => {
    it('should return error when filename is missing', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'voiceNotes.delete',
        params: {},
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toContain('filename');
    });

    it('should reject directory traversal attempts', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'voiceNotes.delete',
        params: { filename: '../../../etc/passwd' },
      };

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('INVALID_PARAMS');
      expect(response.error?.message).toBe('Invalid filename');
    });

    it('should return NOT_FOUND when file does not exist', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'voiceNotes.delete',
        params: { filename: 'nonexistent.md' },
      };

      vi.mocked(fs.access).mockRejectedValue(new Error('ENOENT'));

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('FILE_NOT_FOUND');
      expect(response.error?.message).toContain('Voice note not found');
    });

    it('should delete voice note successfully', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'voiceNotes.delete',
        params: { filename: '2025-01-15-120000-voice-note.md' },
      };

      vi.mocked(fs.access).mockResolvedValue(undefined);
      vi.mocked(fs.unlink).mockResolvedValue(undefined);

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(true);
      expect(response.result).toEqual({
        success: true,
        filename: '2025-01-15-120000-voice-note.md',
      });
      expect(fs.unlink).toHaveBeenCalledWith('/mock/notes/dir/2025-01-15-120000-voice-note.md');
    });

    it('should handle delete errors', async () => {
      const request: RpcRequest = {
        id: '1',
        method: 'voiceNotes.delete',
        params: { filename: 'test.md' },
      };

      vi.mocked(fs.access).mockResolvedValue(undefined);
      vi.mocked(fs.unlink).mockRejectedValue(new Error('Permission denied'));

      const response = await registry.dispatch(request, mockContext);

      expect(response.success).toBe(false);
      expect(response.error?.code).toBe('VOICE_NOTE_DELETE_FAILED');
    });
  });

  describe('createVoiceNotesHandlers', () => {
    it('should create handler registrations', () => {
      const registrations = createVoiceNotesHandlers();

      expect(registrations).toHaveLength(3);

      const methods = registrations.map(r => r.method);
      expect(methods).toContain('voiceNotes.save');
      expect(methods).toContain('voiceNotes.list');
      expect(methods).toContain('voiceNotes.delete');

      // Check save handler options
      const saveHandler = registrations.find(r => r.method === 'voiceNotes.save');
      expect(saveHandler?.options?.requiredParams).toContain('audioBase64');
      expect(saveHandler?.options?.requiredManagers).toContain('transcriptionManager');

      // Check delete handler options
      const deleteHandler = registrations.find(r => r.method === 'voiceNotes.delete');
      expect(deleteHandler?.options?.requiredParams).toContain('filename');
    });
  });
});
