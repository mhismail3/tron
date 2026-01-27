/**
 * @fileoverview Voice Notes RPC Handlers
 *
 * Handlers for voiceNotes.* RPC methods:
 * - voiceNotes.save: Transcribe and save a voice note
 * - voiceNotes.list: List saved voice notes
 * - voiceNotes.delete: Delete a voice note
 */

import { createLogger, categorizeError, LogErrorCategory } from '../../logging/index.js';
import * as fs from 'fs/promises';
import * as path from 'path';
import type {
  RpcRequest,
  RpcResponse,
  VoiceNotesSaveParams,
  VoiceNotesSaveResult,
  VoiceNotesListParams,
  VoiceNotesListResult,
  VoiceNotesDeleteParams,
  VoiceNotesDeleteResult,
  VoiceNoteMetadata,
} from '../types.js';
import type { RpcContext } from '../context-types.js';
import { MethodRegistry, type MethodRegistration, type MethodHandler } from '../registry.js';
import { getNotesDir } from '../../settings/loader.js';

const logger = createLogger('rpc:voiceNotes');

// =============================================================================
// Handler Implementations
// =============================================================================

/**
 * Handle voiceNotes.save request
 *
 * Transcribes audio and saves as a markdown voice note.
 */
export async function handleVoiceNotesSave(
  request: RpcRequest,
  context: RpcContext
): Promise<RpcResponse> {
  const params = request.params as VoiceNotesSaveParams | undefined;

  if (!params?.audioBase64) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'audioBase64 is required');
  }

  if (!context.transcriptionManager) {
    return MethodRegistry.errorResponse(request.id, 'NOT_SUPPORTED', 'Transcription not available');
  }

  try {
    // 1. Transcribe the audio using existing pipeline
    const transcribeResult = await context.transcriptionManager.transcribeAudio({
      audioBase64: params.audioBase64,
      mimeType: params.mimeType,
      fileName: params.fileName,
      transcriptionModelId: params.transcriptionModelId,
    });

    // 2. Generate filename and create notes directory
    const now = new Date();
    const dateStr = now.toISOString().slice(0, 10);
    const timeStr = now.toTimeString().slice(0, 8).replace(/:/g, '');
    const filename = `${dateStr}-${timeStr}-voice-note.md`;
    const notesDir = getNotesDir();
    await fs.mkdir(notesDir, { recursive: true });
    const filepath = path.join(notesDir, filename);

    // 3. Create markdown content with frontmatter
    const content = `---
type: voice-note
created: ${now.toISOString()}
duration: ${transcribeResult.durationSeconds}
language: ${transcribeResult.language}
model: ${transcribeResult.model}
---

# Voice Note - ${now.toLocaleDateString('en-US', { dateStyle: 'long' })} at ${now.toLocaleTimeString('en-US', { timeStyle: 'short' })}

${transcribeResult.text}
`;

    // 4. Save the file
    await fs.writeFile(filepath, content, 'utf-8');

    const result: VoiceNotesSaveResult = {
      success: true,
      filename,
      filepath,
      transcription: {
        text: transcribeResult.text,
        durationSeconds: transcribeResult.durationSeconds,
        language: transcribeResult.language,
      },
    };

    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    const structured = categorizeError(error, { operation: 'save' });
    logger.error('Failed to save voice note', {
      code: structured.code,
      category: LogErrorCategory.FILESYSTEM,
      error: structured.message,
      retryable: structured.retryable,
    });
    const message = error instanceof Error ? error.message : 'Failed to save voice note';
    return MethodRegistry.errorResponse(request.id, 'VOICE_NOTE_SAVE_FAILED', message);
  }
}

/**
 * Parse voice note metadata from file content
 */
function parseVoiceNoteMetadata(
  filename: string,
  filepath: string,
  content: string
): VoiceNoteMetadata {
  // Parse frontmatter
  const frontmatterMatch = content.match(/^---\n([\s\S]*?)\n---/);
  let createdAt = '';
  let durationSeconds: number | undefined;
  let language: string | undefined;

  if (frontmatterMatch && frontmatterMatch[1]) {
    const fm = frontmatterMatch[1];
    const createdMatch = fm.match(/created:\s*(.+)/);
    const durationMatch = fm.match(/duration:\s*(\d+(?:\.\d+)?)/);
    const languageMatch = fm.match(/language:\s*(\w+)/);

    if (createdMatch?.[1]) createdAt = createdMatch[1].trim();
    if (durationMatch?.[1]) durationSeconds = parseFloat(durationMatch[1]);
    if (languageMatch?.[1]) language = languageMatch[1];
  }

  // Extract full transcript (all non-frontmatter, non-header lines)
  const lines = content.split('\n');
  const contentLines: string[] = [];
  let inFrontmatter = false;
  for (const line of lines) {
    if (line === '---') {
      inFrontmatter = !inFrontmatter;
      continue;
    }
    if (inFrontmatter) continue;
    if (line.startsWith('#')) continue;
    if (line.trim()) {
      contentLines.push(line.trim());
    }
  }
  const transcript = contentLines.join('\n');
  const preview = transcript.slice(0, 100);

  return {
    filename,
    filepath,
    createdAt,
    durationSeconds,
    language,
    preview,
    transcript,
  };
}

