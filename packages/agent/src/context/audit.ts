/**
 * @fileoverview Context Audit System
 *
 * Provides comprehensive traceability for what goes into an agent's context.
 * This is a CRITICAL feature for debugging and understanding agent behavior.
 *
 * Tracks:
 * - Context files loaded (AGENTS.md, CLAUDE.md hierarchy)
 * - Handoffs retrieved and injected
 * - System prompt composition
 * - Tool definitions
 * - Hook modifications to context
 * - Session metadata
 *
 * The audit is:
 * - Always generated on session start/resume/fork
 * - Queryable interactively via /context command
 * - Exportable as JSON or Markdown
 * - Logged in debug mode
 *
 * @example
 * ```typescript
 * const audit = new ContextAudit();
 *
 * // Track context loading
 * audit.addContextFile({ path: '~/.tron/AGENTS.md', content: '...', charCount: 500 });
 * audit.addHandoff({ id: 'h1', summary: 'Previous work on auth' });
 *
 * // Get full audit
 * console.log(audit.toMarkdown());
 * ```
 */

// =============================================================================
// Types
// =============================================================================

export interface ContextFileEntry {
  /** Absolute path to the file */
  path: string;
  /** Type of context file */
  type: 'global' | 'project' | 'directory';
  /** Character count of content */
  charCount: number;
  /** Line count */
  lineCount: number;
  /** First 500 chars preview */
  preview: string;
  /** Load timestamp */
  loadedAt: Date;
}

export interface HandoffEntry {
  /** Handoff ID */
  id: string;
  /** Session ID the handoff is from */
  sessionId: string;
  /** Summary text */
  summary: string;
  /** Character count injected */
  charCount: number;
  /** When the handoff was created */
  timestamp: Date;
}

export interface HookModification {
  /** Hook ID/name */
  hookId: string;
  /** Hook event type */
  event: string;
  /** What was modified */
  modification: string;
  /** Character delta (positive = added, negative = removed) */
  charDelta: number;
  /** When the modification occurred */
  timestamp: Date;
}

export interface ToolEntry {
  /** Tool name */
  name: string;
  /** Tool description */
  description: string;
  /** Parameter schema character count */
  schemaCharCount: number;
}

export interface ContextAuditData {
  /** Session information */
  session: {
    id: string;
    type: 'new' | 'resume' | 'fork';
    parentSessionId?: string;
    forkPoint?: number;
    startedAt: Date;
    workingDirectory: string;
    model: string;
  };

  /** Context files loaded */
  contextFiles: ContextFileEntry[];

  /** Handoffs injected */
  handoffs: HandoffEntry[];

  /** Tools registered */
  tools: ToolEntry[];

  /** Hook modifications */
  hookModifications: HookModification[];

  /** Final system prompt */
  systemPrompt: {
    totalCharCount: number;
    sections: Array<{
      name: string;
      charCount: number;
      source: string;
    }>;
  };

  /** Token estimates */
  tokenEstimates: {
    /** Approximate input tokens for context */
    contextTokens: number;
    /** Approximate tokens for system prompt */
    systemPromptTokens: number;
    /** Approximate tokens for tool definitions */
    toolTokens: number;
    /** Total estimated tokens before user message */
    totalBaseTokens: number;
  };
}

// =============================================================================
// Context Audit Class
// =============================================================================

export class ContextAudit {
  private data: ContextAuditData;

  constructor() {
    this.data = {
      session: {
        id: '',
        type: 'new',
        startedAt: new Date(),
        workingDirectory: '',
        model: '',
      },
      contextFiles: [],
      handoffs: [],
      tools: [],
      hookModifications: [],
      systemPrompt: {
        totalCharCount: 0,
        sections: [],
      },
      tokenEstimates: {
        contextTokens: 0,
        systemPromptTokens: 0,
        toolTokens: 0,
        totalBaseTokens: 0,
      },
    };
  }

  // ===========================================================================
  // Session Methods
  // ===========================================================================

  /**
   * Set session information
   */
  setSession(info: ContextAuditData['session']): void {
    this.data.session = { ...info };
  }

  // ===========================================================================
  // Context File Methods
  // ===========================================================================

