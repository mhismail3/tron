/**
 * @fileoverview Obsidian Vault Inbox Connector
 *
 * Monitors an Obsidian vault's inbox folder for new notes to process.
 * Integrates with Obsidian-style markdown files and supports frontmatter.
 *
 * @example
 * ```typescript
 * const connector = new ObsidianConnector({
 *   vaultPath: '/Users/me/Documents/MyVault',
 *   inboxFolder: 'Inbox',
 *   archiveFolder: 'Archive/Processed',
 * });
 *
 * const items = await connector.fetch();
 * ```
 */
import * as fs from 'fs/promises';
import * as path from 'path';
import { createLogger } from '../../logging/index.js';
import type {
  InboxConnector,
  InboxItem,
  FetchOptions,
  ObsidianConnectorConfig,
} from './types.js';

const logger = createLogger('inbox:obsidian');

// =============================================================================
// Constants
// =============================================================================

const DEFAULT_INBOX_FOLDER = 'Inbox';
const DEFAULT_ARCHIVE_FOLDER = 'Archive/Processed';
const PROCESSED_FILE = '.inbox-processed.json';
const MARKDOWN_EXTENSIONS = ['.md', '.markdown'];

// =============================================================================
// Frontmatter Parser
// =============================================================================

interface ObsidianFrontmatter {
  title?: string;
  tags?: string[];
  created?: string;
  processed?: boolean;
  source?: string;
  [key: string]: unknown;
}

function parseFrontmatter(content: string): {
  frontmatter: ObsidianFrontmatter;
  body: string;
} {
  const frontmatterRegex = /^---\n([\s\S]*?)\n---\n([\s\S]*)$/;
  const match = content.match(frontmatterRegex);

  if (!match || !match[1] || !match[2]) {
    return { frontmatter: {}, body: content };
  }

  const frontmatter: ObsidianFrontmatter = {};
  const lines = match[1].split('\n');

  for (const line of lines) {
    const colonIndex = line.indexOf(':');
    if (colonIndex > 0) {
      const key = line.slice(0, colonIndex).trim();
      let value: string | string[] | boolean = line.slice(colonIndex + 1).trim();

      // Parse arrays (Obsidian uses [item1, item2] or - item format)
      if (value.startsWith('[') && value.endsWith(']')) {
        value = value.slice(1, -1).split(',').map(s => s.trim());
      }

      // Parse booleans
      if (value === 'true') value = true as unknown as string;
      if (value === 'false') value = false as unknown as string;

      frontmatter[key] = value;
    }
  }

  return { frontmatter, body: match[2] };
}

// =============================================================================
// Obsidian Connector Implementation
// =============================================================================

export class ObsidianConnector implements InboxConnector {
  readonly name = 'obsidian';
  readonly description = 'Obsidian vault inbox monitor';

  private config: Required<ObsidianConnectorConfig>;
  private processedFile: string;
  private processedIds: Set<string> = new Set();
  private initialized = false;

  constructor(config: ObsidianConnectorConfig) {
    this.config = {
      inboxFolder: DEFAULT_INBOX_FOLDER,
      archiveFolder: DEFAULT_ARCHIVE_FOLDER,
      ...config,
    };
    this.processedFile = path.join(
      this.config.vaultPath,
      this.config.inboxFolder,
      PROCESSED_FILE
    );
  }

