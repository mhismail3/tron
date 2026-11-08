import {
  truncateToWidth,
  visibleWidth,
  type Component,
} from "../../pi/tui.js";
import { boundedDisplayError } from "./terminal-sanitizer.js";

export type ComponentDiagnosticCode =
  | "render-failed"
  | "render-invalid"
  | "render-truncated"
  | "invalidate-failed"
  | "dispose-failed";

export interface ComponentDiagnostic {
  code: ComponentDiagnosticCode;
  message: string;
}

type DisposableComponent = Component & { dispose?: () => void };

const MAXIMUM_LINES = 120;
const MAXIMUM_SOURCE_BYTES = 256 * 1_024;

/**
 * Records the result of the render already requested by pi-tui. Consumers read
 * `capturedLines` and must never call the wrapped component's render method again.
 */
export class RecordingComponent implements Component {
  private disposed = false;
  private lines?: readonly string[];

  constructor(
    private readonly component: DisposableComponent,
    private readonly diagnosticCallback?: (diagnostic: ComponentDiagnostic) => void,
  ) {}

  get capturedLines(): string[] | undefined { return this.lines ? [...this.lines] : undefined; }

  render(width: number): string[] {
    const safeWidth = Math.max(1, Math.trunc(width));
    let lines: string[];

    if (this.disposed) {
      lines = [this.fallbackLine(safeWidth)];
      this.diagnose("render-failed", "Component rendered after disposal");
    } else {
      try {
        const rendered = this.component.render(safeWidth) as unknown;
        if (!Array.isArray(rendered) || rendered.length > MAXIMUM_LINES) {
          lines = [this.fallbackLine(safeWidth)];
          this.diagnose("render-invalid", `Component exceeded ${MAXIMUM_LINES} bounded logical lines`);
        } else {
          // Bound count, element type, and raw bytes before invoking terminal-width
          // logic or returning anything to the compositor.
          let sourceBytes = 0;
          let invalid = false;
          for (const candidate of rendered) {
            if (typeof candidate !== "string") { invalid = true; break; }
            sourceBytes += Buffer.byteLength(candidate, "utf8");
            if (sourceBytes > MAXIMUM_SOURCE_BYTES) { invalid = true; break; }
          }
          if (invalid) {
            lines = [this.fallbackLine(safeWidth)];
            this.diagnose("render-invalid", `Component exceeded its bounded render source`);
          } else lines = (rendered as string[]).map((line) => {
            if (visibleWidth(line) <= safeWidth) return line;
            this.diagnose("render-truncated", `Component line exceeded ${safeWidth} columns`);
            return truncateToWidth(line, safeWidth, "");
          });
        }
      } catch (error) {
        lines = [this.fallbackLine(safeWidth)];
        this.diagnose("render-failed", error);
      }
    }

    this.lines = [...lines];
    return lines;
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
