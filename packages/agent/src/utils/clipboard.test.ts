/**
 * @fileoverview Clipboard Utility Tests
 *
 * Tests for cross-platform clipboard operations.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { execSync } from 'child_process';
import {
  copyToClipboard,
  readFromClipboard,
  getClipboardCommand,
  isClipboardAvailable,
} from '../../src/utils/clipboard.js';

// Mock child_process
vi.mock('child_process', () => ({
  execSync: vi.fn(),
  exec: vi.fn(),
}));

describe('Clipboard Utility', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('getClipboardCommand', () => {
    it('returns pbcopy/pbpaste for darwin', () => {
      const cmd = getClipboardCommand('darwin');
      expect(cmd.copy).toBe('pbcopy');
      expect(cmd.paste).toBe('pbpaste');
    });

    it('returns xclip for linux', () => {
      const cmd = getClipboardCommand('linux');
      expect(cmd.copy).toBe('xclip -selection clipboard');
      expect(cmd.paste).toBe('xclip -selection clipboard -o');
    });

    it('returns clip/powershell for win32', () => {
      const cmd = getClipboardCommand('win32');
      expect(cmd.copy).toBe('clip');
      expect(cmd.paste).toContain('powershell');
    });

    it('returns null for unsupported platforms', () => {
      const cmd = getClipboardCommand('freebsd' as NodeJS.Platform);
      expect(cmd).toBeNull();
    });
  });

  describe('isClipboardAvailable', () => {
    it('returns true when clipboard command exists', () => {
      vi.mocked(execSync).mockReturnValue(Buffer.from(''));
      expect(isClipboardAvailable()).toBe(true);
    });

    it('returns false when clipboard command fails', () => {
      vi.mocked(execSync).mockImplementation(() => {
        throw new Error('Command not found');
      });
      expect(isClipboardAvailable()).toBe(false);
    });
  });

  describe('copyToClipboard', () => {
    it('copies text to clipboard', async () => {
      vi.mocked(execSync).mockReturnValue(Buffer.from(''));

      await copyToClipboard('test text');

      expect(execSync).toHaveBeenCalled();
    });

    it('handles multiline text', async () => {
      vi.mocked(execSync).mockReturnValue(Buffer.from(''));

      await copyToClipboard('line1\nline2\nline3');

      expect(execSync).toHaveBeenCalled();
    });

    it('throws when clipboard unavailable', async () => {
      vi.mocked(execSync).mockImplementation(() => {
        throw new Error('Command not found');
      });

      await expect(copyToClipboard('test')).rejects.toThrow();
    });
  });

  describe('readFromClipboard', () => {
    it('reads text from clipboard', async () => {
      vi.mocked(execSync).mockReturnValue(Buffer.from('clipboard content'));

      const result = await readFromClipboard();

      expect(result).toBe('clipboard content');
    });

    it('returns empty string when clipboard is empty', async () => {
      vi.mocked(execSync).mockReturnValue(Buffer.from(''));

      const result = await readFromClipboard();

      expect(result).toBe('');
    });

    it('trims whitespace from clipboard content', async () => {
      vi.mocked(execSync).mockReturnValue(Buffer.from('  content  \n'));

      const result = await readFromClipboard();

      expect(result).toBe('content');
    });
  });
});
