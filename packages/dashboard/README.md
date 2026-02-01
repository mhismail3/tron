# Tron Dashboard

A lightweight operational dashboard for browsing Tron agent sessions and viewing events/logs in a linear timeline.

## Features

- Browse all sessions from the database
- View full events/logs timeline for any session
- Display all metadata for every event
- Plugin architecture for custom renderers and exporters
- System-preference theming (light/dark)

## Quick Start

```bash
# From the monorepo root
cd packages/dashboard

# Install dependencies (if not already done)
bun install

# Start development servers
bun run dev
```

Open **http://localhost:3000** in your browser.

## Development

The dev setup runs two servers:

| Port | Server | Purpose |
|------|--------|---------|
| 3000 | Vite | Frontend with hot reload |
| 3001 | Node.js | API server |

Vite proxies `/api/*` requests to the backend automatically.

### Scripts

```bash
bun run dev        # Start both servers
bun run dev:api    # Start API server only
bun run dev:vite   # Start Vite only
bun run test       # Run tests
bun run build      # Build for production
```

## API Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /api/sessions` | List all sessions |
| `GET /api/sessions/:id` | Get session details |
| `GET /api/sessions/:id/events` | Get session events |
| `GET /api/stats` | Get dashboard statistics |

### Query Parameters

**`GET /api/sessions`**
- `limit` - Max sessions to return (default: 100)
- `offset` - Pagination offset (default: 0)
- `ended` - Filter by ended status (`true`/`false`)

**`GET /api/sessions/:id/events`**
- `limit` - Max events to return (default: 500)
- `offset` - Pagination offset (default: 0)
- `types` - Comma-separated event types to filter

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `3001` | API server port |
| `DB_NAME` | `beta.db` | Database filename |
| `TRON_HOME` | `~/.tron` | Tron home directory |

## Architecture

```
src/
├── components/         # React components
│   ├── ui/            # Reusable primitives (Badge, JsonViewer, Spinner)
│   ├── session/       # Session list and detail views
│   ├── event/         # Event timeline and items
│   └── layout/        # Dashboard shell and sidebar
├── data/
│   └── repositories/  # Data access layer
├── store/             # State management (reducer + context)
├── hooks/             # React hooks for data fetching
├── plugins/           # Extensibility system
│   ├── renderers/     # Event type renderers
│   └── exporters/     # Export format plugins
├── styles/            # CSS with theming
└── types/             # TypeScript type definitions
```

## Plugin System

The dashboard supports plugins for custom event rendering and export formats.

### Event Renderers

```typescript
import type { EventRendererPlugin } from '@tron/dashboard';

const myRenderer: EventRendererPlugin = {
  id: 'my-renderer',
  name: 'My Renderer',
  priority: 10,
  canRender: (event) => event.type === 'my.custom.event',
  render: (props) => <MyCustomComponent event={props.event} />,
};
```

### Exporters

```typescript
import type { ExportPlugin } from '@tron/dashboard';

const myExporter: ExportPlugin = {
  id: 'my-exporter',
  name: 'My Format',
  extension: 'txt',
  mimeType: 'text/plain',
  export: async (session, events) => '...',
};
```

## Testing

Tests use Vitest with jsdom environment:

```bash
bun run test           # Run once
bun run test:watch     # Watch mode
```

Test coverage includes:
- Repository layer (18 tests)
- State reducer (19 tests)
- React hooks (3 tests)
- UI components (21 tests)
- Plugin registry (8 tests)
