/**
 * @fileoverview End-to-End Integration Tests
 *
 * Tests complete workflows from user prompt to agent response,
 * including tool execution, memory operations, and session management.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { SessionManager } from '../../src/session/manager.js';
import { LedgerManager } from '../../src/memory/ledger-manager.js';
import { HookEngine } from '../../src/hooks/engine.js';
import { SkillLoader } from '../../src/skills/loader.js';
import { CommandRouter } from '../../src/commands/router.js';
import { ReadTool } from '../../src/tools/read.js';
import { WriteTool } from '../../src/tools/write.js';
import { EditTool } from '../../src/tools/edit.js';
import { BashTool } from '../../src/tools/bash.js';
import { HandoffManager } from '../../src/memory/handoff-manager.js';
import { ContextLoader } from '../../src/context/loader.js';
import type { AssistantMessage } from '../../src/types/index.js';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';

describe('End-to-End Workflows', () => {
  let tempDir: string;
  let sessionDir: string;
  let skillsDir: string;

  beforeEach(async () => {
    // Create temp directories
    tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'tron-e2e-'));
    sessionDir = path.join(tempDir, 'sessions');
    skillsDir = path.join(tempDir, 'skills');
    await fs.mkdir(sessionDir, { recursive: true });
    await fs.mkdir(skillsDir, { recursive: true });
  });

  afterEach(async () => {
    // Cleanup temp directories
    await fs.rm(tempDir, { recursive: true, force: true });
  });

  describe('Session Lifecycle', () => {
    it('should create, persist, and resume a session', async () => {
      const sessionManager = new SessionManager({
        sessionsDir: sessionDir,
        defaultModel: 'claude-sonnet-4-20250514',
        defaultProvider: 'anthropic',
      });

      // Create session
      const session = await sessionManager.createSession({
        workingDirectory: tempDir,
      });

      expect(session.id).toBeDefined();
      expect(session.messages).toEqual([]);

      // Add messages
      await sessionManager.addMessage(session.id, {
        role: 'user',
        content: 'Hello, test message',
      });

      await sessionManager.addMessage(session.id, {
        role: 'assistant',
        content: [{ type: 'text', text: 'Hello! How can I help?' }],
      } as AssistantMessage);

      // List sessions
      const sessions = await sessionManager.listSessions({
        workingDirectory: tempDir,
        includeEnded: true,
      });
      expect(sessions.length).toBe(1);
      expect(sessions[0].id).toBe(session.id);

      // Get session to verify messages were saved
      const resumed = await sessionManager.getSession(session.id);
      expect(resumed).not.toBeNull();
      expect(resumed!.messages.length).toBe(2);
      expect(resumed!.messages[0].role).toBe('user');
      expect(resumed!.messages[1].role).toBe('assistant');
    });

    it('should fork a session with full history', async () => {
      const sessionManager = new SessionManager({
        sessionsDir: sessionDir,
        defaultModel: 'claude-sonnet-4-20250514',
        defaultProvider: 'anthropic',
      });

      // Create and populate session
      const original = await sessionManager.createSession({
        workingDirectory: tempDir,
      });

      await sessionManager.addMessage(original.id, { role: 'user', content: 'Message 1' });
      await sessionManager.addMessage(original.id, {
        role: 'assistant',
        content: [{ type: 'text', text: 'Response 1' }],
      } as AssistantMessage);
      await sessionManager.addMessage(original.id, { role: 'user', content: 'Message 2' });

      // Fork session
      const forkResult = await sessionManager.forkSession({ sessionId: original.id });

      expect(forkResult.newSessionId).not.toBe(original.id);
      expect(forkResult.messageCount).toBe(3);
      expect(forkResult.forkedFrom).toBe(original.id);

      // Verify forked session has the messages
      const forked = await sessionManager.getSession(forkResult.newSessionId);
      expect(forked).not.toBeNull();
      expect(forked!.messages.length).toBe(3);
      expect(forked!.metadata.parentSessionId).toBe(original.id);
    });
  });

  describe('Ledger Integration', () => {
    it('should persist ledger state across operations', async () => {
      const ledgerDir = path.join(tempDir, 'ledger');
      await fs.mkdir(ledgerDir, { recursive: true });
      const ledgerManager = new LedgerManager({
        ledgerDir,
        baseName: 'test',
      });

      // Create initial ledger
      await ledgerManager.save({
        goal: 'Complete integration tests',
        constraints: ['Use TDD', 'Cover edge cases'],
        done: [],
        now: 'Writing tests',
        next: ['Add more tests', 'Fix bugs'],
        decisions: [
          { choice: 'Use vitest', reason: 'Fast and TypeScript native' },
        ],
        workingFiles: ['test/e2e/full-workflow.test.ts'],
      });

      // Load and verify
      const loaded = await ledgerManager.load();
      expect(loaded.goal).toBe('Complete integration tests');
      expect(loaded.constraints).toContain('Use TDD');
      expect(loaded.now).toBe('Writing tests');

      // Update partially
      await ledgerManager.update({
        done: ['Setup project structure'],
        now: 'Implementing features',
      });

      // Verify update preserved other fields
      const updated = await ledgerManager.load();
      expect(updated.goal).toBe('Complete integration tests'); // Unchanged
      expect(updated.done).toContain('Setup project structure');
      expect(updated.now).toBe('Implementing features');
    });
  });

  describe('Hook Execution', () => {
    it('should execute hooks in correct order', async () => {
      const hookEngine = new HookEngine();
      const executionOrder: string[] = [];

      // Register hooks with different priorities (higher runs first)
      hookEngine.register({
        name: 'hook-priority-10',
        type: 'PreToolUse',
        priority: 10,
        handler: async () => {
          executionOrder.push('hook-priority-10');
          return { action: 'continue' as const };
        },
      });

      hookEngine.register({
        name: 'hook-priority-1',
        type: 'PreToolUse',
        priority: 1,
        handler: async () => {
          executionOrder.push('hook-priority-1');
          return { action: 'continue' as const };
        },
      });

      hookEngine.register({
        name: 'hook-priority-5',
        type: 'PreToolUse',
        priority: 5,
        handler: async () => {
          executionOrder.push('hook-priority-5');
          return { action: 'continue' as const };
        },
      });

      // Execute hooks
      await hookEngine.execute('PreToolUse', {
        toolName: 'read',
        toolCallId: 'test-123',
        arguments: { path: 'test.txt' },
      });

      // Higher priority numbers execute first in this implementation
      expect(executionOrder).toEqual([
        'hook-priority-10',
        'hook-priority-5',
        'hook-priority-1',
      ]);
    });

    it('should block tool execution when hook returns block', async () => {
      const hookEngine = new HookEngine();

      hookEngine.register({
        name: 'security-hook',
        type: 'PreToolUse',
        handler: async (input) => {
          const args = input as { arguments?: { path?: string } };
          if (args.arguments?.path?.includes('secret')) {
            return {
              action: 'block' as const,
              reason: 'Access to secret files is blocked',
            };
          }
          return { action: 'continue' as const };
        },
      });

      // Should allow normal files
      const allowedResult = await hookEngine.execute('PreToolUse', {
        toolName: 'read',
        toolCallId: 'test-1',
        arguments: { path: 'normal.txt' },
      });
      expect(allowedResult.action).toBe('continue');

      // Should block secret files
      const blockedResult = await hookEngine.execute('PreToolUse', {
        toolName: 'read',
        toolCallId: 'test-2',
        arguments: { path: 'secret-passwords.txt' },
      });
      expect(blockedResult.action).toBe('block');
      expect(blockedResult.reason).toContain('blocked');
    });
  });

  describe('Skill Loading', () => {
    it('should discover and load skills from directory', async () => {
      // Create skill files
      const commitSkillDir = path.join(skillsDir, 'commit');
      await fs.mkdir(commitSkillDir, { recursive: true });
      await fs.writeFile(
        path.join(commitSkillDir, 'SKILL.md'),
        `---
name: my-commit
description: Create a git commit
arguments:
  - name: message
    description: Commit message
    required: false
---

# Commit Skill

Generate and execute a git commit.
`
      );

      const loader = new SkillLoader({ skillDirs: [skillsDir], includeBuiltIn: false });
      const skills = await loader.discover();

      expect(skills.length).toBe(1);
      expect(skills[0].name).toBe('my-commit');
      expect(skills[0].description).toBe('Create a git commit');
      expect(skills[0].arguments).toHaveLength(1);
    });

    it('should parse skill arguments correctly', async () => {
      const skillDir = path.join(skillsDir, 'deploy');
      await fs.mkdir(skillDir, { recursive: true });
      await fs.writeFile(
        path.join(skillDir, 'SKILL.md'),
        `---
name: deploy
description: Deploy to environment
arguments:
  - name: env
    description: Target environment
    required: true
  - name: version
    description: Version to deploy
    required: false
    default: latest
---

Deploy the application.
`
      );

      const loader = new SkillLoader({ skillDirs: [skillsDir], includeBuiltIn: false });
      const skills = await loader.discover();
      const skill = skills.find(s => s.name === 'deploy');

      expect(skill).toBeDefined();
      expect(skill?.arguments).toHaveLength(2);
      expect(skill?.arguments?.[0].required).toBe(true);
      expect(skill?.arguments?.[1].required).toBe(false);
      expect(skill?.arguments?.[1].default).toBe('latest');
    });
  });

  describe('Command Routing', () => {
    it('should parse slash commands correctly', async () => {
      const router = new CommandRouter();

      // Test command parsing
      const clearResult = router.parse('/clear');
      expect(clearResult.command).toBe('clear');
      expect(clearResult.isCommand).toBe(true);

      const modelResult = router.parse('/model gpt-4o');
      expect(modelResult.command).toBe('model');
      expect(modelResult.rawArgs).toBe('gpt-4o');

      const helpResult = router.parse('/help');
      expect(helpResult.command).toBe('help');
    });

    it('should recognize non-commands', async () => {
      const router = new CommandRouter();

      const result = router.parse('just a regular message');
      expect(result.isCommand).toBe(false);
    });
  });

  describe('Tool Execution', () => {
    // Helper to extract text from tool result content
    const getContentText = (content: string | { type: string; text: string }[]): string => {
      if (typeof content === 'string') return content;
      const textItem = content.find(c => c.type === 'text');
      return textItem ? textItem.text : '';
    };

    it('should execute read tool and return file contents', async () => {
      // Create test file
      const testFile = path.join(tempDir, 'test-read.txt');
      await fs.writeFile(testFile, 'Line 1\nLine 2\nLine 3\n');

      const readTool = new ReadTool({ workingDirectory: tempDir });

      const result = await readTool.execute({ file_path: 'test-read.txt' });

      expect(result.isError).toBeFalsy();
      const text = getContentText(result.content);
      expect(text).toContain('Line 1');
    });

    it('should execute write tool and create file', async () => {
      const writeTool = new WriteTool({ workingDirectory: tempDir });

      const result = await writeTool.execute({
        file_path: 'new-file.txt',
        content: 'Created content',
      });

      expect(result.isError).toBeFalsy();

      // Verify file was created
      const content = await fs.readFile(
        path.join(tempDir, 'new-file.txt'),
        'utf-8'
      );
      expect(content).toBe('Created content');
    });

    it('should execute edit tool with exact match', async () => {
      // Create test file
      const testFile = path.join(tempDir, 'test-edit.txt');
      await fs.writeFile(testFile, 'Hello World\nGoodbye World');

      const editTool = new EditTool({ workingDirectory: tempDir });

      const result = await editTool.execute({
        file_path: 'test-edit.txt',
        old_string: 'Goodbye World',
        new_string: 'Hello Again',
      });

      expect(result.isError).toBeFalsy();

      // Verify edit
      const content = await fs.readFile(testFile, 'utf-8');
      expect(content).toBe('Hello World\nHello Again');
    });

    it('should handle bash tool execution', async () => {
      const bashTool = new BashTool({ workingDirectory: tempDir });

      // Quick command
      const result = await bashTool.execute({ command: 'echo "test output"' });

      expect(result.isError).toBeFalsy();
      const text = getContentText(result.content);
      expect(text).toContain('test output');
    });
  });

  describe('Memory Persistence', () => {
    it('should create and search handoffs', async () => {
      const dbPath = path.join(tempDir, 'handoffs.db');
      const manager = new HandoffManager(dbPath);
      await manager.initialize();

      // Create handoff with timestamp
      const handoffId = await manager.create({
        sessionId: 'test-session-1',
        timestamp: new Date(),
        summary: 'Implemented OAuth authentication flow',
        codeChanges: [
          { file: 'src/auth/oauth.ts', description: 'Added PKCE flow' },
        ],
        currentState: 'OAuth working, need to test refresh',
        blockers: [],
        nextSteps: ['Test token refresh', 'Add error handling'],
        patterns: ['Use 5-minute buffer for token expiry'],
      });

      expect(handoffId).toBeDefined();

      // Search
      const results = await manager.search('OAuth');
      expect(results.length).toBe(1);
      expect(results[0].summary).toContain('OAuth');

      // Get recent
      const recent = await manager.getRecent(5);
      expect(recent.length).toBe(1);
      expect(recent[0].sessionId).toBe('test-session-1');

      await manager.close();
    });
  });

  describe('Error Handling', () => {
    // Helper to extract text from tool result content
    const getContentText = (content: string | { type: string; text: string }[]): string => {
      if (typeof content === 'string') return content;
      const textItem = content.find(c => c.type === 'text');
      return textItem ? textItem.text : '';
    };

    it('should handle missing file gracefully', async () => {
      const readTool = new ReadTool({ workingDirectory: tempDir });

      const result = await readTool.execute({ file_path: 'nonexistent-file.txt' });

      expect(result.isError).toBe(true);
      const text = getContentText(result.content);
      expect(text).toContain('not found');
    });

    it('should handle edit with multiple matches', async () => {
      // Create test file with duplicate content
      const testFile = path.join(tempDir, 'duplicates.txt');
      await fs.writeFile(testFile, 'hello\nhello\nhello');

      const editTool = new EditTool({ workingDirectory: tempDir });

      const result = await editTool.execute({
        file_path: 'duplicates.txt',
        old_string: 'hello',
        new_string: 'hi',
      });

      expect(result.isError).toBe(true);
      const text = getContentText(result.content);
      expect(text).toContain('multiple');
    });

    it('should handle bash command failure', async () => {
      const bashTool = new BashTool({ workingDirectory: tempDir });

      const result = await bashTool.execute({ command: 'exit 1' });

      // Command runs but exits with error code
      expect(result.details?.exitCode).toBe(1);
    });
  });

  describe('Context Management', () => {
    it('should load hierarchical context files', async () => {
      // Create context files
      const globalDir = path.join(tempDir, 'global');
      const projectDir = path.join(tempDir, 'project');
      await fs.mkdir(globalDir, { recursive: true });
      await fs.mkdir(projectDir, { recursive: true });

      // Create global AGENTS.md in agent dir
      const agentDir = path.join(globalDir, '.agent');
      await fs.mkdir(agentDir, { recursive: true });
      await fs.writeFile(
        path.join(agentDir, 'AGENTS.md'),
        '# Global Context\nGlobal rules apply.'
      );

      await fs.writeFile(
        path.join(projectDir, 'AGENTS.md'),
        '# Project Context\nProject-specific rules.'
      );

      const loader = new ContextLoader({
        userHome: globalDir,
        projectRoot: projectDir,
      });

      const context = await loader.load(projectDir);

      // ContextLoader returns LoadedContext with merged and files
      expect(context.merged).toBeDefined();
      expect(context.files.length).toBeGreaterThan(0);
    });
  });
});
