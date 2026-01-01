/**
 * @fileoverview Notes Integration Module
 *
 * Provides integration with a designated notes folder for:
 * - Full-text search across notes
 * - PDF text extraction
 * - Image support
 * - Obsidian-compatible markdown
 * - Cross-reference linking
 *
 * @example
 * ```typescript
 * const notesManager = new NotesManager({
 *   notesDir: '/Users/me/Documents/Notes',
 *   includeHidden: false,
 * });
 *
 * await notesManager.initialize();
 * const results = await notesManager.search('project planning');
 * ```
 */
import * as fs from 'fs/promises';
import * as path from 'path';
import Database from 'better-sqlite3';
import { createLogger } from '../logging/index.js';

const logger = createLogger('notes');

// =============================================================================
// Types
// =============================================================================

export interface NotesManagerConfig {
  /** Path to notes directory */
  notesDir: string;
  /** Path to FTS database (defaults to .notes-index.db in notesDir) */
  dbPath?: string;
  /** Include hidden files/folders */
  includeHidden?: boolean;
  /** File extensions to index */
  extensions?: string[];
  /** Folders to exclude from indexing */
  excludeFolders?: string[];
}

export interface Note {
  id: string;
  path: string;
  relativePath: string;
  title: string;
  content: string;
  excerpt: string;
  tags: string[];
  links: string[];
  backlinks: string[];
  createdAt: string;
  modifiedAt: string;
  wordCount: number;
  type: 'markdown' | 'pdf' | 'text' | 'image';
  metadata?: Record<string, unknown>;
}

export interface NoteSearchResult {
  note: Note;
  score: number;
  highlights: string[];
}

export interface NoteStats {
  totalNotes: number;
  byType: Record<string, number>;
  byFolder: Record<string, number>;
  totalWords: number;
  lastIndexed: string;
}

// =============================================================================
// Frontmatter Parser
// =============================================================================

interface NoteFrontmatter {
  title?: string;
  tags?: string[];
  created?: string;
  aliases?: string[];
  [key: string]: unknown;
}

function parseFrontmatter(content: string): {
  frontmatter: NoteFrontmatter;
  body: string;
} {
  const frontmatterRegex = /^---\n([\s\S]*?)\n---\n([\s\S]*)$/;
  const match = content.match(frontmatterRegex);

  if (!match || !match[1]) {
    return { frontmatter: {}, body: content };
  }

  const frontmatter: NoteFrontmatter = {};
  const lines = match[1].split('\n');

  for (const line of lines) {
    const colonIndex = line.indexOf(':');
    if (colonIndex > 0) {
      const key = line.slice(0, colonIndex).trim();
      let value: string | string[] = line.slice(colonIndex + 1).trim();

      // Parse arrays
      if (value.startsWith('[') && value.endsWith(']')) {
        value = value.slice(1, -1).split(',').map(s => s.trim().replace(/"/g, ''));
      }

      frontmatter[key] = value;
    }
  }

  return { frontmatter, body: match[2] || content };
}

// =============================================================================
// Link Extractor
// =============================================================================

function extractLinks(content: string): string[] {
  const links: string[] = [];

  // Obsidian-style wiki links: [[note]] or [[note|alias]]
  const wikiLinkRegex = /\[\[([^\]|]+)(?:\|[^\]]+)?\]\]/g;
  let match;
  while ((match = wikiLinkRegex.exec(content)) !== null) {
    if (match[1]) links.push(match[1]);
  }

  // Markdown links: [text](path)
  const mdLinkRegex = /\[([^\]]+)\]\(([^)]+\.md)\)/g;
  while ((match = mdLinkRegex.exec(content)) !== null) {
    if (match[2]) links.push(match[2]);
  }

  return [...new Set(links)];
}

function extractTags(content: string): string[] {
  const tags: string[] = [];

  // Hashtag-style tags: #tag or #nested/tag
  const tagRegex = /#([\w\/-]+)/g;
  let match;
  while ((match = tagRegex.exec(content)) !== null) {
    if (match[1]) tags.push(match[1]);
  }

  return [...new Set(tags)];
}

