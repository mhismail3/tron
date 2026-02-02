/**
 * Tests for transcription sidecar management.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Mock dependencies before imports
vi.mock('../../settings/index.js', () => ({
  getSettings: vi.fn(() => ({
    server: {
      transcription: {
        enabled: true,
        manageSidecar: true,
        baseUrl: 'http://localhost:8787',
      },
    },
  })),
}));

vi.mock('../../logging/index.js', () => ({
  createLogger: vi.fn(() => ({
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
    debug: vi.fn(),
  })),
  categorizeError: vi.fn((e) => ({ code: 'UNKNOWN', message: e.message, retryable: false })),
  LogErrorCategory: { NETWORK: 'network' },
}));

// Reset modules between tests to get fresh state
beforeEach(() => {
  vi.resetModules();
  vi.clearAllMocks();
});

describe('isSidecarHealthy', () => {
  it('returns true when /health returns 200', async () => {
    const mockFetch = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal('fetch', mockFetch);

    const { isSidecarHealthy } = await import('../sidecar.js');
    const result = await isSidecarHealthy('http://localhost:8787');

    expect(result).toBe(true);
    expect(mockFetch).toHaveBeenCalledWith(
      'http://localhost:8787/health',
      expect.objectContaining({ signal: expect.any(AbortSignal) })
    );
  });

  it('returns false when /health returns non-200', async () => {
    const mockFetch = vi.fn().mockResolvedValue({ ok: false, status: 503 });
    vi.stubGlobal('fetch', mockFetch);

    const { isSidecarHealthy } = await import('../sidecar.js');
    const result = await isSidecarHealthy('http://localhost:8787');

    expect(result).toBe(false);
  });

  it('returns false on network error', async () => {
    const mockFetch = vi.fn().mockRejectedValue(new Error('ECONNREFUSED'));
    vi.stubGlobal('fetch', mockFetch);

    const { isSidecarHealthy } = await import('../sidecar.js');
    const result = await isSidecarHealthy('http://localhost:8787');

    expect(result).toBe(false);
  });

  it('returns false on timeout (AbortError)', async () => {
    const mockFetch = vi.fn().mockRejectedValue(new DOMException('Aborted', 'AbortError'));
    vi.stubGlobal('fetch', mockFetch);

    const { isSidecarHealthy } = await import('../sidecar.js');
    const result = await isSidecarHealthy('http://localhost:8787');

    expect(result).toBe(false);
  });
});

describe('isSidecarReady', () => {
  it('returns true when /ready returns 200', async () => {
    const mockFetch = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal('fetch', mockFetch);

    const { isSidecarReady } = await import('../sidecar.js');
    const result = await isSidecarReady('http://localhost:8787');

    expect(result).toBe(true);
    expect(mockFetch).toHaveBeenCalledWith(
      'http://localhost:8787/ready',
      expect.any(Object)
    );
  });

  it('returns false when /ready returns 503', async () => {
    const mockFetch = vi.fn().mockResolvedValue({ ok: false, status: 503 });
    vi.stubGlobal('fetch', mockFetch);

    const { isSidecarReady } = await import('../sidecar.js');
    const result = await isSidecarReady('http://localhost:8787');

    expect(result).toBe(false);
  });

  it('returns false on network error', async () => {
    const mockFetch = vi.fn().mockRejectedValue(new Error('Connection refused'));
    vi.stubGlobal('fetch', mockFetch);

    const { isSidecarReady } = await import('../sidecar.js');
    const result = await isSidecarReady('http://localhost:8787');

    expect(result).toBe(false);
  });
});

describe('waitForReady', () => {
  // Disable the 30s initial delay for tests
  beforeEach(async () => {
    const { _setReadinessInitialDelay } = await import('../sidecar.js');
    _setReadinessInitialDelay(0);
  });

  afterEach(async () => {
    const { _resetReadinessInitialDelay } = await import('../sidecar.js');
    _resetReadinessInitialDelay();
  });

  it('returns true immediately if already ready', async () => {
    const mockFetch = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal('fetch', mockFetch);

    const { waitForReady } = await import('../sidecar.js');
    const result = await waitForReady('http://localhost:8787', 5000);

    expect(result).toBe(true);
    // Should have called ready endpoint at least once
    expect(mockFetch).toHaveBeenCalled();
  });

  it('polls until ready', async () => {
    let callCount = 0;
    const mockFetch = vi.fn().mockImplementation(() => {
      callCount++;
      return Promise.resolve({ ok: callCount >= 3 });
    });
    vi.stubGlobal('fetch', mockFetch);

    const { waitForReady } = await import('../sidecar.js');
    const result = await waitForReady('http://localhost:8787', 10000);

    expect(result).toBe(true);
    expect(callCount).toBeGreaterThanOrEqual(3);
  });

  it('returns false on timeout', async () => {
    const mockFetch = vi.fn().mockResolvedValue({ ok: false });
    vi.stubGlobal('fetch', mockFetch);

    const { waitForReady } = await import('../sidecar.js');
    const start = Date.now();
    const result = await waitForReady('http://localhost:8787', 500);
    const elapsed = Date.now() - start;

    expect(result).toBe(false);
    expect(elapsed).toBeGreaterThanOrEqual(400); // Allow some tolerance
  });
});

describe('SidecarWatchdog', () => {
  let watchdog: InstanceType<typeof import('../sidecar.js').SidecarWatchdog>;

  beforeEach(async () => {
    vi.useFakeTimers();
    // Set sidecarOwned to true so watchdog actually runs health checks
    const { _setSidecarOwned } = await import('../sidecar.js');
    _setSidecarOwned(true);
  });

  afterEach(async () => {
    watchdog?.stop();
    // Reset sidecarOwned
    const { _setSidecarOwned } = await import('../sidecar.js');
    _setSidecarOwned(false);
    vi.useRealTimers();
  });

  it('can be instantiated', async () => {
    const { SidecarWatchdog } = await import('../sidecar.js');
    watchdog = new SidecarWatchdog();
    expect(watchdog).toBeDefined();
    expect(watchdog.isRunning()).toBe(false);
  });

  it('starts and stops correctly', async () => {
    const mockFetch = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal('fetch', mockFetch);

    const { SidecarWatchdog } = await import('../sidecar.js');
    watchdog = new SidecarWatchdog();
    const restartFn = vi.fn().mockResolvedValue(undefined);

    watchdog.start('http://localhost:8787', restartFn);
    expect(watchdog.isRunning()).toBe(true);

    watchdog.stop();
    expect(watchdog.isRunning()).toBe(false);
  });

  it('detects unhealthy sidecar and triggers restart', async () => {
    const mockFetch = vi.fn().mockResolvedValue({ ok: false });
    vi.stubGlobal('fetch', mockFetch);

    const { SidecarWatchdog } = await import('../sidecar.js');
    watchdog = new SidecarWatchdog();
    const restartFn = vi.fn().mockResolvedValue(undefined);

    watchdog.start('http://localhost:8787', restartFn);

    // Advance past first health check interval (30s)
    await vi.advanceTimersByTimeAsync(35000);

    expect(restartFn).toHaveBeenCalled();
  });

  it('does not restart when healthy', async () => {
    const mockFetch = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal('fetch', mockFetch);

    const { SidecarWatchdog } = await import('../sidecar.js');
    watchdog = new SidecarWatchdog();
    const restartFn = vi.fn().mockResolvedValue(undefined);

    watchdog.start('http://localhost:8787', restartFn);

    // Advance through multiple health check intervals
    await vi.advanceTimersByTimeAsync(120000);

    expect(restartFn).not.toHaveBeenCalled();
  });

  it('stops after max restart attempts', async () => {
    const mockFetch = vi.fn().mockResolvedValue({ ok: false });
    vi.stubGlobal('fetch', mockFetch);

    const { SidecarWatchdog, MAX_RESTART_ATTEMPTS } = await import('../sidecar.js');
    watchdog = new SidecarWatchdog();
    const restartFn = vi.fn().mockResolvedValue(undefined);

    watchdog.start('http://localhost:8787', restartFn);

    // Run for a long time to exhaust restart attempts
    await vi.advanceTimersByTimeAsync(600000);

    // Should have stopped after max attempts
    expect(restartFn.mock.calls.length).toBeLessThanOrEqual(MAX_RESTART_ATTEMPTS);
  });

  it('resets restart counter after successful health check', async () => {
    let healthy = false;
    const mockFetch = vi.fn().mockImplementation(() => Promise.resolve({ ok: healthy }));
    vi.stubGlobal('fetch', mockFetch);

    const { SidecarWatchdog } = await import('../sidecar.js');
    watchdog = new SidecarWatchdog();
    const restartFn = vi.fn().mockResolvedValue(undefined);

    watchdog.start('http://localhost:8787', restartFn);

    // Fail a few times
    await vi.advanceTimersByTimeAsync(100000);
    const failCount = restartFn.mock.calls.length;
    expect(failCount).toBeGreaterThan(0);

    // Now become healthy
    healthy = true;
    await vi.advanceTimersByTimeAsync(60000);

    // Fail again
    healthy = false;
    restartFn.mockClear();
    await vi.advanceTimersByTimeAsync(100000);

    // Should restart again (counter was reset)
    expect(restartFn).toHaveBeenCalled();
  });

  it('does not start twice if already running', async () => {
    const mockFetch = vi.fn().mockResolvedValue({ ok: true });
    vi.stubGlobal('fetch', mockFetch);

    const { SidecarWatchdog } = await import('../sidecar.js');
    watchdog = new SidecarWatchdog();
    const restartFn = vi.fn().mockResolvedValue(undefined);

    watchdog.start('http://localhost:8787', restartFn);
    watchdog.start('http://localhost:8787', restartFn); // Second call should be no-op

    expect(watchdog.isRunning()).toBe(true);
  });
});

describe('parseSidecarLog', () => {
  it('parses valid JSON log from sidecar', async () => {
    const { parseSidecarLog } = await import('../sidecar.js');
    const log = JSON.stringify({
      timestamp: '2024-01-01T00:00:00Z',
      level: 'info',
      component: 'transcription-sidecar',
      message: 'Test message',
      data: { key: 'value' },
    });

    const result = parseSidecarLog(log);

    expect(result).not.toBeNull();
    expect(result!.message).toBe('Test message');
    expect(result!.data).toEqual({ key: 'value' });
  });

  it('returns null for non-JSON input', async () => {
    const { parseSidecarLog } = await import('../sidecar.js');
    const result = parseSidecarLog('plain text log line');

    expect(result).toBeNull();
  });

  it('returns null for JSON without component field', async () => {
    const { parseSidecarLog } = await import('../sidecar.js');
    const log = JSON.stringify({
      level: 'info',
      message: 'Test',
    });

    const result = parseSidecarLog(log);

    expect(result).toBeNull();
  });

  it('returns null for wrong component', async () => {
    const { parseSidecarLog } = await import('../sidecar.js');
    const log = JSON.stringify({
      component: 'other-component',
      message: 'Test',
    });

    const result = parseSidecarLog(log);

    expect(result).toBeNull();
  });

  it('handles log with error info', async () => {
    const { parseSidecarLog } = await import('../sidecar.js');
    const log = JSON.stringify({
      timestamp: '2024-01-01T00:00:00Z',
      level: 'error',
      component: 'transcription-sidecar',
      message: 'Something failed',
      error: {
        type: 'RuntimeError',
        message: 'Model load failed',
        stack: 'Traceback...',
      },
    });

    const result = parseSidecarLog(log);

    expect(result).not.toBeNull();
    expect(result!.level).toBe('error');
    expect(result!.error).toBeDefined();
    expect(result!.error!.type).toBe('RuntimeError');
  });
});
