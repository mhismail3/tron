import {
  TuiMainScreen,
  type Terminal,
  type TuiMainScreenRenderState,
} from "@earendil-works/pi-tui";
import type { ComponentDiagnostic } from "./recording-component.js";
import { boundedDisplayError } from "./terminal-sanitizer.js";

export interface CapturingTuiMainScreenOptions {
  showHardwareCursor?: boolean;
  onRender?: (state: TuiMainScreenRenderState) => void;
  /** Called after every compositor request, including failures and stopped renders. */
  onRenderComplete?: (error?: unknown) => void;
  onDiagnostic?: (diagnostic: ComponentDiagnostic) => void;
}

/**
 * Public-root-only proof that Pi's main-screen compositor can be driven by an
 * in-memory Terminal. Component output is captured by RecordingComponent during
 * Pi's own render pass; this class never invokes a mounted component a second
 * time per mount/compositor pass.
 */
export class CapturingTuiMainScreen extends TuiMainScreen {
  private readonly renderCallback: ((state: TuiMainScreenRenderState) => void) | undefined;
  private readonly diagnosticCallback: ((diagnostic: ComponentDiagnostic) => void) | undefined;
  private readonly renderCompleteCallback: ((error?: unknown) => void) | undefined;
  private _renderCycles = 0;

  constructor(terminal: Terminal, options: CapturingTuiMainScreenOptions = {}) {
    super(terminal, options.showHardwareCursor ?? false);
    this.renderCallback = options.onRender;
    this.diagnosticCallback = options.onDiagnostic;
    this.renderCompleteCallback = options.onRenderComplete;
  }

  get renderCycles(): number { return this._renderCycles; }

  protected override doRender(): void {
    let failure: unknown;
    try {
      if (this.stopped) return;
      super.doRender();
      this._renderCycles += 1;
      if (!this.renderCallback) return;
      try {
        this.renderCallback(this.captureRenderState());
      } catch (error) {
        failure = error;
        if (!this.diagnosticCallback) return;
        try {
          this.diagnosticCallback({
            code: "render-failed",
            message: boundedDisplayError(error),
          });
        } catch {
          // Host diagnostics must not compromise TUI lifecycle.
        }
      }
    } catch (error) {
      failure = error;
      throw error;
    } finally {
      try { this.renderCompleteCallback?.(failure); } catch { /* activity cleanup is best effort */ }
    }
  }
}
