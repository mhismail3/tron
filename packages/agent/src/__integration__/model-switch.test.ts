/**
 * @fileoverview Tests for model switching functionality
 *
 * These tests verify that:
 * - Model switch events are properly linearized (correct parentId chain)
 * - Model changes are persisted to the session in the database
 * - Reloaded sessions reflect the switched model
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { EventStore, SessionId } from '../index.js';
import path from 'path';
import os from 'os';
import fs from 'fs';

describe('Model Switch', () => {
  let eventStore: EventStore;
  let testDir: string;

  beforeEach(async () => {
    testDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tron-model-switch-test-'));
    const dbPath = path.join(testDir, 'events.db');
    eventStore = new EventStore(dbPath);
    await eventStore.initialize();
  });

  afterEach(async () => {
    await eventStore.close();
    fs.rmSync(testDir, { recursive: true, force: true });
  });

  describe('model switch event linearization', () => {
    it('should create model switch event with correct parent chain', async () => {
      // Create session
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-haiku-4-5-20251001',
      });

      // Add a user message first
      const userMsgEvent = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Hello' },
        parentId: rootEvent.id,
      });

      // Now switch model - the event should chain from userMsgEvent
      const modelSwitchEvent = await eventStore.append({
        sessionId: session.id,
        type: 'config.model_switch',
        payload: {
          previousModel: 'claude-haiku-4-5-20251001',
          newModel: 'claude-sonnet-4-5-20250929',
        },
        parentId: userMsgEvent.id,
      });

      expect(modelSwitchEvent.parentId).toBe(userMsgEvent.id);
      expect(modelSwitchEvent.type).toBe('config.model_switch');
      const switchPayload = modelSwitchEvent.payload as { previousModel: string; newModel: string };
      expect(switchPayload.previousModel).toBe('claude-haiku-4-5-20251001');
      expect(switchPayload.newModel).toBe('claude-sonnet-4-5-20250929');
    });

    it('should not create branch when model is switched', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-haiku-4-5-20251001',
      });

      // Add message → model switch → another message
      const msg1 = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'First message' },
        parentId: rootEvent.id,
      });

      const modelSwitch = await eventStore.append({
        sessionId: session.id,
        type: 'config.model_switch',
        payload: { previousModel: 'claude-haiku-4-5-20251001', newModel: 'claude-sonnet-4-5-20250929' },
        parentId: msg1.id,
      });

      const msg2 = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Second message after model switch' },
        parentId: modelSwitch.id,
      });

      // Verify chain: root → msg1 → modelSwitch → msg2
      expect(msg1.parentId).toBe(rootEvent.id);
      expect(modelSwitch.parentId).toBe(msg1.id);
      expect(msg2.parentId).toBe(modelSwitch.id);

      // Count branch points (parents with multiple children)
      const events = await eventStore.getEventsBySession(session.id);
      const childCounts: Record<string, number> = {};
      for (const event of events) {
        if (event.parentId) {
          childCounts[event.parentId] = (childCounts[event.parentId] || 0) + 1;
        }
      }
      const branchPoints = Object.values(childCounts).filter(count => count > 1).length;
      expect(branchPoints).toBe(0);
    });
  });

  describe('model persistence in database', () => {
    it('should persist model change to session record', async () => {
      const { session } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-haiku-4-5-20251001',
      });

      // Verify initial model
      let dbSession = await eventStore.getSession(session.id);
      expect(dbSession?.model).toBe('claude-haiku-4-5-20251001');

      // Update model in database
      await eventStore.updateLatestModel(session.id, 'claude-sonnet-4-5-20250929');

      // Verify model was persisted
      dbSession = await eventStore.getSession(session.id);
      expect(dbSession?.model).toBe('claude-sonnet-4-5-20250929');
    });

    it('should retain model after session is reloaded', async () => {
      const { session } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-haiku-4-5-20251001',
      });

      // Update model
      await eventStore.updateLatestModel(session.id, 'claude-opus-4-5-20251101');

      // Close and reopen event store (simulating app restart)
      await eventStore.close();

      const dbPath = path.join(testDir, 'events.db');
      const newEventStore = new EventStore(dbPath);
      await newEventStore.initialize();

      // Session should have the updated model
      const reloadedSession = await newEventStore.getSession(session.id);
      expect(reloadedSession?.model).toBe('claude-opus-4-5-20251101');

      await newEventStore.close();
    });

    it('should update last_activity_at when model is switched', async () => {
      const { session } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-haiku-4-5-20251001',
      });

      const before = await eventStore.getSession(session.id);
      const beforeTime = new Date(before!.lastActivityAt).getTime();

      // Small delay to ensure timestamp difference
      await new Promise(resolve => setTimeout(resolve, 50));

      await eventStore.updateLatestModel(session.id, 'claude-sonnet-4-5-20250929');

      const after = await eventStore.getSession(session.id);
      const afterTime = new Date(after!.lastActivityAt).getTime();

      expect(afterTime).toBeGreaterThan(beforeTime);
    });
  });

  describe('model reconstruction from events', () => {
    it('should be able to determine current model from event chain', async () => {
      const { session, rootEvent } = await eventStore.createSession({
        workspacePath: '/test/project',
        workingDirectory: '/test/project',
        model: 'claude-haiku-4-5-20251001',
      });

      // Add events including model switches
      const msg1 = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Hello' },
        parentId: rootEvent.id,
      });

      const switch1 = await eventStore.append({
        sessionId: session.id,
        type: 'config.model_switch',
        payload: { previousModel: 'claude-haiku-4-5-20251001', newModel: 'claude-sonnet-4-5-20250929' },
        parentId: msg1.id,
      });

      const msg2 = await eventStore.append({
        sessionId: session.id,
        type: 'message.user',
        payload: { content: 'Using Sonnet now' },
        parentId: switch1.id,
      });

      const switch2 = await eventStore.append({
        sessionId: session.id,
        type: 'config.model_switch',
        payload: { previousModel: 'claude-sonnet-4-5-20250929', newModel: 'claude-opus-4-5-20251101' },
        parentId: msg2.id,
      });

      // Get ancestors from head to reconstruct current model
      const dbSession = await eventStore.getSession(session.id);
      const ancestors = await eventStore.getAncestors(dbSession!.headEventId!);

      // Find the last model_switch event to determine current model
      let currentModel = 'claude-haiku-4-5-20251001'; // Initial from session.start
      for (const event of ancestors) {
        if (event.type === 'session.start') {
          currentModel = event.payload.model as string;
        } else if (event.type === 'config.model_switch') {
          currentModel = event.payload.newModel as string;
        }
      }

      expect(currentModel).toBe('claude-opus-4-5-20251101');
    });
  });
});
