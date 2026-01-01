/**
 * @fileoverview Inbox Types
 *
 * Type definitions for inbox monitoring connectors.
 */

// =============================================================================
// Core Types
// =============================================================================

export interface InboxItem {
  /** Unique identifier */
  id: string;
  /** Source connector name */
  source: string;
  /** Item type */
  type: 'email' | 'file' | 'note' | 'task' | 'other';
  /** Title or subject */
  title: string;
  /** Content or summary */
  content: string;
  /** When the item was received/created */
  receivedAt: string;
  /** Optional sender information */
  sender?: {
    name?: string;
    email?: string;
    id?: string;
  };
  /** Whether item has been processed */
  processed: boolean;
  /** When item was processed */
  processedAt?: string;
  /** Any attachments */
  attachments?: InboxAttachment[];
  /** Source-specific metadata */
  metadata?: Record<string, unknown>;
}

export interface InboxAttachment {
  id: string;
  name: string;
  mimeType: string;
  size: number;
  url?: string;
}

// =============================================================================
// Connector Interface
// =============================================================================

export interface InboxConnector {
  /** Connector name/identifier */
  readonly name: string;
  /** Human-readable description */
  readonly description: string;
  /** Whether connector is currently configured */
  isConfigured(): Promise<boolean>;
  /** Fetch new/unprocessed items */
  fetch(options?: FetchOptions): Promise<InboxItem[]>;
  /** Mark an item as processed */
  markProcessed(itemId: string): Promise<void>;
  /** Mark an item as unprocessed */
  markUnprocessed(itemId: string): Promise<void>;
  /** Archive an item (if supported) */
  archive?(itemId: string): Promise<void>;
  /** Delete an item (if supported) */
  delete?(itemId: string): Promise<void>;
  /** Get item content/details */
  getContent?(itemId: string): Promise<string>;
}

export interface FetchOptions {
  /** Maximum items to fetch */
  limit?: number;
  /** Whether to include processed items */
  includeProcessed?: boolean;
  /** Filter by item type */
  type?: InboxItem['type'];
  /** Only items after this date */
  after?: Date;
}

// =============================================================================
// Gmail Connector Types
// =============================================================================

export interface GmailConnectorConfig {
  /** OAuth credentials */
  credentials: {
    accessToken: string;
    refreshToken?: string;
    expiresAt?: number;
  };
  /** Labels to monitor (default: INBOX) */
  labels?: string[];
  /** Maximum emails per fetch */
  maxResults?: number;
}

// =============================================================================
// Folder Watcher Types
// =============================================================================

export interface FolderWatcherConfig {
  /** Path to folder to watch */
  path: string;
  /** File patterns to include (glob) */
  include?: string[];
  /** File patterns to exclude (glob) */
  exclude?: string[];
  /** Whether to watch subdirectories */
  recursive?: boolean;
  /** Polling interval in ms (for non-native watchers) */
  pollInterval?: number;
}

// =============================================================================
// Notion Connector Types
// =============================================================================

export interface NotionConnectorConfig {
  /** Notion integration token */
  token: string;
  /** Database ID to monitor */
  databaseId: string;
  /** Filter for unprocessed items */
  filter?: Record<string, unknown>;
}

// =============================================================================
// Obsidian Connector Types
// =============================================================================

export interface ObsidianConnectorConfig {
  /** Path to Obsidian vault */
  vaultPath: string;
  /** Inbox folder relative to vault */
  inboxFolder?: string;
  /** Archive folder relative to vault */
  archiveFolder?: string;
}

// =============================================================================
// Aggregator Types
// =============================================================================

export interface AggregatorConfig {
  /** Connectors to aggregate */
  connectors: InboxConnector[];
  /** Polling interval in ms */
  pollInterval?: number;
  /** Maximum total items */
  maxItems?: number;
}
