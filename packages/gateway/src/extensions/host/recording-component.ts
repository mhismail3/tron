import { performance } from "node:perf_hooks";
import {
  truncateToWidth,
  visibleWidth,
  type Component,
  type Focusable,
} from "@earendil-works/pi-tui";
import { boundedDisplayError } from "./terminal-sanitizer.js";

export type ComponentDiagnosticCode =
  | "render-failed"
  | "render-invalid"
  | "render-truncated"
  | "input-failed"
  | "invalidate-failed"
  | "focus-failed"
  | "dispose-failed";

export interface ComponentDiagnostic {
  code: ComponentDiagnosticCode;
  message: string;
}

export interface ComponentRenderCapture {
  sequence: number;
  width: number;
  lines: readonly string[];
  durationMs: number;
  failed: boolean;
}

export interface RecordingComponentOptions {
  maximumLines?: number;
  maximumSourceBytes?: number;
  onDiagnostic?: (diagnostic: ComponentDiagnostic) => void;
}

type DisposableComponent = Component & { dispose?: () => void };

const DEFAULT_MAXIMUM_LINES = 120;
const DEFAULT_MAXIMUM_SOURCE_BYTES = 256 * 1_024;

/**
 * Records the result of the render already requested by pi-tui. Consumers read
 * `capture` and must never call the wrapped component's render method again.
 */
export class RecordingComponent implements Component {
  private readonly component: DisposableComponent;
  private readonly maximumLines: number;
  private readonly maximumSourceBytes: number;
  private readonly diagnosticCallback: ((diagnostic: ComponentDiagnostic) => void) | undefined;
  private disposed = false;
  private sequence = 0;
  private _capture?: ComponentRenderCapture;

  constructor(component: Component, options: RecordingComponentOptions = {}) {
    this.component = component;
    const requestedMaximum = options.maximumLines ?? DEFAULT_MAXIMUM_LINES;
    this.maximumLines = Number.isFinite(requestedMaximum)
      ? Math.max(1, Math.min(DEFAULT_MAXIMUM_LINES, Math.trunc(requestedMaximum)))
      : DEFAULT_MAXIMUM_LINES;
    const requestedBytes = options.maximumSourceBytes ?? DEFAULT_MAXIMUM_SOURCE_BYTES;
    this.maximumSourceBytes = Number.isFinite(requestedBytes)
      ? Math.max(256, Math.min(DEFAULT_MAXIMUM_SOURCE_BYTES, Math.trunc(requestedBytes)))
      : DEFAULT_MAXIMUM_SOURCE_BYTES;
    this.diagnosticCallback = options.onDiagnostic;

    if ("focused" in component) {
      Object.defineProperty(this, "focused", {
        configurable: false,
        enumerable: true,
        get: () => (component as Component & Focusable).focused,
        set: (focused: boolean) => {
          try {
            (component as Component & Focusable).focused = focused;
          } catch (error) {
            this.diagnose("focus-failed", error);
          }
        },
      });
    }
  }

  get capture(): ComponentRenderCapture | undefined {
    if (!this._capture) return undefined;
    return { ...this._capture, lines: [...this._capture.lines] };
  }

  get renderCount(): number { return this.sequence; }
  get wantsKeyRelease(): boolean { return this.component.wantsKeyRelease === true; }

  render(width: number): string[] {
    const safeWidth = Math.max(1, Math.trunc(width));
    const startedAt = performance.now();
    this.sequence += 1;
    let failed = false;
    let lines: string[];

    if (this.disposed) {
      failed = true;
      lines = [this.fallbackLine(safeWidth)];
      this.diagnose("render-failed", "Component rendered after disposal");
    } else {
      try {
        const rendered = this.component.render(safeWidth) as unknown;
        if (!Array.isArray(rendered) || rendered.length > this.maximumLines) {
          failed = true;
          lines = [this.fallbackLine(safeWidth)];
          this.diagnose("render-invalid", `Component exceeded ${this.maximumLines} bounded logical lines`);
        } else {
          // Bound count, element type, and raw bytes before invoking terminal-width
          // logic or returning anything to the compositor.
          let sourceBytes = 0;
          let invalid = false;
          for (const candidate of rendered) {
            if (typeof candidate !== "string") { invalid = true; break; }
            sourceBytes += Buffer.byteLength(candidate, "utf8");
            if (sourceBytes > this.maximumSourceBytes) { invalid = true; break; }
          }
          if (invalid) {
            failed = true;
            lines = [this.fallbackLine(safeWidth)];
            this.diagnose("render-invalid", `Component exceeded its bounded render source`);
          } else lines = (rendered as string[]).map((line) => {
            if (visibleWidth(line) <= safeWidth) return line;
            this.diagnose("render-truncated", `Component line exceeded ${safeWidth} columns`);
            return truncateToWidth(line, safeWidth, "");
          });
        }
      } catch (error) {
        failed = true;
        lines = [this.fallbackLine(safeWidth)];
        this.diagnose("render-failed", error);
      }
    }

    this._capture = {
      sequence: this.sequence,
      width: safeWidth,
      lines: [...lines],
      durationMs: performance.now() - startedAt,
      failed,
    };
    return lines;
  }

  handleInput(data: string): void {
    if (this.disposed || !this.component.handleInput) return;
    try {
      this.component.handleInput(data);
    } catch (error) {
      this.diagnose("input-failed", error);
    }
  }

  invalidate(): void {
    if (this.disposed) return;
    try {
      this.component.invalidate();
    } catch (error) {
      this.diagnose("invalidate-failed", error);
    }
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    try {
      this.component.dispose?.();
    } catch (error) {
      this.diagnose("dispose-failed", error);
    }
  }

  private fallbackLine(width: number): string {
    return truncateToWidth("[Extension component unavailable]", width, "");
  }

  private diagnose(code: ComponentDiagnosticCode, error: unknown): void {
    if (!this.diagnosticCallback) return;
    try {
      this.diagnosticCallback({ code, message: boundedDisplayError(error) });
    } catch {
      // Diagnostics must not make extension rendering fail.
    }
  }
}
