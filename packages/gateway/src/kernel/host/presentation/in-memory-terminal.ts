import {
  setCapabilities,
  type ProgramStatus,
  type Terminal,
  type TerminalCapabilities,
} from "../../pi/tui.js";

const REMOTE_CAPABILITIES: TerminalCapabilities = {
  images: null,
  trueColor: true,
  hyperlinks: true,
};

let capabilitiesInitialized = false;

/** Initializes the process-wide public pi-tui capability cache exactly once. */
function initializeRemoteTuiCapabilities(): void {
  if (capabilitiesInitialized) return;
  setCapabilities(REMOTE_CAPABILITIES);
  capabilitiesInitialized = true;
}

/**
 * A fixed 80x24 terminal for driving public pi-tui composition without touching
 * stdin or stdout. Mounted components are read through RecordingComponent, so
 * terminal output, cursor and title writes are discarded and no input is ever
 * delivered.
 */
export class InMemoryTerminal implements Terminal {
  constructor() { initializeRemoteTuiCapabilities(); }

  get columns(): number { return 80; }
  get rows(): number { return 24; }
  get kittyProtocolActive(): boolean { return false; }

  start(_onInput: (data: string) => void, _onResize: () => void): void {}
  stop(): void {}
  async drainInput(_maxMs?: number, _idleMs?: number): Promise<void> {}
  write(_data: string): void {}
  moveBy(_lines: number): void {}
  hideCursor(): void {}
  showCursor(): void {}
  clearLine(): void {}
  clearFromCursor(): void {}
  clearScreen(): void {}
  setTitle(_title: string): void {}
  setProgress(_active: boolean): void {}
  setProgramStatus(_status: ProgramStatus): void {}
}
