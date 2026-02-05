import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { DEFAULT_SETTINGS } from '../defaults.js';
import { applyEnvOverrides } from '../loader.js';
import {
  parseEnvBoolean,
  parseEnvInteger,
  parseOptionalInteger,
  type EnvParseLogger,
} from '../env-parsing.js';

describe('env parsing', () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = { ...originalEnv };
  });

  afterAll(() => {
    process.env = originalEnv;
  });

  it('parses valid integers with bounds', () => {
    const value = parseEnvInteger('8080', {
      name: 'TRON_WS_PORT',
      fallback: 9000,
      min: 1,
      max: 65535,
    });

    expect(value).toBe(8080);
  });

  it('falls back for invalid integers and logs warning', () => {
    const logger: EnvParseLogger = { warn: vi.fn() };
    const value = parseEnvInteger('abc', {
      name: 'TRON_WS_PORT',
      fallback: 8080,
      min: 1,
      max: 65535,
      logger,
    });

    expect(value).toBe(8080);
    expect(logger.warn).toHaveBeenCalledTimes(1);
  });

  it('parses optional integers and rejects invalid values', () => {
    const logger: EnvParseLogger = { warn: vi.fn() };
    expect(parseOptionalInteger(undefined, { name: 'limit', min: 1, logger })).toBeUndefined();
    expect(parseOptionalInteger('25', { name: 'limit', min: 1, logger })).toBe(25);
    expect(parseOptionalInteger('0', { name: 'limit', min: 1, logger })).toBeUndefined();
  });

  it('parses booleans with fallback for invalid values', () => {
    const logger: EnvParseLogger = { warn: vi.fn() };

    expect(parseEnvBoolean('true', { name: 'TRON_FEATURE', fallback: false, logger })).toBe(true);
    expect(parseEnvBoolean('0', { name: 'TRON_FEATURE', fallback: true, logger })).toBe(false);
    expect(parseEnvBoolean('maybe', { name: 'TRON_FEATURE', fallback: true, logger })).toBe(true);
    expect(logger.warn).toHaveBeenCalledTimes(1);
  });

  it('applyEnvOverrides keeps defaults for malformed numeric env values', () => {
    process.env.TRON_WS_PORT = 'not-a-port';
    process.env.TRON_MAX_SESSIONS = '-5';
    process.env.TRON_HEARTBEAT_INTERVAL = '100';
    process.env.TRON_TRANSCRIBE_TIMEOUT_MS = 'NaN';
    process.env.TRON_TRANSCRIBE_MAX_BYTES = '0';
    process.env.TRON_TRANSCRIBE_ENABLED = 'maybe';

    const overridden = applyEnvOverrides(DEFAULT_SETTINGS);

    expect(overridden.server.wsPort).toBe(DEFAULT_SETTINGS.server.wsPort);
    expect(overridden.server.maxConcurrentSessions).toBe(DEFAULT_SETTINGS.server.maxConcurrentSessions);
    expect(overridden.server.heartbeatIntervalMs).toBe(DEFAULT_SETTINGS.server.heartbeatIntervalMs);
    expect(overridden.server.transcription.timeoutMs).toBe(DEFAULT_SETTINGS.server.transcription.timeoutMs);
    expect(overridden.server.transcription.maxBytes).toBe(DEFAULT_SETTINGS.server.transcription.maxBytes);
    expect(overridden.server.transcription.enabled).toBe(DEFAULT_SETTINGS.server.transcription.enabled);
  });
});
