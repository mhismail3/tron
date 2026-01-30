/**
 * @fileoverview Tests for GuardrailEngine
 */

import { describe, it, expect, beforeEach } from 'vitest';
import * as os from 'os';
import * as path from 'path';
import {
  GuardrailEngine,
  createGuardrailEngine,
  isCoreRule,
} from '../index.js';
import type { EvaluationContext } from '../types.js';

describe('GuardrailEngine', () => {
  let engine: GuardrailEngine;

  beforeEach(() => {
    engine = createGuardrailEngine({ enableAudit: true });
  });

  describe('initialization', () => {
    it('should load default rules', () => {
      const rules = engine.getRules();
      expect(rules.length).toBeGreaterThan(0);

      // Check that core rules are loaded
      expect(engine.getRule('core.destructive-commands')).toBeDefined();
      expect(engine.getRule('core.tron-no-delete')).toBeDefined();
      expect(engine.getRule('core.tron-app-protection')).toBeDefined();
      expect(engine.getRule('core.tron-db-protection')).toBeDefined();
      expect(engine.getRule('core.tron-auth-protection')).toBeDefined();
      expect(engine.getRule('path.traversal')).toBeDefined();
    });

    it('should have audit logger when enabled', () => {
      expect(engine.getAuditLogger()).not.toBeNull();
    });

    it('should not have audit logger when disabled', () => {
      const noAuditEngine = createGuardrailEngine({ enableAudit: false });
      expect(noAuditEngine.getAuditLogger()).toBeNull();
    });
  });

  describe('core rules', () => {
    it('should identify core rules correctly', () => {
      expect(isCoreRule('core.destructive-commands')).toBe(true);
      expect(isCoreRule('core.tron-no-delete')).toBe(true);
      expect(isCoreRule('core.tron-app-protection')).toBe(true);
      expect(isCoreRule('core.tron-db-protection')).toBe(true);
      expect(isCoreRule('core.tron-auth-protection')).toBe(true);
      expect(isCoreRule('bash.sudo')).toBe(false);
    });

    it('should always enable core rules', () => {
      expect(engine.isRuleEnabled('core.destructive-commands')).toBe(true);
      expect(engine.isRuleEnabled('core.tron-no-delete')).toBe(true);
      expect(engine.isRuleEnabled('core.tron-app-protection')).toBe(true);
      expect(engine.isRuleEnabled('core.tron-db-protection')).toBe(true);
      expect(engine.isRuleEnabled('core.tron-auth-protection')).toBe(true);
    });

    it('should not allow unregistering core rules', () => {
      const result = engine.unregisterRule('core.destructive-commands');
      expect(result).toBe(false);
      expect(engine.getRule('core.destructive-commands')).toBeDefined();
    });
  });

  describe('pattern rule evaluation', () => {
    it('should block rm -rf /', async () => {
      const context: EvaluationContext = {
        toolName: 'Bash',
        toolArguments: { command: 'rm -rf /' },
      };

      const evaluation = await engine.evaluate(context);
      expect(evaluation.blocked).toBe(true);
      expect(evaluation.blockReason).toContain('Destructive Commands');
    });

    it('should block fork bombs', async () => {
      const context: EvaluationContext = {
        toolName: 'Bash',
        toolArguments: { command: ':(){:|:&};:' },
      };

      const evaluation = await engine.evaluate(context);
      expect(evaluation.blocked).toBe(true);
    });

    it('should block dangerous sudo commands', async () => {
      const context: EvaluationContext = {
        toolName: 'Bash',
        toolArguments: { command: 'sudo rm -rf /usr' },
      };

      const evaluation = await engine.evaluate(context);
      expect(evaluation.blocked).toBe(true);
      expect(evaluation.triggeredRules.some(r => r.ruleId === 'core.destructive-commands')).toBe(true);
    });

    it('should allow safe sudo commands', async () => {
      const context: EvaluationContext = {
        toolName: 'Bash',
        toolArguments: { command: 'sudo apt update' },
      };

      const evaluation = await engine.evaluate(context);
      expect(evaluation.blocked).toBe(false);
    });

    it('should allow safe commands', async () => {
      const context: EvaluationContext = {
        toolName: 'Bash',
        toolArguments: { command: 'ls -la' },
      };

      const evaluation = await engine.evaluate(context);
      expect(evaluation.blocked).toBe(false);
    });
  });

  describe('path rule evaluation', () => {
    it('should block writes to ~/.tron/app directory', async () => {
      const appPath = path.join(os.homedir(), '.tron', 'app', 'server.js');
      const context: EvaluationContext = {
        toolName: 'Write',
        toolArguments: { file_path: appPath, content: 'test' },
      };

      const evaluation = await engine.evaluate(context);
      expect(evaluation.blocked).toBe(true);
      expect(evaluation.triggeredRules.some(r => r.ruleId === 'core.tron-app-protection')).toBe(true);
    });

    it('should block writes to ~/.tron/db directory', async () => {
      const dbPath = path.join(os.homedir(), '.tron', 'db', 'prod.db');
      const context: EvaluationContext = {
        toolName: 'Write',
        toolArguments: { file_path: dbPath, content: 'test' },
      };

      const evaluation = await engine.evaluate(context);
      expect(evaluation.blocked).toBe(true);
      expect(evaluation.triggeredRules.some(r => r.ruleId === 'core.tron-db-protection')).toBe(true);
    });

    it('should block writes to ~/.tron/auth.json', async () => {
      const authPath = path.join(os.homedir(), '.tron', 'auth.json');
      const context: EvaluationContext = {
        toolName: 'Write',
        toolArguments: { file_path: authPath, content: 'test' },
      };

      const evaluation = await engine.evaluate(context);
      expect(evaluation.blocked).toBe(true);
      expect(evaluation.triggeredRules.some(r => r.ruleId === 'core.tron-auth-protection')).toBe(true);
    });

    it('should allow writes to project .tron directory', async () => {
      // Project-level .tron directories are allowed for custom configuration
      const projectTronPath = '/home/user/project/.tron/SYSTEM.md';
      const context: EvaluationContext = {
        toolName: 'Write',
        toolArguments: { file_path: projectTronPath, content: 'test' },
      };

      const evaluation = await engine.evaluate(context);
      // Should not be blocked by any tron protection rule
      const tronRules = ['core.tron-app-protection', 'core.tron-db-protection', 'core.tron-auth-protection'];
      expect(evaluation.triggeredRules.every(r => !tronRules.includes(r.ruleId))).toBe(true);
    });

    it('should block rm commands targeting ~/.tron', async () => {
      const context: EvaluationContext = {
        toolName: 'Bash',
        toolArguments: { command: `rm -rf ${path.join(os.homedir(), '.tron', 'settings.json')}` },
      };

      const evaluation = await engine.evaluate(context);
      expect(evaluation.blocked).toBe(true);
      expect(evaluation.triggeredRules.some(r => r.ruleId === 'core.tron-no-delete')).toBe(true);
    });

    it('should block path traversal', async () => {
      const context: EvaluationContext = {
        toolName: 'Write',
        toolArguments: { file_path: '/tmp/../etc/passwd', content: 'test' },
      };

      const evaluation = await engine.evaluate(context);
      expect(evaluation.blocked).toBe(true);
      expect(evaluation.triggeredRules.some(r => r.ruleId === 'path.traversal')).toBe(true);
    });

    it('should allow writes to normal paths', async () => {
      const context: EvaluationContext = {
        toolName: 'Write',
        toolArguments: { file_path: '/tmp/test.txt', content: 'test' },
      };

      const evaluation = await engine.evaluate(context);
      expect(evaluation.blocked).toBe(false);
    });
  });

  describe('resource rule evaluation', () => {
    it('should block excessive timeout', async () => {
      const context: EvaluationContext = {
        toolName: 'Bash',
        toolArguments: { command: 'sleep 1', timeout: 700000 },
      };

      const evaluation = await engine.evaluate(context);
      expect(evaluation.blocked).toBe(true);
      expect(evaluation.triggeredRules.some(r => r.ruleId === 'bash.timeout')).toBe(true);
    });

    it('should allow reasonable timeout', async () => {
      const context: EvaluationContext = {
        toolName: 'Bash',
        toolArguments: { command: 'sleep 1', timeout: 60000 },
      };

      const evaluation = await engine.evaluate(context);
      // Should not be blocked by timeout rule
      expect(evaluation.triggeredRules.every(r => r.ruleId !== 'bash.timeout')).toBe(true);
    });
  });

  describe('context rule evaluation', () => {
    it('should block tools in plan mode', async () => {
      const context: EvaluationContext = {
        toolName: 'Write',
        toolArguments: { file_path: '/tmp/test.txt', content: 'test' },
        sessionState: {
          isPlanMode: true,
          planModeBlockedTools: ['Write', 'Edit', 'Bash'],
        },
      };

      const evaluation = await engine.evaluate(context);
      expect(evaluation.blocked).toBe(true);
      expect(evaluation.triggeredRules.some(r => r.ruleId === 'session.plan-mode')).toBe(true);
    });

    it('should allow tools when not in plan mode', async () => {
      const context: EvaluationContext = {
        toolName: 'Write',
        toolArguments: { file_path: '/tmp/test.txt', content: 'test' },
        sessionState: { isPlanMode: false },
      };

      const evaluation = await engine.evaluate(context);
      expect(evaluation.triggeredRules.every(r => r.ruleId !== 'session.plan-mode')).toBe(true);
    });
  });

  describe('rule overrides', () => {
    it('should disable standard rules via overrides', async () => {
      const customEngine = createGuardrailEngine({
        ruleOverrides: { 'path.traversal': { enabled: false } },
      });

      expect(customEngine.isRuleEnabled('path.traversal')).toBe(false);

      const context: EvaluationContext = {
        toolName: 'Write',
        toolArguments: { file_path: '/tmp/../test.txt', content: 'test' },
      };

      const evaluation = await customEngine.evaluate(context);
      // Traversal rule should not trigger since it's disabled
      expect(evaluation.triggeredRules.every(r => r.ruleId !== 'path.traversal')).toBe(true);
    });

    it('should NOT allow disabling core rules via overrides', () => {
      const customEngine = createGuardrailEngine({
        ruleOverrides: { 'core.destructive-commands': { enabled: false } },
      });

      // Core rules should still be enabled
      expect(customEngine.isRuleEnabled('core.destructive-commands')).toBe(true);
    });
  });

  describe('audit logging', () => {
    it('should log all evaluations', async () => {
      const context: EvaluationContext = {
        toolName: 'Bash',
        toolArguments: { command: 'ls -la' },
        sessionId: 'test-session',
      };

      await engine.evaluate(context);

      const auditLogger = engine.getAuditLogger();
      expect(auditLogger).not.toBeNull();

      const entries = auditLogger!.getEntries();
      expect(entries.length).toBe(1);
      expect(entries[0].toolName).toBe('Bash');
      expect(entries[0].sessionId).toBe('test-session');
    });

    it('should log blocked evaluations', async () => {
      const context: EvaluationContext = {
        toolName: 'Bash',
        toolArguments: { command: 'rm -rf /' },
      };

      await engine.evaluate(context);

      const auditLogger = engine.getAuditLogger();
      const blockedEntries = auditLogger!.getBlockedEntries();
      expect(blockedEntries.length).toBe(1);
    });
  });
});