  /**
   * Add a context file entry
   */
  addContextFile(file: {
    path: string;
    type: ContextFileEntry['type'];
    content: string;
  }): void {
    const lines = file.content.split('\n');
    this.data.contextFiles.push({
      path: file.path,
      type: file.type,
      charCount: file.content.length,
      lineCount: lines.length,
      preview: file.content.slice(0, 500) + (file.content.length > 500 ? '...' : ''),
      loadedAt: new Date(),
    });

    // Update token estimates (rough: ~4 chars per token)
    this.data.tokenEstimates.contextTokens += Math.ceil(file.content.length / 4);
    this.updateTotalTokens();
  }

  // ===========================================================================
  // Handoff Methods
  // ===========================================================================

  /**
   * Add a handoff entry
   */
  addHandoff(handoff: {
    id: string;
    sessionId: string;
    summary: string;
    timestamp: Date;
  }): void {
    this.data.handoffs.push({
      ...handoff,
      charCount: handoff.summary.length,
    });
  }

  // ===========================================================================
  // Tool Methods
  // ===========================================================================

  /**
   * Add a tool entry
   */
  addTool(tool: {
    name: string;
    description: string;
    parameters: Record<string, unknown>;
  }): void {
    const schemaStr = JSON.stringify(tool.parameters);
    this.data.tools.push({
      name: tool.name,
      description: tool.description,
      schemaCharCount: schemaStr.length,
    });

    // Update token estimates
    this.data.tokenEstimates.toolTokens += Math.ceil(
      (tool.name.length + tool.description.length + schemaStr.length) / 4
    );
    this.updateTotalTokens();
  }

  // ===========================================================================
  // Hook Methods
  // ===========================================================================

  /**
   * Record a hook modification to context
   */
  addHookModification(mod: {
    hookId: string;
    event: string;
    modification: string;
    charDelta: number;
  }): void {
    this.data.hookModifications.push({
      ...mod,
      timestamp: new Date(),
    });
  }

  // ===========================================================================
  // System Prompt Methods
  // ===========================================================================

  /**
   * Set the final system prompt details
   */
  setSystemPrompt(prompt: {
    content: string;
    sections: Array<{ name: string; content: string; source: string }>;
  }): void {
    this.data.systemPrompt = {
      totalCharCount: prompt.content.length,
      sections: prompt.sections.map(s => ({
        name: s.name,
        charCount: s.content.length,
        source: s.source,
      })),
    };

    // Update token estimates
    this.data.tokenEstimates.systemPromptTokens = Math.ceil(prompt.content.length / 4);
    this.updateTotalTokens();
  }

  // ===========================================================================
  // Output Methods
  // ===========================================================================

  /**
   * Get raw audit data
   */
  getData(): ContextAuditData {
    return { ...this.data };
  }

  /**
   * Export as JSON
   */
  toJSON(): string {
    return JSON.stringify(this.data, null, 2);
  }

