/**
 * @fileoverview Clipboard Utility
 *
 * Cross-platform clipboard operations for copy/paste functionality.
 * Supports macOS, Linux (with xclip), and Windows.
 */

import { execSync } from 'child_process';

interface ClipboardCommand {
  copy: string;
  paste: string;
}

/**
 * Get the clipboard commands for the current platform
 */
export function getClipboardCommand(
  platform: NodeJS.Platform = process.platform
): ClipboardCommand | null {
  switch (platform) {
    case 'darwin':
      return {
        copy: 'pbcopy',
        paste: 'pbpaste',
      };
    case 'linux':
      return {
        copy: 'xclip -selection clipboard',
        paste: 'xclip -selection clipboard -o',
      };
    case 'win32':
      return {
        copy: 'clip',
        paste: 'powershell -command "Get-Clipboard"',
      };
    default:
      return null;
  }
}

/**
 * Check if clipboard commands are available on this system
 */
export function isClipboardAvailable(): boolean {
  const cmd = getClipboardCommand();
  if (!cmd) return false;

  try {
    // Try to run the paste command to check availability
    execSync(`which ${cmd.paste.split(' ')[0]} 2>/dev/null || where ${cmd.paste.split(' ')[0]} 2>nul`, {
      encoding: 'utf8',
      stdio: 'pipe',
    });
    return true;
  } catch {
    return false;
  }
}

/**
 * Copy text to the system clipboard
 */
export async function copyToClipboard(text: string): Promise<void> {
  const cmd = getClipboardCommand();
  if (!cmd) {
    throw new Error(`Clipboard not supported on platform: ${process.platform}`);
  }

  try {
    execSync(cmd.copy, {
      input: text,
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
    });
  } catch (error) {
    throw new Error(
      `Failed to copy to clipboard: ${error instanceof Error ? error.message : String(error)}`
    );
  }
}

/**
 * Read text from the system clipboard
 */
export async function readFromClipboard(): Promise<string> {
  const cmd = getClipboardCommand();
  if (!cmd) {
    throw new Error(`Clipboard not supported on platform: ${process.platform}`);
  }

  try {
    const result = execSync(cmd.paste, {
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    // Handle both string and Buffer results
    const text = typeof result === 'string' ? result : result.toString('utf8');
    return text.trim();
  } catch (error) {
    throw new Error(
      `Failed to read from clipboard: ${error instanceof Error ? error.message : String(error)}`
    );
  }
}