// =============================================================================
// Notes Manager Implementation
// =============================================================================

export class NotesManager {
  private config: Required<NotesManagerConfig>;
  private db!: Database.Database;
  private initialized = false;

  constructor(config: NotesManagerConfig) {
    this.config = {
      dbPath: path.join(config.notesDir, '.notes-index.db'),
      includeHidden: false,
      extensions: ['.md', '.markdown', '.txt', '.pdf'],
      excludeFolders: ['.git', '.obsidian', 'node_modules', '.trash'],
      ...config,
    };
  }

  /**
   * Initialize the notes manager and FTS database
   */
  async initialize(): Promise<void> {
    if (this.initialized) return;

    // Ensure notes directory exists
    await fs.mkdir(this.config.notesDir, { recursive: true });

    // Initialize database
    this.db = new Database(this.config.dbPath);
    this.db.pragma('journal_mode = WAL');

    // Create tables
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS notes (
        id TEXT PRIMARY KEY,
        path TEXT NOT NULL UNIQUE,
        relative_path TEXT NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        excerpt TEXT,
        tags TEXT,
        links TEXT,
        created_at TEXT NOT NULL,
        modified_at TEXT NOT NULL,
        word_count INTEGER DEFAULT 0,
        type TEXT DEFAULT 'markdown',
        metadata TEXT
      );

      CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
        title,
        content,
        tags,
        content='notes',
        content_rowid='rowid'
      );

      CREATE TRIGGER IF NOT EXISTS notes_ai AFTER INSERT ON notes BEGIN
        INSERT INTO notes_fts(rowid, title, content, tags)
        VALUES (new.rowid, new.title, new.content, new.tags);
      END;

      CREATE TRIGGER IF NOT EXISTS notes_ad AFTER DELETE ON notes BEGIN
        INSERT INTO notes_fts(notes_fts, rowid, title, content, tags)
        VALUES('delete', old.rowid, old.title, old.content, old.tags);
      END;

      CREATE TRIGGER IF NOT EXISTS notes_au AFTER UPDATE ON notes BEGIN
        INSERT INTO notes_fts(notes_fts, rowid, title, content, tags)
        VALUES('delete', old.rowid, old.title, old.content, old.tags);
        INSERT INTO notes_fts(rowid, title, content, tags)
        VALUES (new.rowid, new.title, new.content, new.tags);
      END;

      CREATE TABLE IF NOT EXISTS backlinks (
        source_id TEXT NOT NULL,
        target_id TEXT NOT NULL,
        PRIMARY KEY (source_id, target_id),
        FOREIGN KEY (source_id) REFERENCES notes(id),
        FOREIGN KEY (target_id) REFERENCES notes(id)
      );

