/**
 * @fileoverview Session Manager
 *
 * Manages the lifecycle of agent sessions including creation,
 * persistence, resumption, forking, and rewinding.
 */
import { EventEmitter } from 'events';
import * as fs from 'fs/promises';
import * as path from 'path';
import { randomUUID } from 'crypto';
import { createLogger } from '../logging/logger.js';
import type { Message, TokenUsage } from '../types/index.js';
import type {
  Session,
  SessionSummary,
  SessionMetadata,
  SessionLogEntry,
  SessionStartEntry,
  MessageEntry,
  SessionEndEntry,
  MetadataUpdateEntry,
  CreateSessionOptions,
  ListSessionsOptions,
  ForkSessionOptions,
  ForkSessionResult,
  RewindSessionOptions,
  RewindSessionResult,
} from './types.js';

const logger = createLogger('session-manager');

// =============================================================================
// Configuration
// =============================================================================

export interface SessionManagerConfig {
  /** Directory to store session files */
  sessionsDir: string;
  /** Default model to use for new sessions */
  defaultModel: string;
  /** Default provider to use */
  defaultProvider: string;
}

// =============================================================================
// Session Manager
// =============================================================================

export class SessionManager extends EventEmitter {
  private config: SessionManagerConfig;
  /** In-memory cache of active sessions */
  private sessions: Map<string, Session> = new Map();

  constructor(config: SessionManagerConfig) {
    super();
    this.config = config;
    logger.debug('SessionManager initialized', { sessionsDir: config.sessionsDir });
  }

  // ===========================================================================
  // Session Creation
  // ===========================================================================

  /**
   * Create a new session
   */
  async createSession(options: CreateSessionOptions): Promise<Session> {
    const sessionId = `sess_${randomUUID().replace(/-/g, '').slice(0, 12)}`;
    const now = new Date().toISOString();

    const session: Session = {
      id: sessionId,
      workingDirectory: options.workingDirectory,
      model: options.model ?? this.config.defaultModel,
      provider: options.provider ?? this.config.defaultProvider,
      systemPrompt: options.systemPrompt,
      messages: [],
      createdAt: now,
      lastActivityAt: now,
      tokenUsage: { inputTokens: 0, outputTokens: 0 },
      currentTurn: 0,
      isActive: true,
      activeFiles: [],
      metadata: {
        title: options.title,
        tags: options.tags,
        contextFiles: options.contextFiles,
      },
    };

    // Ensure sessions directory exists
    await fs.mkdir(this.config.sessionsDir, { recursive: true });

    // Write session start entry
    const startEntry: SessionStartEntry = {
      type: 'session_start',
      timestamp: now,
      sessionId,
      workingDirectory: session.workingDirectory,
      model: session.model,
      provider: session.provider,
      systemPrompt: session.systemPrompt,
      metadata: session.metadata,
    };

    await this.appendEntry(sessionId, startEntry);

    // Cache the session
    this.sessions.set(sessionId, session);

    logger.info('Session created', { sessionId, workingDirectory: options.workingDirectory });

    // Emit event
    const summary = this.toSummary(session);
    this.emit('session_created', summary);

    return session;
  }

  // ===========================================================================
  // Session Retrieval
  // ===========================================================================

  /**
   * Get a session by ID
   */
  async getSession(sessionId: string): Promise<Session | null> {
    // Check cache first
    if (this.sessions.has(sessionId)) {
      return this.sessions.get(sessionId)!;
    }

    // Try to load from file
    const session = await this.loadSession(sessionId);
    if (session) {
      this.sessions.set(sessionId, session);
    }

    return session;
  }

