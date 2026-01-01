/**
 * @fileoverview Inbox Aggregator
 *
 * Aggregates items from multiple inbox connectors.
 */
import { createLogger } from '../../logging/index.js';
import type {
  InboxConnector,
  InboxItem,
  FetchOptions,
  AggregatorConfig,
} from './types.js';

const logger = createLogger('inbox:aggregator');

// =============================================================================
// Aggregator Implementation
// =============================================================================

export class InboxAggregator implements InboxConnector {
  readonly name = 'aggregator';
  readonly description = 'Multi-source inbox aggregator';

  private connectors: InboxConnector[];
  private maxItems: number;

  constructor(config: AggregatorConfig) {
    this.connectors = config.connectors;
    this.maxItems = config.maxItems ?? 100;
  }

  async isConfigured(): Promise<boolean> {
    // Configured if at least one connector is configured
    for (const connector of this.connectors) {
      if (await connector.isConfigured()) {
        return true;
      }
    }
    return false;
  }

  /**
   * Fetch items from all configured connectors
   */
  async fetch(options: FetchOptions = {}): Promise<InboxItem[]> {
    const allItems: InboxItem[] = [];
    const limit = Math.min(options.limit ?? this.maxItems, this.maxItems);

    // Fetch from each connector in parallel
    const fetchPromises = this.connectors.map(async (connector) => {
      try {
        if (await connector.isConfigured()) {
          const items = await connector.fetch({
            ...options,
            limit: Math.ceil(limit / this.connectors.length),
          });
          return items;
        }
        return [];
      } catch (error) {
        logger.warn('Error fetching from connector', {
          connector: connector.name,
          error,
        });
        return [];
      }
    });

    const results = await Promise.all(fetchPromises);

    for (const items of results) {
      allItems.push(...items);
    }

    // Sort by received date (newest first)
    allItems.sort((a, b) => {
      const dateA = new Date(a.receivedAt);
      const dateB = new Date(b.receivedAt);
      return dateB.getTime() - dateA.getTime();
    });

    // Apply limit
    return allItems.slice(0, limit);
  }

  /**
   * Fetch items from all connectors grouped by source
   */
  async fetchGrouped(): Promise<Map<string, InboxItem[]>> {
    const grouped = new Map<string, InboxItem[]>();

    for (const connector of this.connectors) {
      try {
        if (await connector.isConfigured()) {
          const items = await connector.fetch();
          grouped.set(connector.name, items);
        }
      } catch (error) {
        logger.warn('Error fetching from connector', {
          connector: connector.name,
          error,
        });
        grouped.set(connector.name, []);
      }
    }

    return grouped;
  }

  /**
   * Mark item as processed (routes to correct connector)
   */
  async markProcessed(itemId: string): Promise<void> {
    const connector = await this.findConnectorForItem(itemId);
    if (connector) {
      await connector.markProcessed(itemId);
    }
  }

  /**
   * Mark item as unprocessed (routes to correct connector)
   */
  async markUnprocessed(itemId: string): Promise<void> {
    const connector = await this.findConnectorForItem(itemId);
    if (connector) {
      await connector.markUnprocessed(itemId);
    }
  }

  /**
   * Archive item (routes to correct connector)
   */
  async archive(itemId: string): Promise<void> {
    const connector = await this.findConnectorForItem(itemId);
    if (connector?.archive) {
      await connector.archive(itemId);
    }
  }

  /**
   * Delete item (routes to correct connector)
   */
  async delete(itemId: string): Promise<void> {
    const connector = await this.findConnectorForItem(itemId);
    if (connector?.delete) {
      await connector.delete(itemId);
    }
  }

  /**
   * Get item content (routes to correct connector)
   */
  async getContent(itemId: string): Promise<string> {
    const connector = await this.findConnectorForItem(itemId);
    if (connector?.getContent) {
      return connector.getContent(itemId);
    }
    throw new Error(`Item not found: ${itemId}`);
  }

  /**
   * Get statistics about inbox items
   */
  async getStats(): Promise<{
    total: number;
    unprocessed: number;
    bySource: Record<string, { total: number; unprocessed: number }>;
    byType: Record<string, number>;
  }> {
    const allItems = await this.fetch({ includeProcessed: true, limit: 1000 });

    const stats = {
      total: allItems.length,
      unprocessed: allItems.filter(i => !i.processed).length,
      bySource: {} as Record<string, { total: number; unprocessed: number }>,
      byType: {} as Record<string, number>,
    };

    for (const item of allItems) {
      // By source
      const source = stats.bySource[item.source] ?? { total: 0, unprocessed: 0 };
      stats.bySource[item.source] = source;
      source.total++;
      if (!item.processed) {
        source.unprocessed++;
      }

      // By type
      stats.byType[item.type] = (stats.byType[item.type] || 0) + 1;
    }

    return stats;
  }

  /**
   * Add a connector
   */
  addConnector(connector: InboxConnector): void {
    this.connectors.push(connector);
    logger.info('Connector added', { name: connector.name });
  }

  /**
   * Remove a connector
   */
  removeConnector(name: string): boolean {
    const index = this.connectors.findIndex(c => c.name === name);
    if (index !== -1) {
      this.connectors.splice(index, 1);
      logger.info('Connector removed', { name });
      return true;
    }
    return false;
  }

  /**
   * Get all connectors
   */
  getConnectors(): InboxConnector[] {
    return [...this.connectors];
  }

  // =============================================================================
  // Private Methods
  // =============================================================================

  private async findConnectorForItem(itemId: string): Promise<InboxConnector | null> {
    // Try to find the item in each connector
    for (const connector of this.connectors) {
      try {
        const items = await connector.fetch({ includeProcessed: true });
        if (items.some(i => i.id === itemId)) {
          return connector;
        }
      } catch {
        // Ignore errors when searching
      }
    }
    return null;
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createAggregator(connectors: InboxConnector[]): InboxAggregator {
  return new InboxAggregator({ connectors });
}
