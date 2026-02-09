/**
 * @fileoverview Embedding Controller
 *
 * Manages the embedding service lifecycle and memory vector operations:
 * - Embedding service initialization (async, non-blocking)
 * - Memory vector backfilling for unembedded ledger events
 * - Workspace memory loading for session context injection
 * - Embedding service accessor for tool integration
 */
import { createLogger } from '@infrastructure/logging/index.js';
import { EmbeddingService, buildEmbeddingText } from '@infrastructure/embeddings/index.js';
import type { VectorRepository } from '@infrastructure/events/sqlite/repositories/vector.repo.js';
import type { EventStore } from '@infrastructure/events/event-store.js';
import type { EventType } from '@infrastructure/events/types.js';
import type { MemoryLedgerPayload } from '@infrastructure/events/types/memory.js';

const logger = createLogger('embedding-controller');

// =============================================================================
// Types
// =============================================================================

export interface EmbeddingControllerConfig {
  eventStore: EventStore;
}

// =============================================================================
// EmbeddingController
// =============================================================================

export class EmbeddingController {
  private embeddingService: EmbeddingService | null = null;
  private vectorRepo: VectorRepository | null = null;
  private eventStore: EventStore;

  constructor(config: EmbeddingControllerConfig) {
    this.eventStore = config.eventStore;
  }

  /**
   * Initialize embedding service and vector repository.
   * Non-blocking — server continues without waiting for model download.
   */
  async initialize(settings: {
    enabled: boolean;
    model?: string;
    dtype?: string;
    dimensions?: number;
    cacheDir?: string;
  }): Promise<void> {
    this.vectorRepo = this.eventStore.getVectorRepository();

    if (!settings.enabled || !this.vectorRepo) return;

    this.embeddingService = new EmbeddingService({
      modelId: settings.model,
      dtype: settings.dtype,
      dimensions: settings.dimensions,
      cacheDir: settings.cacheDir,
    });

    // Fire-and-forget init — don't block server start on model download
    this.embeddingService.initialize().then(() => {
      logger.info('Embedding service ready');
      this.backfillMemoryVectors().catch(err => {
        logger.warn('Memory vector backfill failed', { error: (err as Error).message });
      });
    }).catch(err => {
      logger.warn('Embedding service failed to initialize', { error: (err as Error).message });
      this.embeddingService = null;
    });
  }

  getEmbeddingService(): EmbeddingService | null {
    return this.embeddingService;
  }

  getVectorRepo(): VectorRepository | null {
    return this.vectorRepo;
  }

  /**
   * Load workspace memory entries for context injection.
   * Returns formatted markdown with lessons and decisions from recent sessions.
   */
  async loadWorkspaceMemory(
    workspacePath: string,
    options?: { count?: number }
  ): Promise<{ content: string; count: number; tokens: number } | undefined> {
    const workspace = await this.eventStore.getWorkspaceByPath(workspacePath);
    if (!workspace) return undefined;

    const count = Math.max(1, Math.min(options?.count ?? 5, 10));

    const ledgerEvents = await this.eventStore.getEventsByWorkspaceAndTypes(
      workspace.id,
      ['memory.ledger' as EventType],
      { limit: count }
    );

    if (ledgerEvents.length === 0) return undefined;

    // Events come back DESC, reverse for chronological display
    const entries = ledgerEvents.reverse().map(e => {
      const p = e.payload as unknown as MemoryLedgerPayload;
      const parts = [`### ${p.title}`];
      if (p.lessons?.length) parts.push(p.lessons.map(l => `- ${l}`).join('\n'));
      if (p.decisions?.length) parts.push(p.decisions.map(d => `- ${d.choice}: ${d.reason}`).join('\n'));
      return parts.join('\n');
    });

    const content = `# Memory\n\n## Recent sessions in this workspace\n\n${entries.join('\n\n')}`;
    const tokens = Math.ceil(content.length / 4);

    return { content, count: ledgerEvents.length, tokens };
  }

  /**
   * Embed a single memory ledger entry for semantic search.
   * Called by memory-ledger hook after writing a new entry.
   */
  async embedMemory(
    eventId: string,
    workspaceId: string,
    payload: Record<string, unknown>
  ): Promise<void> {
    if (!this.embeddingService?.isReady() || !this.vectorRepo) return;
    const text = buildEmbeddingText(payload as unknown as MemoryLedgerPayload);
    const embedding = await this.embeddingService.embedSingle(text);
    this.vectorRepo.store(eventId, workspaceId, embedding);
  }

  /**
   * Backfill vectors for memory.ledger events that don't have embeddings.
   * Called after embedding service initializes.
   */
  private async backfillMemoryVectors(): Promise<void> {
    if (!this.embeddingService?.isReady() || !this.vectorRepo) return;

    const db = this.eventStore.getDatabase();
    const unembedded = db.prepare(`
      SELECT e.id, e.workspace_id, e.payload
      FROM events e
      LEFT JOIN memory_vectors v ON e.id = v.event_id
      WHERE e.type = 'memory.ledger' AND v.event_id IS NULL
    `).all() as Array<{ id: string; workspace_id: string; payload: string }>;

    if (unembedded.length === 0) return;

    logger.info('Backfilling memory vectors', { count: unembedded.length });

    let embedded = 0;
    for (const event of unembedded) {
      try {
        const payload = JSON.parse(event.payload) as MemoryLedgerPayload;
        const text = buildEmbeddingText(payload);
        const embedding = await this.embeddingService.embedSingle(text);
        this.vectorRepo.store(event.id, event.workspace_id, embedding);
        embedded++;
      } catch (err) {
        logger.warn('Failed to embed memory event', {
          eventId: event.id,
          error: (err as Error).message,
        });
      }
    }

    logger.info('Memory vector backfill complete', { embedded, total: unembedded.length });
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createEmbeddingController(config: EmbeddingControllerConfig): EmbeddingController {
  return new EmbeddingController(config);
}
