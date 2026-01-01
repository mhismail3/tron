/**
 * @fileoverview Folder Watcher Inbox Connector
 *
 * Monitors a local folder for new files.
 */
import * as fs from 'fs/promises';
import * as path from 'path';
import { createLogger } from '../../logging/index.js';
import type {
  InboxConnector,
  InboxItem,
  FetchOptions,
  FolderWatcherConfig,
} from './types.js';

const logger = createLogger('inbox:folder');

// =============================================================================
// Folder Watcher Implementation
// =============================================================================

export class FolderWatcherConnector implements InboxConnector {
  readonly name = 'folder';
  readonly description = 'Local folder watcher';

  private config: FolderWatcherConfig;
  private processedFile: string;
  private processedIds: Set<string> = new Set();

  constructor(config: FolderWatcherConfig) {
    this.config = {
      include: ['*'],
      exclude: ['.*', '*.tmp', '*.bak'],
      recursive: false,
      pollInterval: 30000,
      ...config,
    };
    this.processedFile = path.join(config.path, '.inbox-processed.json');
  }

  async isConfigured(): Promise<boolean> {
    try {
      await fs.access(this.config.path, fs.constants.R_OK);
      return true;
    } catch {
      return false;
    }
  }

  async initialize(): Promise<void> {
    // Load processed IDs
    try {
      const content = await fs.readFile(this.processedFile, 'utf-8');
      const data = JSON.parse(content);
      this.processedIds = new Set(data.processed || []);
    } catch {
      // File doesn't exist yet
      this.processedIds = new Set();
    }
  }

  async fetch(options: FetchOptions = {}): Promise<InboxItem[]> {
    await this.initialize();

    const items: InboxItem[] = [];
    const limit = options.limit ?? 50;

    const files = await this.listFiles(this.config.path, this.config.recursive ?? false);

    for (const filePath of files) {
      if (items.length >= limit) break;

      const fileId = this.getFileId(filePath);

      // Skip processed unless requested
      if (this.processedIds.has(fileId) && !options.includeProcessed) {
        continue;
      }

      // Skip excluded patterns
      const fileName = path.basename(filePath);
      if (this.shouldExclude(fileName)) {
        continue;
      }

      try {
        const stats = await fs.stat(filePath);

        // Skip if before 'after' date
        if (options.after && stats.mtime < options.after) {
          continue;
        }

        const item: InboxItem = {
          id: fileId,
          source: this.name,
          type: this.getFileType(filePath),
          title: fileName,
          content: `File: ${filePath}`,
          receivedAt: stats.mtime.toISOString(),
          processed: this.processedIds.has(fileId),
          processedAt: this.processedIds.has(fileId) ? new Date().toISOString() : undefined,
          metadata: {
            path: filePath,
            size: stats.size,
            extension: path.extname(filePath),
          },
        };

        items.push(item);
      } catch (error) {
        logger.warn('Error reading file', { filePath, error });
      }
    }

    return items;
  }

  async markProcessed(itemId: string): Promise<void> {
    this.processedIds.add(itemId);
    await this.saveProcessed();
    logger.debug('Item marked as processed', { itemId });
  }

  async markUnprocessed(itemId: string): Promise<void> {
    this.processedIds.delete(itemId);
    await this.saveProcessed();
    logger.debug('Item marked as unprocessed', { itemId });
  }

  async archive(itemId: string): Promise<void> {
    // Move to archive folder if specified
    const archiveDir = path.join(this.config.path, 'archive');
    await fs.mkdir(archiveDir, { recursive: true });

    const filePath = this.getFilePath(itemId);
    if (!filePath) return;

    const archivePath = path.join(archiveDir, path.basename(filePath));
    await fs.rename(filePath, archivePath);

    this.processedIds.delete(itemId);
    await this.saveProcessed();
    logger.info('Item archived', { itemId, archivePath });
  }

  async delete(itemId: string): Promise<void> {
    const filePath = this.getFilePath(itemId);
    if (!filePath) return;

    await fs.unlink(filePath);
    this.processedIds.delete(itemId);
    await this.saveProcessed();
    logger.info('Item deleted', { itemId });
  }

  async getContent(itemId: string): Promise<string> {
    const filePath = this.getFilePath(itemId);
    if (!filePath) {
      throw new Error(`File not found: ${itemId}`);
    }

    const ext = path.extname(filePath).toLowerCase();

    // Only read text files
    const textExtensions = ['.txt', '.md', '.json', '.yaml', '.yml', '.xml', '.csv', '.log'];
    if (!textExtensions.includes(ext)) {
      return `[Binary file: ${path.basename(filePath)}]`;
    }

    const content = await fs.readFile(filePath, 'utf-8');
    return content;
  }

  // =============================================================================
  // Private Methods
  // =============================================================================

  private async listFiles(dir: string, recursive: boolean): Promise<string[]> {
    const files: string[] = [];
    const entries = await fs.readdir(dir, { withFileTypes: true });

    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);

      if (entry.isFile()) {
        files.push(fullPath);
      } else if (entry.isDirectory() && recursive && !entry.name.startsWith('.')) {
        const subFiles = await this.listFiles(fullPath, true);
        files.push(...subFiles);
      }
    }

    return files;
  }

  private getFileId(filePath: string): string {
    const relative = path.relative(this.config.path, filePath);
    return Buffer.from(relative).toString('base64url');
  }

  private getFilePath(itemId: string): string | null {
    try {
      const relative = Buffer.from(itemId, 'base64url').toString('utf-8');
      return path.join(this.config.path, relative);
    } catch {
      return null;
    }
  }

  private shouldExclude(fileName: string): boolean {
    for (const pattern of this.config.exclude || []) {
      if (this.matchPattern(fileName, pattern)) {
        return true;
      }
    }
    return false;
  }

  private matchPattern(name: string, pattern: string): boolean {
    // Simple glob matching
    if (pattern === '*') return true;
    if (pattern.startsWith('*.')) {
      return name.endsWith(pattern.slice(1));
    }
    if (pattern.startsWith('.')) {
      return name.startsWith('.');
    }
    return name === pattern;
  }

  private getFileType(filePath: string): InboxItem['type'] {
    const ext = path.extname(filePath).toLowerCase();

    if (['.md', '.txt', '.note'].includes(ext)) {
      return 'note';
    }
    if (['.eml', '.msg'].includes(ext)) {
      return 'email';
    }
    if (['.todo', '.task'].includes(ext)) {
      return 'task';
    }

    return 'file';
  }

  private async saveProcessed(): Promise<void> {
    const data = {
      processed: Array.from(this.processedIds),
      updatedAt: new Date().toISOString(),
    };
    await fs.writeFile(this.processedFile, JSON.stringify(data, null, 2), 'utf-8');
  }
}
