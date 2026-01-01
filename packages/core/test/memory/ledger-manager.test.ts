/**
 * @fileoverview Tests for LedgerManager
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';
import { LedgerManager } from '../../src/memory/ledger-manager.js';

describe('LedgerManager', () => {
  let tempDir: string;
  let manager: LedgerManager;

  beforeEach(async () => {
    tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'ledger-test-'));
    manager = new LedgerManager({ ledgerDir: tempDir });
    await manager.initialize();
  });

  afterEach(async () => {
    await fs.rm(tempDir, { recursive: true, force: true });
  });

  describe('load', () => {
    it('should return empty ledger when file does not exist', async () => {
      const ledger = await manager.load();

      expect(ledger.goal).toBe('');
      expect(ledger.done).toEqual([]);
      expect(ledger.next).toEqual([]);
      expect(ledger.now).toBe('');
    });

    it('should load and parse existing ledger file', async () => {
      const content = `# Continuity Ledger

## Goal
Build the agent

## Constraints
- Use TypeScript
- Keep it simple

## Done
- [x] Setup project
- [x] Implement core

## Now
Working on tests

## Next
- [ ] Add docs
- [ ] Deploy

## Key Decisions
- **Use SQLite**: Portable and simple
- **Markdown ledger**: Human readable

## Working Files
- src/index.ts
- test/main.test.ts

---
*Last updated: 2025-12-31T12:00:00.000Z*
`;

      await fs.writeFile(manager.getPath(), content, 'utf-8');

      const ledger = await manager.load();

      expect(ledger.goal).toBe('Build the agent');
      expect(ledger.constraints).toEqual(['Use TypeScript', 'Keep it simple']);
      expect(ledger.done).toEqual(['Setup project', 'Implement core']);
      expect(ledger.now).toBe('Working on tests');
      expect(ledger.next).toEqual(['Add docs', 'Deploy']);
      expect(ledger.decisions).toEqual([
        { choice: 'Use SQLite', reason: 'Portable and simple' },
        { choice: 'Markdown ledger', reason: 'Human readable' },
      ]);
      expect(ledger.workingFiles).toEqual(['src/index.ts', 'test/main.test.ts']);
    });
  });

  describe('save', () => {
    it('should save ledger to file', async () => {
      const ledger = {
        goal: 'Test goal',
        constraints: ['Constraint 1'],
        done: ['Done task'],
        now: 'Current work',
        next: ['Next 1', 'Next 2'],
        decisions: [{ choice: 'Decision', reason: 'Because' }],
        workingFiles: ['file.ts'],
      };

      await manager.save(ledger);

      const content = await fs.readFile(manager.getPath(), 'utf-8');

      expect(content).toContain('# Continuity Ledger');
      expect(content).toContain('## Goal');
      expect(content).toContain('Test goal');
      expect(content).toContain('- Constraint 1');
      expect(content).toContain('- [x] Done task');
      expect(content).toContain('Current work');
      expect(content).toContain('- [ ] Next 1');
      expect(content).toContain('**Decision**: Because');
      expect(content).toContain('- file.ts');
      expect(content).toContain('*Last updated:');
    });
  });

  describe('update', () => {
    it('should update partial fields', async () => {
      await manager.save({
        goal: 'Original goal',
        constraints: [],
        done: [],
        now: 'Original now',
        next: [],
        decisions: [],
        workingFiles: [],
      });

      const updated = await manager.update({ now: 'New focus' });

      expect(updated.goal).toBe('Original goal'); // Unchanged
      expect(updated.now).toBe('New focus'); // Updated
    });

    it('should auto-save when configured', async () => {
      await manager.update({ goal: 'Auto-saved goal' });

      const loaded = await manager.load();
      expect(loaded.goal).toBe('Auto-saved goal');
    });
  });

  describe('setGoal', () => {
    it('should set the goal', async () => {
      await manager.setGoal('New goal');

      const ledger = await manager.get();
      expect(ledger.goal).toBe('New goal');
    });
  });

  describe('setNow', () => {
    it('should set current focus', async () => {
      await manager.setNow('Implementing feature X');

      const ledger = await manager.get();
      expect(ledger.now).toBe('Implementing feature X');
    });
  });

  describe('addDone', () => {
    it('should add item to done list', async () => {
      await manager.addDone('Task 1');
      await manager.addDone('Task 2');

      const ledger = await manager.get();
      expect(ledger.done).toEqual(['Task 1', 'Task 2']);
    });
  });

  describe('addNext', () => {
    it('should add item to next list', async () => {
      await manager.addNext('Next task 1');
      await manager.addNext('Next task 2');

      const ledger = await manager.get();
      expect(ledger.next).toEqual(['Next task 1', 'Next task 2']);
    });
  });

  describe('popNext', () => {
    it('should remove and return first item from next list', async () => {
      await manager.addNext('First');
      await manager.addNext('Second');

      const { item, ledger } = await manager.popNext();

      expect(item).toBe('First');
      expect(ledger.next).toEqual(['Second']);
    });

    it('should return null when next list is empty', async () => {
      const { item } = await manager.popNext();

      expect(item).toBeNull();
    });
  });

  describe('completeNow', () => {
    it('should move now to done and pop next', async () => {
      await manager.setNow('Current task');
      await manager.addNext('Next task');

      const ledger = await manager.completeNow();

      expect(ledger.done).toContain('Current task');
      expect(ledger.now).toBe('Next task');
      expect(ledger.next).toEqual([]);
    });

    it('should clear now when next is empty', async () => {
      await manager.setNow('Current task');

      const ledger = await manager.completeNow();

      expect(ledger.done).toContain('Current task');
      expect(ledger.now).toBe('');
    });
  });

  describe('addDecision', () => {
    it('should add decision with reason', async () => {
      await manager.addDecision('Use React', 'Best for this use case');

      const ledger = await manager.get();
      expect(ledger.decisions).toHaveLength(1);
      expect(ledger.decisions[0]!.choice).toBe('Use React');
      expect(ledger.decisions[0]!.reason).toBe('Best for this use case');
    });
  });

  describe('addWorkingFile', () => {
    it('should add working file', async () => {
      await manager.addWorkingFile('src/index.ts');

      const ledger = await manager.get();
      expect(ledger.workingFiles).toContain('src/index.ts');
    });

    it('should not add duplicate files', async () => {
      await manager.addWorkingFile('src/index.ts');
      await manager.addWorkingFile('src/index.ts');

      const ledger = await manager.get();
      expect(ledger.workingFiles.filter(f => f === 'src/index.ts')).toHaveLength(1);
    });
  });

  describe('removeWorkingFile', () => {
    it('should remove working file', async () => {
      await manager.addWorkingFile('src/index.ts');
      await manager.addWorkingFile('src/other.ts');
      await manager.removeWorkingFile('src/index.ts');

      const ledger = await manager.get();
      expect(ledger.workingFiles).not.toContain('src/index.ts');
      expect(ledger.workingFiles).toContain('src/other.ts');
    });
  });

  describe('addConstraint', () => {
    it('should add constraint', async () => {
      await manager.addConstraint('Must use TypeScript');

      const ledger = await manager.get();
      expect(ledger.constraints).toContain('Must use TypeScript');
    });

    it('should not add duplicate constraints', async () => {
      await manager.addConstraint('Must use TypeScript');
      await manager.addConstraint('Must use TypeScript');

      const ledger = await manager.get();
      expect(ledger.constraints.filter(c => c === 'Must use TypeScript')).toHaveLength(1);
    });
  });

  describe('clear', () => {
    it('should clear all fields', async () => {
      await manager.setGoal('Goal');
      await manager.setNow('Working');
      await manager.addDone('Done');
      await manager.addNext('Next');

      const ledger = await manager.clear();

      expect(ledger.goal).toBe('');
      expect(ledger.now).toBe('');
      expect(ledger.done).toEqual([]);
      expect(ledger.next).toEqual([]);
    });

    it('should preserve goal when requested', async () => {
      await manager.setGoal('Important goal');
      await manager.addConstraint('Important constraint');
      await manager.addDone('Done');

      const ledger = await manager.clear(true);

      expect(ledger.goal).toBe('Important goal');
      expect(ledger.constraints).toContain('Important constraint');
      expect(ledger.done).toEqual([]);
    });
  });

  describe('formatForContext', () => {
    it('should format ledger for agent context', async () => {
      await manager.setGoal('Build agent');
      await manager.setNow('Writing tests');
      await manager.addNext('Add docs');
      await manager.addWorkingFile('src/agent.ts');

      const context = await manager.formatForContext();

      expect(context).toContain('**Goal**: Build agent');
      expect(context).toContain('**Working on**: Writing tests');
      expect(context).toContain('**Next up**: Add docs');
      expect(context).toContain('**Files**: src/agent.ts');
    });
  });
});
