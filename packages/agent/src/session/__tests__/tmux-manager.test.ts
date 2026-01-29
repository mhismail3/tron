/**
 * @fileoverview Tests for TmuxManager
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { TmuxManager, type TmuxManagerConfig } from '../tmux-manager.js';

describe('TmuxManager', () => {
  let manager: TmuxManager;

  beforeEach(() => {
    vi.clearAllMocks();
    manager = new TmuxManager({ prefix: 'test-agent' });
  });

  describe('Configuration', () => {
    it('should accept custom prefix', () => {
      const customManager = new TmuxManager({ prefix: 'custom' });
      expect(customManager).toBeDefined();
    });

    it('should use default prefix if not provided', () => {
      const defaultManager = new TmuxManager({});
      expect(defaultManager).toBeDefined();
    });

    it('should accept socket path configuration', () => {
      const socketManager = new TmuxManager({
        prefix: 'test',
        socketPath: '/tmp/custom-tmux.sock',
      });
      expect(socketManager).toBeDefined();
    });

    it('should accept environment variables', () => {
      const envManager = new TmuxManager({
        prefix: 'test',
        env: { MY_VAR: 'value' },
      });
      expect(envManager).toBeDefined();
    });
  });

  describe('Session Management', () => {
    it('should define spawn method', () => {
      expect(typeof manager.spawn).toBe('function');
    });

    it('should define list method', () => {
      expect(typeof manager.list).toBe('function');
    });

    it('should define kill method', () => {
      expect(typeof manager.kill).toBe('function');
    });

    it('should define exists method', () => {
      expect(typeof manager.exists).toBe('function');
    });

    it('should define attach method', () => {
      expect(typeof manager.attach).toBe('function');
    });

    it('should define detach method', () => {
      expect(typeof manager.detach).toBe('function');
    });
  });

  describe('Window and Pane Management', () => {
    it('should define listWindows method', () => {
      expect(typeof manager.listWindows).toBe('function');
    });

    it('should define listPanes method', () => {
      expect(typeof manager.listPanes).toBe('function');
    });

    it('should define selectWindow method', () => {
      expect(typeof manager.selectWindow).toBe('function');
    });

    it('should define selectPane method', () => {
      expect(typeof manager.selectPane).toBe('function');
    });
  });

  describe('Pane Operations', () => {
    it('should define capturePane method', () => {
      expect(typeof manager.capturePane).toBe('function');
    });

    it('should define sendKeys method', () => {
      expect(typeof manager.sendKeys).toBe('function');
    });

    it('should define sendCommand method', () => {
      expect(typeof manager.sendCommand).toBe('function');
    });
  });

  describe('Availability Check', () => {
    it('should define isAvailable method', () => {
      expect(typeof manager.isAvailable).toBe('function');
    });

    it('should define isServerRunning method', () => {
      expect(typeof manager.isServerRunning).toBe('function');
    });
  });

  describe('Utility Methods', () => {
    it('should define renameSession method', () => {
      expect(typeof manager.renameSession).toBe('function');
    });

    it('should define killAll method', () => {
      expect(typeof manager.killAll).toBe('function');
    });

    it('should define getSession method', () => {
      expect(typeof manager.getSession).toBe('function');
    });
  });
});