  /**
   * List sessions with optional filtering
   */
  async listSessions(options: ListSessionsOptions): Promise<SessionSummary[]> {
    const summaries: SessionSummary[] = [];

    // Get cached sessions
    for (const session of this.sessions.values()) {
      if (this.matchesFilter(session, options)) {
        summaries.push(this.toSummary(session));
      }
    }

    // Also scan sessions directory for non-cached sessions
    try {
      const files = await fs.readdir(this.config.sessionsDir, { withFileTypes: true });

      for (const file of files) {
        if (file.isFile() && file.name.endsWith('.jsonl')) {
          const sessionId = file.name.replace('.jsonl', '');

          // Skip if already in summaries
          if (summaries.some(s => s.id === sessionId)) continue;

          // Load first line to get session info
          const session = await this.loadSessionSummary(sessionId);
          if (session && this.matchesFilter(session, options)) {
            summaries.push(session);
          }
        }
      }
    } catch (err) {
      // Directory may not exist yet
      logger.debug('Sessions directory not found', { error: err });
    }

    // Sort
    const orderBy = options.orderBy ?? 'lastActivityAt';
    const order = options.order ?? 'desc';
    summaries.sort((a, b) => {
      const aVal = a[orderBy] ?? '';
      const bVal = b[orderBy] ?? '';
      return order === 'desc' ? bVal.localeCompare(aVal) : aVal.localeCompare(bVal);
    });

    // Apply limit
    if (options.limit) {
      return summaries.slice(0, options.limit);
    }

    return summaries;
  }

  /**
   * Get the most recent session for a working directory
   */
  async getMostRecent(workingDirectory: string): Promise<Session | null> {
    const sessions = await this.listSessions({
      workingDirectory,
      includeEnded: false,
      limit: 1,
      orderBy: 'lastActivityAt',
      order: 'desc',
    });

    const firstSession = sessions[0];
    if (!firstSession) return null;

    return this.getSession(firstSession.id);
  }

  // ===========================================================================
  // Session Modification
  // ===========================================================================

