/**
 * @fileoverview HTTP server for the dashboard
 *
 * Serves the dashboard UI and provides REST API endpoints
 * for session and event data.
 *
 * Uses Node.js http module for compatibility with better-sqlite3.
 */

import { createServer, type IncomingMessage, type ServerResponse } from 'http';
import { createSQLiteEventStore, type SQLiteEventStore } from '@tron/agent';
import { DashboardSessionRepository } from './src/data/repositories/dashboard-session.repo.js';
import { DashboardEventRepository } from './src/data/repositories/dashboard-event.repo.js';
import type { SessionId } from '@tron/agent';
import * as path from 'path';
import * as fs from 'fs';
import { fileURLToPath } from 'url';

// =============================================================================
// Configuration
// =============================================================================

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = parseInt(process.env.PORT || '3001', 10);
const DB_NAME = process.env.DB_NAME || 'beta.db';
const TRON_HOME = process.env.TRON_HOME || path.join(process.env.HOME || '~', '.tron');
const DB_PATH = path.join(TRON_HOME, 'db', DB_NAME);

// =============================================================================
// Server State
// =============================================================================

let store: SQLiteEventStore | null = null;
let sessionRepo: DashboardSessionRepository | null = null;
let eventRepo: DashboardEventRepository | null = null;

// =============================================================================
// Initialization
// =============================================================================

async function initializeStore(): Promise<void> {
  if (!fs.existsSync(DB_PATH)) {
    console.error(`Database not found: ${DB_PATH}`);
    console.error('Make sure the Tron agent has been run at least once.');
    process.exit(1);
  }

  console.log(`Opening database: ${DB_PATH}`);
  store = await createSQLiteEventStore(DB_PATH);
  sessionRepo = new DashboardSessionRepository(store);
  eventRepo = new DashboardEventRepository(store);
  console.log('Database initialized successfully');
}

// =============================================================================
// API Handlers
// =============================================================================

async function handleApiSessions(url: URL): Promise<{ data: unknown; status: number }> {
  if (!sessionRepo) {
    return { data: { error: 'Database not initialized' }, status: 500 };
  }

  const limit = parseInt(url.searchParams.get('limit') || '100', 10);
  const offset = parseInt(url.searchParams.get('offset') || '0', 10);
  const ended = url.searchParams.get('ended');

  try {
    const sessions = await sessionRepo.listWithStats({
      limit,
      offset,
      ended: ended === 'true' ? true : ended === 'false' ? false : undefined,
      includePreview: true,
    });
    const total = await sessionRepo.count({
      ended: ended === 'true' ? true : ended === 'false' ? false : undefined,
    });

    return { data: { sessions, total }, status: 200 };
  } catch (error) {
    console.error('Error fetching sessions:', error);
    return { data: { error: 'Failed to fetch sessions' }, status: 500 };
  }
}

async function handleApiSession(sessionId: string): Promise<{ data: unknown; status: number }> {
  if (!sessionRepo) {
    return { data: { error: 'Database not initialized' }, status: 500 };
  }

  try {
    const session = await sessionRepo.getById(sessionId as SessionId);
    if (!session) {
      return { data: { error: 'Session not found' }, status: 404 };
    }
    return { data: { session }, status: 200 };
  } catch (error) {
    console.error('Error fetching session:', error);
    return { data: { error: 'Failed to fetch session' }, status: 500 };
  }
}

async function handleApiSessionEvents(
  sessionId: string,
  url: URL
): Promise<{ data: unknown; status: number }> {
  if (!eventRepo) {
    return { data: { error: 'Database not initialized' }, status: 500 };
  }

  const limit = parseInt(url.searchParams.get('limit') || '500', 10);
  const offset = parseInt(url.searchParams.get('offset') || '0', 10);
  const types = url.searchParams.get('types');

  try {
    let result;
    if (types) {
      const typeList = types.split(',') as any[];
      result = await eventRepo.getEventsByType(sessionId as SessionId, typeList, {
        limit,
        offset,
      });
    } else {
      result = await eventRepo.getEventsBySession(sessionId as SessionId, {
        limit,
        offset,
      });
    }

    return {
      data: {
        events: result.items,
        total: result.total,
        hasMore: result.hasMore,
      },
      status: 200,
    };
  } catch (error) {
    console.error('Error fetching events:', error);
    return { data: { error: 'Failed to fetch events' }, status: 500 };
  }
}

async function handleApiStats(): Promise<{ data: unknown; status: number }> {
  if (!sessionRepo) {
    return { data: { error: 'Database not initialized' }, status: 500 };
  }

  try {
    const stats = await sessionRepo.getStats();
    return { data: stats, status: 200 };
  } catch (error) {
    console.error('Error fetching stats:', error);
    return { data: { error: 'Failed to fetch stats' }, status: 500 };
  }
}

// =============================================================================
// Static File Serving
// =============================================================================