      CREATE INDEX IF NOT EXISTS idx_notes_path ON notes(path);
      CREATE INDEX IF NOT EXISTS idx_notes_type ON notes(type);
      CREATE INDEX IF NOT EXISTS idx_backlinks_target ON backlinks(target_id);
    `);

    this.initialized = true;
    logger.info('Notes manager initialized', { notesDir: this.config.notesDir });
  }

  /**
   * Index all notes in the directory
   */
  async reindex(): Promise<{ indexed: number; errors: number }> {
    await this.initialize();

    let indexed = 0;
    let errors = 0;

    // Clear existing data
    this.db.exec('DELETE FROM backlinks');
    this.db.exec('DELETE FROM notes');

    // Walk directory
    const files = await this.walkDirectory(this.config.notesDir);

    for (const filePath of files) {
      try {
        await this.indexFile(filePath);
        indexed++;
      } catch (error) {
        logger.warn('Error indexing file', { path: filePath, error });
        errors++;
      }
    }

    // Build backlinks
    await this.buildBacklinks();

    logger.info('Reindexing complete', { indexed, errors });
    return { indexed, errors };
  }

  /**
   * Index a single file
   */
  async indexFile(filePath: string): Promise<string> {
    await this.initialize();

    const stats = await fs.stat(filePath);
    const relativePath = path.relative(this.config.notesDir, filePath);
    const ext = path.extname(filePath).toLowerCase();

    let content: string;
    let title: string;
    let tags: string[] = [];
    let links: string[] = [];
    let type: Note['type'] = 'text';
    let metadata: Record<string, unknown> = {};

    // Read and parse based on type
    if (ext === '.md' || ext === '.markdown') {
      type = 'markdown';
      const raw = await fs.readFile(filePath, 'utf-8');
      const { frontmatter, body } = parseFrontmatter(raw);

      content = body;
      title = frontmatter.title || path.basename(filePath, ext);
      tags = [...(frontmatter.tags || []), ...extractTags(body)];
      links = extractLinks(body);
      metadata = frontmatter;
    } else if (ext === '.pdf') {
      type = 'pdf';
      // PDF extraction would require a library like pdf-parse
      // For now, just index metadata
      content = `[PDF Document: ${path.basename(filePath)}]`;
      title = path.basename(filePath, ext);
    } else if (['.png', '.jpg', '.jpeg', '.gif', '.webp'].includes(ext)) {
      type = 'image';
      content = `[Image: ${path.basename(filePath)}]`;
      title = path.basename(filePath, ext);
    } else {
      content = await fs.readFile(filePath, 'utf-8');
      title = path.basename(filePath, ext);
    }

    const id = this.generateId(relativePath);
    const excerpt = content.slice(0, 300).replace(/\n/g, ' ').trim();
    const wordCount = content.split(/\s+/).filter(w => w.length > 0).length;

    // Upsert into database
    const stmt = this.db.prepare(`
      INSERT OR REPLACE INTO notes (id, path, relative_path, title, content, excerpt, tags, links, created_at, modified_at, word_count, type, metadata)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);

    stmt.run(
      id,
      filePath,
      relativePath,
      title,
      content,
      excerpt,
      JSON.stringify(tags),
      JSON.stringify(links),
      stats.birthtime.toISOString(),
      stats.mtime.toISOString(),
      wordCount,
      type,
      JSON.stringify(metadata)
    );

    return id;
  }

  /**
   * Search notes using FTS
   */
  async search(query: string, options?: { limit?: number; type?: string }): Promise<NoteSearchResult[]> {
    await this.initialize();

    const limit = options?.limit ?? 20;

    // Build FTS query
    const ftsQuery = query
      .split(/\s+/)
      .map(term => `"${term}"*`)
      .join(' OR ');

    let sql = `
      SELECT n.*, bm25(notes_fts) as score
      FROM notes_fts fts
      JOIN notes n ON fts.rowid = n.rowid
      WHERE notes_fts MATCH ?
    `;

    const params: (string | number)[] = [ftsQuery];

    if (options?.type) {
      sql += ` AND n.type = ?`;
      params.push(options.type);
    }

    sql += ` ORDER BY score LIMIT ?`;
    params.push(limit);

    const rows = this.db.prepare(sql).all(...params) as Array<{
      score: number;
      id: string;
      path: string;
      relative_path: string;
      title: string;
      content: string;
      excerpt: string;
      tags: string;
      links: string;
      created_at: string;
      modified_at: string;
      word_count: number;
      type: string;
      metadata: string;
    }>;

    return rows.map(row => ({
      note: this.deserializeNote(row),
      score: Math.abs(row.score),
      highlights: this.extractHighlights(row.content, query),
    }));
  }

  /**
   * Get a note by ID
   */
  async get(id: string): Promise<Note | null> {
    await this.initialize();

    const row = this.db.prepare('SELECT * FROM notes WHERE id = ?').get(id) as {
      id: string;
      path: string;
      relative_path: string;
      title: string;
      content: string;
      excerpt: string;
      tags: string;
      links: string;
      created_at: string;
      modified_at: string;
      word_count: number;
      type: string;
      metadata: string;
    } | undefined;

    if (!row) return null;

    const note = this.deserializeNote(row);

    // Get backlinks
    const backlinks = this.db.prepare(
      'SELECT source_id FROM backlinks WHERE target_id = ?'
    ).all(id) as Array<{ source_id: string }>;

    note.backlinks = backlinks.map(b => b.source_id);

    return note;
  }

  /**
   * Get a note by path
   */
  async getByPath(filePath: string): Promise<Note | null> {
    await this.initialize();

    const absolutePath = path.isAbsolute(filePath)
      ? filePath
      : path.join(this.config.notesDir, filePath);

    const row = this.db.prepare('SELECT * FROM notes WHERE path = ?').get(absolutePath);

    if (!row) return null;

    return this.deserializeNote(row as {
      id: string;
      path: string;
      relative_path: string;
      title: string;
      content: string;
      excerpt: string;
      tags: string;
      links: string;
      created_at: string;
      modified_at: string;
      word_count: number;
      type: string;
      metadata: string;
    });
  }

  /**
   * Get all notes in a folder
   */
  async getFolder(folder: string): Promise<Note[]> {
    await this.initialize();

    const rows = this.db.prepare(
      'SELECT * FROM notes WHERE relative_path LIKE ? ORDER BY title'
    ).all(`${folder}%`) as Array<{
      id: string;
      path: string;
      relative_path: string;
      title: string;
      content: string;
      excerpt: string;
      tags: string;
      links: string;
      created_at: string;
      modified_at: string;
      word_count: number;
      type: string;
      metadata: string;
    }>;

    return rows.map(row => this.deserializeNote(row));
  }

  /**
   * Get notes by tag
   */
  async getByTag(tag: string): Promise<Note[]> {
    await this.initialize();

    const rows = this.db.prepare(
      'SELECT * FROM notes WHERE tags LIKE ? ORDER BY modified_at DESC'
    ).all(`%"${tag}"%`) as Array<{
      id: string;
      path: string;
      relative_path: string;
      title: string;
      content: string;
      excerpt: string;
      tags: string;
      links: string;
      created_at: string;
      modified_at: string;
      word_count: number;
      type: string;
      metadata: string;
    }>;

    return rows.map(row => this.deserializeNote(row));
  }

  /**
   * Get all unique tags
   */
  async getTags(): Promise<Array<{ tag: string; count: number }>> {
    await this.initialize();

    const rows = this.db.prepare('SELECT tags FROM notes').all() as Array<{ tags: string }>;
    const tagCounts = new Map<string, number>();

    for (const row of rows) {
      const tags = JSON.parse(row.tags || '[]') as string[];
      for (const tag of tags) {
        tagCounts.set(tag, (tagCounts.get(tag) || 0) + 1);
      }
    }

    return Array.from(tagCounts.entries())
      .map(([tag, count]) => ({ tag, count }))
      .sort((a, b) => b.count - a.count);
  }

  /**
   * Get statistics
   */
  async getStats(): Promise<NoteStats> {
    await this.initialize();

    const total = this.db.prepare('SELECT COUNT(*) as count FROM notes').get() as { count: number };
    const byType = this.db.prepare(
      'SELECT type, COUNT(*) as count FROM notes GROUP BY type'
    ).all() as Array<{ type: string; count: number }>;
    const words = this.db.prepare('SELECT SUM(word_count) as total FROM notes').get() as { total: number };

    // Get folder counts
    const folderCounts: Record<string, number> = {};
    const rows = this.db.prepare('SELECT relative_path FROM notes').all() as Array<{ relative_path: string }>;
    for (const row of rows) {
      const folder = path.dirname(row.relative_path) || '/';
      folderCounts[folder] = (folderCounts[folder] || 0) + 1;
    }

    return {
      totalNotes: total.count,
      byType: Object.fromEntries(byType.map(b => [b.type, b.count])),
      byFolder: folderCounts,
      totalWords: words.total || 0,
      lastIndexed: new Date().toISOString(),
    };
  }

  /**
   * Read note content from disk
   */
  async readNote(relativePath: string): Promise<string> {
    const fullPath = path.join(this.config.notesDir, relativePath);
    return fs.readFile(fullPath, 'utf-8');
  }

  /**
   * Create a new note
   */
  async createNote(options: {
    path: string;
    title: string;
    content: string;
    tags?: string[];
  }): Promise<string> {
    const fullPath = path.join(this.config.notesDir, options.path);

    // Ensure directory exists
    await fs.mkdir(path.dirname(fullPath), { recursive: true });

    // Build content with frontmatter
    const frontmatter = ['---', `title: ${options.title}`];
    if (options.tags && options.tags.length > 0) {
      frontmatter.push(`tags: [${options.tags.join(', ')}]`);
    }
    frontmatter.push(`created: ${new Date().toISOString()}`, '---', '');

    const fullContent = frontmatter.join('\n') + options.content;
    await fs.writeFile(fullPath, fullContent, 'utf-8');

    // Index the new note
    return this.indexFile(fullPath);
  }

  /**
   * Close the database connection
   */
  close(): void {
    if (this.db) {
      this.db.close();
    }
  }

  // =============================================================================
  // Private Methods
  // =============================================================================

  private async walkDirectory(dir: string): Promise<string[]> {
    const files: string[] = [];
    const entries = await fs.readdir(dir, { withFileTypes: true });

    for (const entry of entries) {
      // Skip hidden files/folders if configured
      if (!this.config.includeHidden && entry.name.startsWith('.')) {
        continue;
      }

      // Skip excluded folders
      if (entry.isDirectory() && this.config.excludeFolders.includes(entry.name)) {
        continue;
      }

      const fullPath = path.join(dir, entry.name);

      if (entry.isDirectory()) {
        const subFiles = await this.walkDirectory(fullPath);
        files.push(...subFiles);
      } else if (entry.isFile()) {
        const ext = path.extname(entry.name).toLowerCase();
        if (this.config.extensions.includes(ext)) {
          files.push(fullPath);
        }
      }
    }

    return files;
  }

  private generateId(relativePath: string): string {
    return Buffer.from(relativePath).toString('base64url');
  }

  private deserializeNote(row: {
    id: string;
    path: string;
    relative_path: string;
    title: string;
    content: string;
    excerpt: string;
    tags: string;
    links: string;
    created_at: string;
    modified_at: string;
    word_count: number;
    type: string;
    metadata: string;
  }): Note {
    return {
      id: row.id,
      path: row.path,
      relativePath: row.relative_path,
      title: row.title,
      content: row.content,
      excerpt: row.excerpt,
      tags: JSON.parse(row.tags || '[]'),
      links: JSON.parse(row.links || '[]'),
      backlinks: [], // Populated separately if needed
      createdAt: row.created_at,
      modifiedAt: row.modified_at,
      wordCount: row.word_count,
      type: row.type as Note['type'],
      metadata: JSON.parse(row.metadata || '{}'),
    };
  }

  private async buildBacklinks(): Promise<void> {
    // Get all notes with their links
    const notes = this.db.prepare('SELECT id, links FROM notes').all() as Array<{
      id: string;
      links: string;
    }>;

    const insertStmt = this.db.prepare(
      'INSERT OR IGNORE INTO backlinks (source_id, target_id) VALUES (?, ?)'
    );

    for (const note of notes) {
      const links = JSON.parse(note.links || '[]') as string[];

      for (const link of links) {
        // Try to find the target note
        const target = this.db.prepare(
          'SELECT id FROM notes WHERE title = ? OR relative_path LIKE ?'
        ).get(link, `%${link}%`) as { id: string } | undefined;

        if (target) {
          insertStmt.run(note.id, target.id);
        }
      }
    }
  }

  private extractHighlights(content: string, query: string): string[] {
    const highlights: string[] = [];
    const terms = query.toLowerCase().split(/\s+/);
    const lines = content.split('\n');

    for (const line of lines) {
      const lowerLine = line.toLowerCase();
      if (terms.some(term => lowerLine.includes(term))) {
        highlights.push(line.slice(0, 200));
        if (highlights.length >= 3) break;
      }
    }

    return highlights;
  }
}

// =============================================================================
// Factory Function
// =============================================================================

export function createNotesManager(config: NotesManagerConfig): NotesManager {
  return new NotesManager(config);
}