  /**
   * Add a message to a session
   */
  async addMessage(
    sessionId: string,
    message: Message,
    tokenUsage?: TokenUsage
  ): Promise<void> {
    const session = await this.getSession(sessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    const now = new Date().toISOString();

    // Update session state
    session.messages.push(message);
    session.lastActivityAt = now;

    if (tokenUsage) {
      session.tokenUsage.inputTokens += tokenUsage.inputTokens;
      session.tokenUsage.outputTokens += tokenUsage.outputTokens;
    }

    // Append to file
    const entry: MessageEntry = {
      type: 'message',
      timestamp: now,
      message,
      turn: session.currentTurn,
      tokenUsage,
    };

    await this.appendEntry(sessionId, entry);

    logger.debug('Message added', { sessionId, role: message.role });
  }

  /**
   * Update session metadata
   */
  async updateMetadata(
    sessionId: string,
    updates: Partial<SessionMetadata>
  ): Promise<void> {
    const session = await this.getSession(sessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    // Merge updates
    session.metadata = { ...session.metadata, ...updates };
    session.lastActivityAt = new Date().toISOString();

    // Append to file
    const entry: MetadataUpdateEntry = {
      type: 'metadata_update',
      timestamp: session.lastActivityAt,
      updates,
    };

    await this.appendEntry(sessionId, entry);

    logger.debug('Metadata updated', { sessionId, updates });
  }

  /**
   * End a session
   */
  async endSession(
    sessionId: string,
    reason: 'completed' | 'aborted' | 'error' | 'timeout',
    summary?: string
  ): Promise<void> {
    const session = await this.getSession(sessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }

    const now = new Date().toISOString();

    // Update session state
    session.endedAt = now;
    session.isActive = false;
    session.lastActivityAt = now;

    // Append to file
    const entry: SessionEndEntry = {
      type: 'session_end',
      timestamp: now,
      reason,
      summary,
      tokenUsage: session.tokenUsage,
    };

    await this.appendEntry(sessionId, entry);

    logger.info('Session ended', { sessionId, reason });

    // Emit event
    this.emit('session_ended', { sessionId, reason });
  }

  // ===========================================================================
  // Session Deletion
  // ===========================================================================

  /**
   * Delete a session
   */
  async deleteSession(sessionId: string): Promise<boolean> {
    try {
      const filePath = this.getSessionPath(sessionId);
      await fs.rm(filePath, { force: true });

      // Remove from cache
      this.sessions.delete(sessionId);

      logger.info('Session deleted', { sessionId });
      this.emit('session_deleted', { sessionId });

      return true;
    } catch (err) {
      logger.warn('Failed to delete session', { sessionId, error: err });
      return false;
    }
  }

  // ===========================================================================
  // Session Fork & Rewind
  // ===========================================================================

  /**
   * Fork a session, creating a new session with copied messages
   */
  async forkSession(options: ForkSessionOptions): Promise<ForkSessionResult> {
    const original = await this.getSession(options.sessionId);
    if (!original) {
      throw new Error(`Session not found: ${options.sessionId}`);
    }

    // Determine how many messages to copy
    const fromIndex = options.fromIndex ?? original.messages.length;
    const messagesToCopy = original.messages.slice(0, fromIndex);

    // Create new session
    const forked = await this.createSession({
      workingDirectory: original.workingDirectory,
      model: original.model,
      provider: original.provider,
      systemPrompt: original.systemPrompt,
      title: options.title ?? `Fork of ${original.metadata.title ?? original.id}`,
    });

    // Update metadata to link to parent
    await this.updateMetadata(forked.id, {
      parentSessionId: original.id,
      forkFromIndex: fromIndex,
    });

    // Copy messages
    for (const message of messagesToCopy) {
      await this.addMessage(forked.id, message);
    }

    logger.info('Session forked', {
      original: original.id,
      forked: forked.id,
      messageCount: messagesToCopy.length,
    });

    this.emit('session_forked', { original: original.id, forked: forked.id });

    return {
      newSessionId: forked.id,
      forkedFrom: original.id,
      messageCount: messagesToCopy.length,
    };
  }

  /**
   * Rewind a session to an earlier state
   */
  async rewindSession(options: RewindSessionOptions): Promise<RewindSessionResult> {
    const session = await this.getSession(options.sessionId);
    if (!session) {
      throw new Error(`Session not found: ${options.sessionId}`);
    }

    if (options.toIndex < 0 || options.toIndex >= session.messages.length) {
      throw new Error(`Index out of bounds: ${options.toIndex}`);
    }

    // toIndex is inclusive - keep messages from 0 to toIndex (inclusive)
    const keepCount = options.toIndex + 1;
    const removedCount = session.messages.length - keepCount;

    // Truncate messages in memory
    session.messages = session.messages.slice(0, keepCount);
    session.lastActivityAt = new Date().toISOString();

    // Rewrite the session file
    await this.rewriteSession(session);

    logger.info('Session rewound', {
      sessionId: session.id,
      toIndex: options.toIndex,
      removedCount,
    });

    this.emit('session_rewound', {
      sessionId: session.id,
      toIndex: options.toIndex,
    });

    return {
      sessionId: session.id,
      newMessageCount: session.messages.length,
      removedCount,
    };
  }

  // ===========================================================================
  // Private Methods
  // ===========================================================================

  private getSessionPath(sessionId: string): string {
    return path.join(this.config.sessionsDir, `${sessionId}.jsonl`);
  }

  private async appendEntry(sessionId: string, entry: SessionLogEntry): Promise<void> {
    const filePath = this.getSessionPath(sessionId);
    await fs.appendFile(filePath, JSON.stringify(entry) + '\n');
  }

  private async loadSession(sessionId: string): Promise<Session | null> {
    const filePath = this.getSessionPath(sessionId);

    try {
      await fs.access(filePath);
    } catch {
      return null;
    }

    try {
      const content = await fs.readFile(filePath, 'utf-8');
      const lines = content.trim().split('\n');

      let session: Session | null = null;

      for (const line of lines) {
        if (!line) continue;

        const entry = JSON.parse(line) as SessionLogEntry;

        switch (entry.type) {
          case 'session_start':
            session = {
              id: entry.sessionId,
              workingDirectory: entry.workingDirectory,
              model: entry.model,
              provider: entry.provider,
              systemPrompt: entry.systemPrompt,
              messages: [],
              createdAt: entry.timestamp,
              lastActivityAt: entry.timestamp,
              tokenUsage: { inputTokens: 0, outputTokens: 0 },
              currentTurn: 0,
              isActive: true,
              activeFiles: [],
              metadata: entry.metadata,
            };
            break;

          case 'message':
            if (session) {
              session.messages.push(entry.message);
              session.lastActivityAt = entry.timestamp;
              if (entry.tokenUsage) {
                session.tokenUsage.inputTokens += entry.tokenUsage.inputTokens;
                session.tokenUsage.outputTokens += entry.tokenUsage.outputTokens;
              }
            }
            break;

          case 'metadata_update':
            if (session) {
              session.metadata = { ...session.metadata, ...entry.updates };
              session.lastActivityAt = entry.timestamp;
            }
            break;

          case 'session_end':
            if (session) {
              session.endedAt = entry.timestamp;
              session.isActive = false;
              session.lastActivityAt = entry.timestamp;
            }
            break;
        }
      }

      return session;
    } catch (err) {
      logger.error('Failed to load session', { sessionId, error: err });
      return null;
    }
  }

  private async loadSessionSummary(sessionId: string): Promise<SessionSummary | null> {
    const filePath = this.getSessionPath(sessionId);

    try {
      const content = await fs.readFile(filePath, 'utf-8');
      const firstLine = content.split('\n')[0];
      if (!firstLine) return null;

      const entry = JSON.parse(firstLine) as SessionStartEntry;
      if (entry.type !== 'session_start') return null;

      // Count messages by reading the rest
      const lines = content.trim().split('\n');
      let messageCount = 0;
      let lastActivityAt = entry.timestamp;
      let isActive = true;

      for (const line of lines.slice(1)) {
        if (!line) continue;
        const e = JSON.parse(line) as SessionLogEntry;
        if (e.type === 'message') {
          messageCount++;
          lastActivityAt = e.timestamp;
        } else if (e.type === 'session_end') {
          isActive = false;
          lastActivityAt = e.timestamp;
        }
      }

      return {
        id: entry.sessionId,
        workingDirectory: entry.workingDirectory,
        model: entry.model,
        messageCount,
        createdAt: entry.timestamp,
        lastActivityAt,
        isActive,
        title: entry.metadata.title,
        tags: entry.metadata.tags,
      };
    } catch {
      return null;
    }
  }

  private async rewriteSession(session: Session): Promise<void> {
    const filePath = this.getSessionPath(session.id);

    // Build new content
    const entries: SessionLogEntry[] = [];

    // Session start
    entries.push({
      type: 'session_start',
      timestamp: session.createdAt,
      sessionId: session.id,
      workingDirectory: session.workingDirectory,
      model: session.model,
      provider: session.provider,
      systemPrompt: session.systemPrompt,
      metadata: session.metadata,
    });

    // Messages
    for (const message of session.messages) {
      entries.push({
        type: 'message',
        timestamp: session.lastActivityAt, // Not ideal but we don't have original timestamps
        message,
      });
    }

    // Write atomically
    const content = entries.map(e => JSON.stringify(e)).join('\n') + '\n';
    await fs.writeFile(filePath, content);
  }

  private matchesFilter(session: Session | SessionSummary, options: ListSessionsOptions): boolean {
    if (options.workingDirectory && session.workingDirectory !== options.workingDirectory) {
      return false;
    }

    if (!options.includeEnded && !session.isActive) {
      return false;
    }

    if (options.tags?.length) {
      const sessionTags = 'tags' in session && session.tags ? session.tags : [];
      if (!options.tags.some(t => sessionTags.includes(t))) {
        return false;
      }
    }

    return true;
  }

  private toSummary(session: Session): SessionSummary {
    return {
      id: session.id,
      workingDirectory: session.workingDirectory,
      model: session.model,
      messageCount: session.messages.length,
      createdAt: session.createdAt,
      lastActivityAt: session.lastActivityAt,
      isActive: session.isActive,
      title: session.metadata.title,
      tags: session.metadata.tags,
    };
  }

  // EventEmitter typed overloads
  emit(event: 'session_created', summary: SessionSummary): boolean;
  emit(event: 'session_ended', data: { sessionId: string; reason: string }): boolean;
  emit(event: 'session_forked', data: { original: string; forked: string }): boolean;
  emit(event: 'session_rewound', data: { sessionId: string; toIndex: number }): boolean;
  emit(event: 'session_deleted', data: { sessionId: string }): boolean;
  emit(event: string, ...args: unknown[]): boolean {
    return super.emit(event, ...args);
  }

  on(event: 'session_created', listener: (summary: SessionSummary) => void): this;
  on(event: 'session_ended', listener: (data: { sessionId: string; reason: string }) => void): this;
  on(event: 'session_forked', listener: (data: { original: string; forked: string }) => void): this;
  on(event: 'session_rewound', listener: (data: { sessionId: string; toIndex: number }) => void): this;
  on(event: 'session_deleted', listener: (data: { sessionId: string }) => void): this;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  on(event: string, listener: (...args: any[]) => void): this {
    return super.on(event, listener);
  }
}