function getMimeType(filePath: string): string {
  const ext = path.extname(filePath).toLowerCase();
  const mimeTypes: Record<string, string> = {
    '.html': 'text/html',
    '.css': 'text/css',
    '.js': 'application/javascript',
    '.json': 'application/json',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.gif': 'image/gif',
    '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon',
    '.woff': 'font/woff',
    '.woff2': 'font/woff2',
  };
  return mimeTypes[ext] || 'application/octet-stream';
}

function serveStaticFile(
  filePath: string,
  res: ServerResponse
): { served: boolean } {
  const fullPath = path.join(__dirname, 'dist', 'static', filePath);

  if (!fs.existsSync(fullPath)) {
    return { served: false };
  }

  const content = fs.readFileSync(fullPath);
  const mimeType = getMimeType(filePath);

  res.writeHead(200, {
    'Content-Type': mimeType,
    'Cache-Control': 'public, max-age=3600',
  });
  res.end(content);
  return { served: true };
}

// =============================================================================
// Response Helpers
// =============================================================================

function sendJson(res: ServerResponse, data: unknown, status = 200): void {
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
  });
  res.end(JSON.stringify(data));
}

function sendHtml(res: ServerResponse, content: string, status = 200): void {
  res.writeHead(status, {
    'Content-Type': 'text/html',
  });
  res.end(content);
}

function sendCss(res: ServerResponse, content: string): void {
  res.writeHead(200, {
    'Content-Type': 'text/css',
  });
  res.end(content);
}

// =============================================================================
// Request Handler
// =============================================================================

async function handleRequest(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const url = new URL(req.url || '/', `http://localhost:${PORT}`);
  const pathname = url.pathname;
  const method = req.method || 'GET';

  // CORS preflight
  if (method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    });
    res.end();
    return;
  }

  // API routes
  if (pathname.startsWith('/api/')) {
    // GET /api/sessions
    if (pathname === '/api/sessions' && method === 'GET') {
      const result = await handleApiSessions(url);
      sendJson(res, result.data, result.status);
      return;
    }

    // GET /api/sessions/:id
    const sessionMatch = pathname.match(/^\/api\/sessions\/([^/]+)$/);
    if (sessionMatch && method === 'GET') {
      const result = await handleApiSession(sessionMatch[1]);
      sendJson(res, result.data, result.status);
      return;
    }

    // GET /api/sessions/:id/events
    const eventsMatch = pathname.match(/^\/api\/sessions\/([^/]+)\/events$/);
    if (eventsMatch && method === 'GET') {
      const result = await handleApiSessionEvents(eventsMatch[1], url);
      sendJson(res, result.data, result.status);
      return;
    }

    // GET /api/stats
    if (pathname === '/api/stats' && method === 'GET') {
      const result = await handleApiStats();
      sendJson(res, result.data, result.status);
      return;
    }

    sendJson(res, { error: 'Not found' }, 404);
    return;
  }

  // Serve static files from dist/static in production
  if (pathname !== '/') {
    const staticResult = serveStaticFile(pathname, res);
    if (staticResult.served) {
      return;
    }
  }

  // Serve CSS file directly in development
  if (pathname === '/styles/dashboard.css') {
    const cssPath = path.join(__dirname, 'src', 'styles', 'dashboard.css');
    if (fs.existsSync(cssPath)) {
      const content = fs.readFileSync(cssPath, 'utf-8');
      sendCss(res, content);
      return;
    }
  }

  // For development, serve source files directly
  if (pathname.endsWith('.tsx') || pathname.endsWith('.ts') || pathname.endsWith('.js')) {
    const srcPath = path.join(__dirname, 'src', pathname);
    if (fs.existsSync(srcPath)) {
      const content = fs.readFileSync(srcPath, 'utf-8');
      res.writeHead(200, { 'Content-Type': 'application/javascript' });
      res.end(content);
      return;
    }
  }

  // Serve index.html for SPA routes
  const indexPath = path.join(__dirname, 'src', 'index.html');
  if (fs.existsSync(indexPath)) {
    const content = fs.readFileSync(indexPath, 'utf-8');
    sendHtml(res, content);
    return;
  }

  // Fallback: 404
  sendHtml(res, '<h1>Not Found</h1>', 404);
}

// =============================================================================
// Server Startup
// =============================================================================

async function main() {
  await initializeStore();

  const server = createServer(handleRequest);

  server.listen(PORT, () => {
    console.log(`Dashboard server running at http://localhost:${PORT}`);
    console.log(`Database: ${DB_PATH}`);
    console.log('');
    console.log('API Endpoints:');
    console.log(`  GET /api/sessions     - List all sessions`);
    console.log(`  GET /api/sessions/:id - Get session details`);
    console.log(`  GET /api/sessions/:id/events - Get session events`);
    console.log(`  GET /api/stats        - Get dashboard statistics`);
  });
}

main().catch((error) => {
  console.error('Failed to start server:', error);
  process.exit(1);
});