/**
 * Handle voiceNotes.list request
 *
 * Lists saved voice notes with pagination.
 */
export async function handleVoiceNotesList(
  request: RpcRequest,
  _context: RpcContext
): Promise<RpcResponse> {
  const params = (request.params || {}) as VoiceNotesListParams;
  const limit = params.limit ?? 50;
  const offset = params.offset ?? 0;

  try {
    const notesDir = getNotesDir();

    // Check if directory exists
    try {
      await fs.access(notesDir);
    } catch {
      // Directory doesn't exist yet - return empty list
      return MethodRegistry.successResponse(request.id, {
        notes: [],
        totalCount: 0,
        hasMore: false,
      });
    }

    // Read directory and filter for markdown files
    const files = await fs.readdir(notesDir);
    const mdFiles = files.filter(f => f.endsWith('.md')).sort().reverse();
    const totalCount = mdFiles.length;

    // Apply pagination
    const pageFiles = mdFiles.slice(offset, offset + limit);
    const hasMore = offset + limit < totalCount;

    // Parse each file for metadata
    const notes: VoiceNoteMetadata[] = [];
    for (const filename of pageFiles) {
      const filepath = path.join(notesDir, filename);
      try {
        const content = await fs.readFile(filepath, 'utf-8');
        const metadata = parseVoiceNoteMetadata(filename, filepath, content);
        notes.push(metadata);
      } catch {
        // Skip files that can't be read
      }
    }

    const result: VoiceNotesListResult = { notes, totalCount, hasMore };
    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    const structured = categorizeError(error, { operation: 'list', limit, offset });
    logger.error('Failed to list voice notes', {
      code: structured.code,
      category: LogErrorCategory.FILESYSTEM,
      error: structured.message,
      retryable: structured.retryable,
    });
    const message = error instanceof Error ? error.message : 'Failed to list voice notes';
    return MethodRegistry.errorResponse(request.id, 'VOICE_NOTES_LIST_FAILED', message);
  }
}

/**
 * Handle voiceNotes.delete request
 *
 * Deletes a voice note file.
 */
export async function handleVoiceNotesDelete(
  request: RpcRequest,
  _context: RpcContext
): Promise<RpcResponse> {
  const params = request.params as VoiceNotesDeleteParams | undefined;

  if (!params?.filename) {
    return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'filename is required');
  }

  try {
    const notesDir = getNotesDir();
    const filepath = path.join(notesDir, params.filename);

    // Security: Ensure the file is within the notes directory
    const resolvedPath = path.resolve(filepath);
    const resolvedNotesDir = path.resolve(notesDir);
    if (!resolvedPath.startsWith(resolvedNotesDir)) {
      return MethodRegistry.errorResponse(request.id, 'INVALID_PARAMS', 'Invalid filename');
    }

    // Check if file exists
    try {
      await fs.access(filepath);
    } catch {
      return MethodRegistry.errorResponse(request.id, 'NOT_FOUND', `Voice note not found: ${params.filename}`);
    }

    // Delete the file
    await fs.unlink(filepath);

    const result: VoiceNotesDeleteResult = {
      success: true,
      filename: params.filename,
    };

    return MethodRegistry.successResponse(request.id, result);
  } catch (error) {
    const structured = categorizeError(error, { filename: params.filename, operation: 'delete' });
    logger.error('Failed to delete voice note', {
      filename: params.filename,
      code: structured.code,
      category: LogErrorCategory.FILESYSTEM,
      error: structured.message,
      retryable: structured.retryable,
    });
    const message = error instanceof Error ? error.message : 'Failed to delete voice note';
    return MethodRegistry.errorResponse(request.id, 'VOICE_NOTE_DELETE_FAILED', message);
  }
}

// =============================================================================
// Handler Factory
// =============================================================================

/**
 * Create voice notes handler registrations
 *
 * @returns Array of method registrations for bulk registration
 */
export function createVoiceNotesHandlers(): MethodRegistration[] {
  const saveHandler: MethodHandler = async (request, context) => {
    const response = await handleVoiceNotesSave(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const listHandler: MethodHandler = async (request, context) => {
    const response = await handleVoiceNotesList(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  const deleteHandler: MethodHandler = async (request, context) => {
    const response = await handleVoiceNotesDelete(request, context);
    if (response.success && response.result) {
      return response.result;
    }
    const err = new Error(response.error?.message || 'Unknown error');
    (err as any).code = response.error?.code;
    throw err;
  };

  return [
    {
      method: 'voiceNotes.save',
      handler: saveHandler,
      options: {
        requiredParams: ['audioBase64'],
        requiredManagers: ['transcriptionManager'],
        description: 'Transcribe and save a voice note',
      },
    },
    {
      method: 'voiceNotes.list',
      handler: listHandler,
      options: {
        description: 'List saved voice notes',
      },
    },
    {
      method: 'voiceNotes.delete',
      handler: deleteHandler,
      options: {
        requiredParams: ['filename'],
        description: 'Delete a voice note',
      },
    },
  ];
}