  /**
   * Check if the vault and inbox folder exist
   */
  async isConfigured(): Promise<boolean> {
    try {
      const inboxPath = path.join(this.config.vaultPath, this.config.inboxFolder);
      await fs.access(inboxPath, fs.constants.R_OK);
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Initialize by loading processed IDs
   */
  private async initialize(): Promise<void> {
    if (this.initialized) return;

    try {
      const content = await fs.readFile(this.processedFile, 'utf-8');
      const data = JSON.parse(content);
      this.processedIds = new Set(data.processed || []);
    } catch {
      this.processedIds = new Set();
    }

    this.initialized = true;
  }

  /**
   * Fetch items from the inbox folder
   */
  async fetch(options: FetchOptions = {}): Promise<InboxItem[]> {
    await this.initialize();

    const inboxPath = path.join(this.config.vaultPath, this.config.inboxFolder);
    const items: InboxItem[] = [];
    const limit = options.limit ?? 50;

    try {
      const files = await this.listMarkdownFiles(inboxPath);

      for (const filePath of files) {
        if (items.length >= limit) break;

        const fileId = this.getFileId(filePath);

        // Skip processed unless requested
        if (this.processedIds.has(fileId) && !options.includeProcessed) {
          continue;
        }

        // Skip hidden and processed files
        const fileName = path.basename(filePath);
        if (fileName.startsWith('.')) continue;

        try {
          const stats = await fs.stat(filePath);

          // Skip if before 'after' date
          if (options.after && stats.mtime < options.after) {
            continue;
          }

          // Read and parse the file
          const content = await fs.readFile(filePath, 'utf-8');
          const { frontmatter, body } = parseFrontmatter(content);

          // Skip if marked as processed in frontmatter
          if (frontmatter.processed && !options.includeProcessed) {
            continue;
          }

          const item: InboxItem = {
            id: fileId,
            source: this.name,
            type: 'note',
            title: frontmatter.title || path.basename(filePath, '.md'),
            content: body.trim().slice(0, 1000), // Preview
            receivedAt: (frontmatter.created || stats.mtime.toISOString()),
            processed: this.processedIds.has(fileId) || !!frontmatter.processed,
            processedAt: this.processedIds.has(fileId) ? new Date().toISOString() : undefined,
            metadata: {
              path: filePath,
              relativePath: path.relative(this.config.vaultPath, filePath),
              frontmatter,
              tags: frontmatter.tags || [],
              wordCount: body.split(/\s+/).length,
            },
          };

          items.push(item);
        } catch (error) {
          logger.warn('Error reading file', { filePath, error });
        }
      }
    } catch (error) {
      logger.error('Error fetching from inbox', { error });
    }

    // Sort by date (newest first)
    items.sort((a, b) => {
      const dateA = new Date(a.receivedAt);
      const dateB = new Date(b.receivedAt);
      return dateB.getTime() - dateA.getTime();
    });

    return items;
  }

  /**
   * Mark an item as processed
   */
  async markProcessed(itemId: string): Promise<void> {
    this.processedIds.add(itemId);
    await this.saveProcessed();

    // Optionally update frontmatter
    const filePath = this.getFilePath(itemId);
    if (filePath) {
      await this.updateFrontmatter(filePath, { processed: true });
    }

    logger.debug('Item marked as processed', { itemId });
  }

  /**
   * Mark an item as unprocessed
   */
  async markUnprocessed(itemId: string): Promise<void> {
    this.processedIds.delete(itemId);
    await this.saveProcessed();

    const filePath = this.getFilePath(itemId);
    if (filePath) {
      await this.updateFrontmatter(filePath, { processed: false });
    }

    logger.debug('Item marked as unprocessed', { itemId });
  }

  /**
   * Archive an item by moving it to the archive folder
   */
  async archive(itemId: string): Promise<void> {
    const filePath = this.getFilePath(itemId);
    if (!filePath) return;

    const archivePath = path.join(
      this.config.vaultPath,
      this.config.archiveFolder
    );

    // Ensure archive folder exists
    await fs.mkdir(archivePath, { recursive: true });

    // Generate unique archive filename
    const baseName = path.basename(filePath);
    const timestamp = new Date().toISOString().slice(0, 10);
    const archiveFile = path.join(archivePath, `${timestamp}_${baseName}`);

    // Move file
    await fs.rename(filePath, archiveFile);

    // Update tracking
    this.processedIds.delete(itemId);
    await this.saveProcessed();

    logger.info('Item archived', { itemId, archivePath: archiveFile });
  }

  /**
   * Delete an item
   */
  async delete(itemId: string): Promise<void> {
    const filePath = this.getFilePath(itemId);
    if (!filePath) return;

    // Move to vault trash (Obsidian convention)
    const trashPath = path.join(this.config.vaultPath, '.trash');
    await fs.mkdir(trashPath, { recursive: true });

    const trashFile = path.join(trashPath, path.basename(filePath));
    await fs.rename(filePath, trashFile);

    this.processedIds.delete(itemId);
    await this.saveProcessed();

    logger.info('Item moved to trash', { itemId });
  }

  /**
   * Get full content of an item
   */
  async getContent(itemId: string): Promise<string> {
    const filePath = this.getFilePath(itemId);
    if (!filePath) {
      throw new Error(`Item not found: ${itemId}`);
    }

    const content = await fs.readFile(filePath, 'utf-8');
    const { body } = parseFrontmatter(content);
    return body;
  }

  /**
   * Create a new note in the inbox
   */
  async createNote(options: {
    title: string;
    content: string;
    tags?: string[];
    metadata?: Record<string, unknown>;
  }): Promise<string> {
    const inboxPath = path.join(this.config.vaultPath, this.config.inboxFolder);
    await fs.mkdir(inboxPath, { recursive: true });

    const fileName = this.sanitizeFileName(options.title) + '.md';
    const filePath = path.join(inboxPath, fileName);

    // Build frontmatter
    const frontmatter = [
      '---',
      `title: ${options.title}`,
      `created: ${new Date().toISOString()}`,
    ];

    if (options.tags && options.tags.length > 0) {
      frontmatter.push(`tags: [${options.tags.join(', ')}]`);
    }

    if (options.metadata) {
      for (const [key, value] of Object.entries(options.metadata)) {
        frontmatter.push(`${key}: ${JSON.stringify(value)}`);
      }
    }

    frontmatter.push('---', '', options.content);

    await fs.writeFile(filePath, frontmatter.join('\n'), 'utf-8');

    logger.info('Note created', { title: options.title, path: filePath });

    return this.getFileId(filePath);
  }

  // =============================================================================
  // Private Methods
  // =============================================================================

  /**
   * List all markdown files in a directory
   */
  private async listMarkdownFiles(dir: string): Promise<string[]> {
    const files: string[] = [];

    try {
      const entries = await fs.readdir(dir, { withFileTypes: true });

      for (const entry of entries) {
        const fullPath = path.join(dir, entry.name);

        if (entry.isFile() && MARKDOWN_EXTENSIONS.includes(path.extname(entry.name).toLowerCase())) {
          files.push(fullPath);
        }
      }
    } catch {
      // Directory doesn't exist
    }

    return files;
  }

  /**
   * Generate a file ID from path
   */
  private getFileId(filePath: string): string {
    const relative = path.relative(
      path.join(this.config.vaultPath, this.config.inboxFolder),
      filePath
    );
    return Buffer.from(relative).toString('base64url');
  }

  /**
   * Get file path from ID
   */
  private getFilePath(itemId: string): string | null {
    try {
      const relative = Buffer.from(itemId, 'base64url').toString('utf-8');
      return path.join(this.config.vaultPath, this.config.inboxFolder, relative);
    } catch {
      return null;
    }
  }

  /**
   * Save processed IDs to disk
   */
  private async saveProcessed(): Promise<void> {
    const data = {
      processed: Array.from(this.processedIds),
      updatedAt: new Date().toISOString(),
    };
    await fs.writeFile(this.processedFile, JSON.stringify(data, null, 2), 'utf-8');
  }

  /**
   * Update frontmatter in a file
   */
  private async updateFrontmatter(
    filePath: string,
    updates: Record<string, unknown>
  ): Promise<void> {
    try {
      const content = await fs.readFile(filePath, 'utf-8');
      const { frontmatter, body } = parseFrontmatter(content);

      Object.assign(frontmatter, updates);

      const newFrontmatter = ['---'];
      for (const [key, value] of Object.entries(frontmatter)) {
        if (Array.isArray(value)) {
          newFrontmatter.push(`${key}: [${value.join(', ')}]`);
        } else {
          newFrontmatter.push(`${key}: ${value}`);
        }
      }
      newFrontmatter.push('---', '');

      await fs.writeFile(filePath, newFrontmatter.join('\n') + body, 'utf-8');
    } catch (error) {
      logger.warn('Failed to update frontmatter', { filePath, error });
    }
  }

  /**
   * Sanitize a string for use as filename
   */
  private sanitizeFileName(name: string): string {
    return name
      .replace(/[<>:"/\\|?*]/g, '')
      .replace(/\s+/g, '-')
      .slice(0, 100);
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createObsidianConnector(
  config: ObsidianConnectorConfig
): ObsidianConnector {
  return new ObsidianConnector(config);
}