  /**
   * Export as Markdown for display
   */
  toMarkdown(): string {
    const lines: string[] = [];

    // Header
    lines.push('# Context Audit Report');
    lines.push('');

    // Session info
    lines.push('## Session');
    lines.push(`- **ID**: ${this.data.session.id}`);
    lines.push(`- **Type**: ${this.data.session.type}`);
    if (this.data.session.parentSessionId) {
      lines.push(`- **Parent Session**: ${this.data.session.parentSessionId}`);
    }
    if (this.data.session.forkPoint !== undefined) {
      lines.push(`- **Fork Point**: Message ${this.data.session.forkPoint}`);
    }
    lines.push(`- **Started**: ${this.data.session.startedAt.toISOString()}`);
    lines.push(`- **Working Dir**: ${this.data.session.workingDirectory}`);
    lines.push(`- **Model**: ${this.data.session.model}`);
    lines.push('');

    // Token estimates
    lines.push('## Token Estimates');
    lines.push(`- Context files: ~${this.data.tokenEstimates.contextTokens} tokens`);
    lines.push(`- System prompt: ~${this.data.tokenEstimates.systemPromptTokens} tokens`);
    lines.push(`- Tool definitions: ~${this.data.tokenEstimates.toolTokens} tokens`);
    lines.push(`- **Total base**: ~${this.data.tokenEstimates.totalBaseTokens} tokens`);
    lines.push('');

    // Context files
    lines.push('## Context Files');
    if (this.data.contextFiles.length === 0) {
      lines.push('*No context files loaded*');
    } else {
      for (const file of this.data.contextFiles) {
        lines.push(`### ${file.type}: ${file.path}`);
        lines.push(`- ${file.charCount} chars, ${file.lineCount} lines`);
        lines.push(`- Loaded: ${file.loadedAt.toISOString()}`);
        lines.push('```');
        lines.push(file.preview);
        lines.push('```');
        lines.push('');
      }
    }
    lines.push('');

    // Handoffs
    lines.push('## Handoffs Injected');
    if (this.data.handoffs.length === 0) {
      lines.push('*No handoffs injected*');
    } else {
      for (const h of this.data.handoffs) {
        lines.push(`### ${h.id}`);
        lines.push(`- From session: ${h.sessionId}`);
        lines.push(`- Created: ${h.timestamp.toISOString()}`);
        lines.push(`- ${h.charCount} chars`);
        lines.push(`> ${h.summary.slice(0, 200)}${h.summary.length > 200 ? '...' : ''}`);
        lines.push('');
      }
    }
    lines.push('');

    // Tools
    lines.push('## Tools Registered');
    if (this.data.tools.length === 0) {
      lines.push('*No tools registered*');
    } else {
      for (const tool of this.data.tools) {
        lines.push(`- **${tool.name}**: ${tool.description.slice(0, 80)}${tool.description.length > 80 ? '...' : ''} (${tool.schemaCharCount} chars schema)`);
      }
    }
    lines.push('');

    // Hook modifications
    lines.push('## Hook Modifications');
    if (this.data.hookModifications.length === 0) {
      lines.push('*No hook modifications*');
    } else {
      for (const mod of this.data.hookModifications) {
        const delta = mod.charDelta >= 0 ? `+${mod.charDelta}` : `${mod.charDelta}`;
        lines.push(`- **${mod.hookId}** (${mod.event}): ${mod.modification} [${delta} chars]`);
      }
    }
    lines.push('');

    // System prompt sections
    lines.push('## System Prompt Composition');
    lines.push(`Total: ${this.data.systemPrompt.totalCharCount} chars`);
    lines.push('');
    if (this.data.systemPrompt.sections.length > 0) {
      lines.push('| Section | Source | Chars |');
      lines.push('|---------|--------|-------|');
      for (const section of this.data.systemPrompt.sections) {
        lines.push(`| ${section.name} | ${section.source} | ${section.charCount} |`);
      }
    }
    lines.push('');

    return lines.join('\n');
  }

  /**
   * Get a compact summary string
   */
  toSummary(): string {
    const parts: string[] = [];

    parts.push(`Session ${this.data.session.id} (${this.data.session.type})`);
    parts.push(`${this.data.contextFiles.length} context files`);
    parts.push(`${this.data.handoffs.length} handoffs`);
    parts.push(`${this.data.tools.length} tools`);
    parts.push(`~${this.data.tokenEstimates.totalBaseTokens} base tokens`);

    return parts.join(' | ');
  }

  // ===========================================================================
  // Private Methods
  // ===========================================================================

  private updateTotalTokens(): void {
    this.data.tokenEstimates.totalBaseTokens =
      this.data.tokenEstimates.contextTokens +
      this.data.tokenEstimates.systemPromptTokens +
      this.data.tokenEstimates.toolTokens;
  }
}

// =============================================================================
// Singleton for Current Session
// =============================================================================

let currentAudit: ContextAudit | null = null;

/**
 * Get the current session's context audit
 */
export function getCurrentContextAudit(): ContextAudit | null {
  return currentAudit;
}

/**
 * Create a new context audit for a session
 */
export function createContextAudit(): ContextAudit {
  currentAudit = new ContextAudit();
  return currentAudit;
}

/**
 * Clear the current context audit
 */
export function clearContextAudit(): void {
  currentAudit = null;
}
