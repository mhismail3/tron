/**
 * @fileoverview Transcription Sidecar Client
 *
 * Sends audio to the local transcription sidecar and returns the result.
 */
import { createLogger, getSettings } from './index.js';
import type {
  TranscribeAudioParams,
  TranscribeAudioResult,
  TranscribeListModelsResult,
  TranscriptionModelInfo,
} from './index.js';

const logger = createLogger('transcription');

type TranscriptionModelProfile = TranscriptionModelInfo & {
  backend: string;
  modelName: string;
  device: string;
  computeType: string;
  endpoint: string;
};

const TRANSCRIPTION_MODELS: TranscriptionModelProfile[] = [
  {
    id: 'parakeet-tdt-0.6b-v3',
    label: 'Parakeet TDT 0.6B v3',
    description: 'Fast transcription on Apple Silicon',
    backend: 'parakeet-mlx',
    modelName: 'mlx-community/parakeet-tdt-0.6b-v3',
    device: 'mlx',
    computeType: 'mlx',
    endpoint: '/transcribe/faster',
  },
];

const DEFAULT_TRANSCRIPTION_MODEL_ID = TRANSCRIPTION_MODELS[0]?.id;

function normalizeBase64(input: string): string {
  const trimmed = input.trim();
  const commaIndex = trimmed.indexOf(',');
  if (commaIndex >= 0) {
    return trimmed.slice(commaIndex + 1);
  }
  return trimmed;
}

function normalizeCleanupMode(mode: TranscribeAudioParams['cleanupMode'], fallback: string): string | undefined {
  if (mode === 'none' || mode === 'basic' || mode === 'llm') {
    return mode;
  }
  if (fallback === 'none' || fallback === 'basic' || fallback === 'llm') {
    return fallback;
  }
  return undefined;
}

export async function transcribeAudio(params: TranscribeAudioParams): Promise<TranscribeAudioResult> {
  const settings = getSettings().server.transcription;

  if (!settings.enabled) {
    throw new Error('Transcription is disabled');
  }

  const base64 = normalizeBase64(params.audioBase64);
  const audioBuffer = Buffer.from(base64, 'base64');
  if (!audioBuffer.length) {
    throw new Error('Audio payload is empty');
  }
  if (audioBuffer.length > settings.maxBytes) {
    throw new Error(`Audio payload exceeds ${settings.maxBytes} bytes`);
  }

  const cleanupMode = normalizeCleanupMode(params.cleanupMode, settings.cleanupMode);
  const mimeType = params.mimeType ?? 'audio/m4a';
  const fileName = params.fileName ?? 'audio.m4a';
  const profile =
    getProfileById(params.transcriptionModelId)
    ?? getProfileByQuality(params.transcriptionQuality)
    ?? getDefaultProfile();
  const endpointPath = profile?.endpoint ?? '/transcribe';
  const endpoint = new URL(endpointPath, settings.baseUrl).toString();

  const form = new FormData();
  form.append('audio', new Blob([audioBuffer], { type: mimeType }), fileName);
  if (params.language) {
    form.append('language', params.language);
  }
  if (params.task) {
    form.append('task', params.task);
  }
  if (params.prompt) {
    form.append('prompt', params.prompt);
  }
  if (cleanupMode) {
    form.append('cleanup_mode', cleanupMode);
  }
  if (profile) {
    form.append('backend', profile.backend);
    form.append('model_name', profile.modelName);
    form.append('device', profile.device);
    form.append('compute_type', profile.computeType);
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), settings.timeoutMs);

  try {
    const response = await fetch(endpoint, {
      method: 'POST',
      body: form,
      signal: controller.signal,
    });

    if (!response.ok) {
      const detail = await response.text();
      throw new Error(`Sidecar error (${response.status}): ${detail || 'unknown error'}`);
    }

    const data = await response.json() as Record<string, unknown>;

    return {
      text: String(data.text ?? ''),
      rawText: String(data.raw_text ?? data.rawText ?? ''),
      language: String(data.language ?? ''),
      durationSeconds: Number(data.duration_s ?? data.durationSeconds ?? 0),
      processingTimeMs: Number(data.processing_time_ms ?? data.processingTimeMs ?? 0),
      model: String(data.model ?? ''),
      device: String(data.device ?? ''),
      computeType: String(data.compute_type ?? data.computeType ?? ''),
      cleanupMode: String(data.cleanup_mode ?? cleanupMode ?? ''),
    };
  } catch (error) {
    if (error instanceof Error && error.name === 'AbortError') {
      throw new Error('Transcription request timed out');
    }
    logger.error('Transcription failed', error instanceof Error ? error : new Error(String(error)));
    throw error instanceof Error ? error : new Error(String(error));
  } finally {
    clearTimeout(timeout);
  }
}

export async function listTranscriptionModels(): Promise<TranscribeListModelsResult> {
  return {
    models: TRANSCRIPTION_MODELS.map(({ id, label, description }) => ({
      id,
      label,
      description,
    })),
    defaultModelId: DEFAULT_TRANSCRIPTION_MODEL_ID,
  };
}

function getProfileById(id?: string): TranscriptionModelProfile | null {
  if (!id) {
    return null;
  }
  return TRANSCRIPTION_MODELS.find((model) => model.id === id) ?? null;
}

function getProfileByQuality(
  quality: TranscribeAudioParams['transcriptionQuality'],
): TranscriptionModelProfile | null {
  // All quality levels now use parakeet (the only supported model)
  if (quality === 'faster' || quality === 'better') {
    return getProfileById('parakeet-tdt-0.6b-v3');
  }
  return null;
}

function getDefaultProfile(): TranscriptionModelProfile | null {
  if (!DEFAULT_TRANSCRIPTION_MODEL_ID) {
    return null;
  }
  return getProfileById(DEFAULT_TRANSCRIPTION_MODEL_ID);
}
