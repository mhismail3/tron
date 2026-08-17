import {
  setCapabilities,
  type Terminal,
  type TerminalCapabilities,
} from "@earendil-works/pi-tui";

export const REMOTE_TUI_MAX_COLUMNS = 160;
export const REMOTE_TUI_MAX_ROWS = 120;
export const REMOTE_TUI_MAX_INPUT_BYTES = 16 * 1024;

const WRITE_EVENT_LIMIT = 16;
const WRITE_SAMPLE_LIMIT = 256;
const TITLE_LIMIT = 256;
const REMOTE_CAPABILITIES: TerminalCapabilities = {
  images: null,
  trueColor: true,
  hyperlinks: true,
};

let capabilitiesInitialized = false;

/** Initializes the process-wide public pi-tui capability cache exactly once. */
export function initializeRemoteTuiCapabilities(): void {
  if (capabilitiesInitialized) return;
  setCapabilities(REMOTE_CAPABILITIES);
  capabilitiesInitialized = true;
}

export interface InMemoryTerminalWriteEvent {
  bytes: number;
  sample: string;
}

export interface InMemoryTerminalState {
  started: boolean;
  cursorVisible: boolean;
  title: string;
  progressActive: boolean;
  verticalOffset: number;
  clearOperations: number;
  writeEvents: readonly InMemoryTerminalWriteEvent[];
}

function clampInteger(value: number, minimum: number, maximum: number): number {
  if (!Number.isFinite(value)) return minimum;
  return Math.min(maximum, Math.max(minimum, Math.trunc(value)));
}

function boundedDisplayText(value: string, limit: number): string {
  let text = "";
  for (const character of value) {
    const point = character.codePointAt(0) ?? 0;
    if (point < 0x20 || (point >= 0x7f && point <= 0x9f)) continue;
    if (text.length + character.length > limit) break;
    text += character;
  }
  return text;
}

/**
 * A bounded terminal implementation for driving public pi-tui composition without
 * touching stdin or stdout. Host-only injection methods are deliberately outside
 * Pi's Terminal interface.
 */
export class InMemoryTerminal implements Terminal {
  private inputHandler: ((data: string) => void) | undefined;
  private resizeHandler: (() => void) | undefined;
  private started = false;
  private _columns: number;
  private _rows: number;
  private cursorVisible = true;
  private title = "";
  private progressActive = false;
  private verticalOffset = 0;
  private clearOperations = 0;
  private readonly writeEvents: InMemoryTerminalWriteEvent[] = [];

  constructor(columns = 80, rows = 24) {
    initializeRemoteTuiCapabilities();
    this._columns = clampInteger(columns, 1, REMOTE_TUI_MAX_COLUMNS);
    this._rows = clampInteger(rows, 1, REMOTE_TUI_MAX_ROWS);
  }

  get columns(): number { return this._columns; }
  get rows(): number { return this._rows; }
  get kittyProtocolActive(): boolean { return false; }

  start(onInput: (data: string) => void, onResize: () => void): void {
    this.inputHandler = onInput;
    this.resizeHandler = onResize;
    this.started = true;
  }

  stop(): void {
    if (!this.started && !this.inputHandler && !this.resizeHandler) return;
    this.started = false;
    this.inputHandler = undefined;
    this.resizeHandler = undefined;
    this.progressActive = false;
  }

  async drainInput(_maxMs?: number, _idleMs?: number): Promise<void> {}

  /** Returns false when stopped and rejects oversized input before delivery. */
  injectInput(data: string): boolean {
    if (!this.started || !this.inputHandler) return false;
    if (Buffer.byteLength(data, "utf8") > REMOTE_TUI_MAX_INPUT_BYTES) {
      throw new Error(`Remote TUI input exceeds ${REMOTE_TUI_MAX_INPUT_BYTES} bytes`);
    }
    this.inputHandler(data);
    return true;
  }

  /** Resizes within host bounds and notifies a started TUI only on change. */
  resize(columns: number, rows: number): boolean {
    const nextColumns = clampInteger(columns, 1, REMOTE_TUI_MAX_COLUMNS);
    const nextRows = clampInteger(rows, 1, REMOTE_TUI_MAX_ROWS);
    if (nextColumns === this._columns && nextRows === this._rows) return false;
    this._columns = nextColumns;
    this._rows = nextRows;
    if (this.started) this.resizeHandler?.();
    return true;
  }

  write(data: string): void {
    const sample = boundedDisplayText(data, WRITE_SAMPLE_LIMIT);
    this.writeEvents.push({ bytes: Buffer.byteLength(data, "utf8"), sample });
    if (this.writeEvents.length > WRITE_EVENT_LIMIT) this.writeEvents.shift();
  }

  moveBy(lines: number): void {
    this.verticalOffset = clampInteger(this.verticalOffset + lines, -REMOTE_TUI_MAX_ROWS, REMOTE_TUI_MAX_ROWS);
  }

  hideCursor(): void { this.cursorVisible = false; }
  showCursor(): void { this.cursorVisible = true; }
  clearLine(): void { this.clearOperations += 1; }
  clearFromCursor(): void { this.clearOperations += 1; }
  clearScreen(): void { this.clearOperations += 1; }
  setTitle(title: string): void { this.title = boundedDisplayText(title, TITLE_LIMIT); }
  setProgress(active: boolean): void { this.progressActive = active; }

  snapshot(): InMemoryTerminalState {
    return {
      started: this.started,
      cursorVisible: this.cursorVisible,
      title: this.title,
      progressActive: this.progressActive,
      verticalOffset: this.verticalOffset,
      clearOperations: this.clearOperations,
      writeEvents: this.writeEvents.map((event) => ({ ...event })),
    };
  }
}
