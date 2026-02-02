/**
 * @fileoverview Blob Repository
 *
 * Handles content-addressable blob storage operations.
 * Blobs are deduplicated by SHA-256 hash and reference counted.
 */

import * as crypto from 'crypto';
import { BaseRepository } from './base.js';
import type { BlobDbRow } from '../types.js';

/**
 * Repository for blob storage operations
 */
export class BlobRepository extends BaseRepository {
  /**
   * Store content as a blob, deduplicating by hash
   * @returns The blob ID (new or existing)
   */
  store(content: string | Buffer, mimeType = 'text/plain'): string {
    const buffer = typeof content === 'string' ? Buffer.from(content, 'utf-8') : content;
    const hash = crypto.createHash('sha256').update(buffer).digest('hex');

    // Check for existing blob with same hash
    const existing = this.get<{ id: string }>('SELECT id FROM blobs WHERE hash = ?', hash);

    if (existing) {
      // Increment reference count
      this.run('UPDATE blobs SET ref_count = ref_count + 1 WHERE id = ?', existing.id);
      return existing.id;
    }

    // Create new blob
    const id = this.generateId('blob');
    const now = this.now();

    this.run(
      `INSERT INTO blobs (id, hash, content, mime_type, size_original, size_compressed, compression, created_at)
       VALUES (?, ?, ?, ?, ?, ?, 'none', ?)`,
      id,
      hash,
      buffer,
      mimeType,
      buffer.length,
      buffer.length,
      now
    );

    return id;
  }

  /**
   * Get blob content by ID
   */
  getContent(blobId: string): string | null {
    const row = this.get<{ content: Buffer }>('SELECT content FROM blobs WHERE id = ?', blobId);
    if (!row) return null;
    return row.content.toString('utf-8');
  }

  /**
   * Get full blob record by ID
   */
  getById(blobId: string): BlobDbRow | null {
    const row = this.get<BlobDbRow>('SELECT * FROM blobs WHERE id = ?', blobId);
    return row ?? null;
  }

  /**
   * Get blob by hash
   */
  getByHash(hash: string): BlobDbRow | null {
    const row = this.get<BlobDbRow>('SELECT * FROM blobs WHERE hash = ?', hash);
    return row ?? null;
  }

  /**
   * Get reference count for a blob
   */
  getRefCount(blobId: string): number {
    const row = this.get<{ ref_count: number }>('SELECT ref_count FROM blobs WHERE id = ?', blobId);
    return row?.ref_count ?? 0;
  }

  /**
   * Increment reference count
   */
  incrementRefCount(blobId: string): void {
    this.run('UPDATE blobs SET ref_count = ref_count + 1 WHERE id = ?', blobId);
  }

  /**
   * Decrement reference count
   * @returns The new reference count
   */
  decrementRefCount(blobId: string): number {
    this.run('UPDATE blobs SET ref_count = ref_count - 1 WHERE id = ? AND ref_count > 0', blobId);
    return this.getRefCount(blobId);
  }

  /**
   * Delete blobs with zero references
   * @returns Number of blobs deleted
   */
  deleteUnreferenced(): number {
    const result = this.run('DELETE FROM blobs WHERE ref_count <= 0');
    return result.changes;
  }

  /**
   * Get total blob count
   */
  count(): number {
    const row = this.get<{ count: number }>('SELECT COUNT(*) as count FROM blobs');
    return row?.count ?? 0;
  }

  /**
   * Get total storage used by blobs
   */
  getTotalSize(): { original: number; compressed: number } {
    const row = this.get<{ original: number; compressed: number }>(
      'SELECT COALESCE(SUM(size_original), 0) as original, COALESCE(SUM(size_compressed), 0) as compressed FROM blobs'
    );
    return row ?? { original: 0, compressed: 0 };
  }
}
