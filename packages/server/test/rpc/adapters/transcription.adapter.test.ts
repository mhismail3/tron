/**
 * @fileoverview Tests for Transcription Adapter
 *
 * The transcription adapter delegates to the transcription client
 * for audio transcription services.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';

// Mock the transcription client module
vi.mock('../../../src/transcription-client.js', () => ({
  transcribeAudio: vi.fn(),
  listTranscriptionModels: vi.fn(),
}));

// Import after mocking
import { transcribeAudio, listTranscriptionModels } from '../../../src/transcription-client.js';
import { createTranscriptionAdapter } from '../../../src/rpc/adapters/transcription.adapter.js';

describe('TranscriptionAdapter', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('transcribeAudio', () => {
    it('should delegate to transcription client', async () => {
      const mockResult = {
        text: 'Hello world',
        segments: [{ start: 0, end: 1, text: 'Hello world' }],
      };
      vi.mocked(transcribeAudio).mockResolvedValue(mockResult);

      const adapter = createTranscriptionAdapter();
      const params = {
        audioData: 'base64-audio-data',
        mimeType: 'audio/wav',
        model: 'parakeet-tdt-0.6b-v3',
      };

      const result = await adapter.transcribeAudio(params);

      expect(transcribeAudio).toHaveBeenCalledWith(params);
      expect(result).toEqual(mockResult);
    });

    it('should propagate errors from transcription client', async () => {
      const error = new Error('Transcription failed');
      vi.mocked(transcribeAudio).mockRejectedValue(error);

      const adapter = createTranscriptionAdapter();

      await expect(adapter.transcribeAudio({
        audioData: 'invalid',
        mimeType: 'audio/wav',
      })).rejects.toThrow('Transcription failed');
    });
  });

  describe('listModels', () => {
    it('should return available transcription models', async () => {
      const mockModels = {
        models: [
          { id: 'parakeet-tdt-0.6b-v3', name: 'Parakeet TDT', provider: 'mlx' },
        ],
      };
      vi.mocked(listTranscriptionModels).mockResolvedValue(mockModels);

      const adapter = createTranscriptionAdapter();
      const result = await adapter.listModels();

      expect(listTranscriptionModels).toHaveBeenCalled();
      expect(result).toEqual(mockModels);
    });
  });
});
