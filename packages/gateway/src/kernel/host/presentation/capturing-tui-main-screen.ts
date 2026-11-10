import {
  TuiMainScreen,
  type Terminal,
  type TuiMainScreenRenderState,
} from "../../pi/tui.js";
import type { ComponentDiagnostic } from "./recording-component.js";
import { boundedDisplayError } from "./terminal-sanitizer.js";

interface CapturingTuiMainScreenOptions {
  showHardwareCursor?: boolean;
  onRender?: (state: TuiMainScreenRenderState) => void;
  onRenderComplete?: (error?: unknown) => void;
  onDiagnostic?: (diagnostic: ComponentDiagnostic) => void;
}

export class CapturingTuiMainScreen extends TuiMainScreen {
  private readonly renderCallback: ((state: TuiMainScreenRenderState) => void) | undefined;
  private readonly diagnosticCallback: ((diagnostic: ComponentDiagnostic) => void) | undefined;
  private readonly renderCompleteCallback: ((error?: unknown) => void) | undefined;

  constructor(terminal: Terminal, options: CapturingTuiMainScreenOptions = {}) {
    super(terminal, options.showHardwareCursor ?? false);
    this.renderCallback = options.onRender;
    this.diagnosticCallback = options.onDiagnostic;
    this.renderCompleteCallback = options.onRenderComplete;
  }

  protected override doRender(): void {
    let failure: unknown;
    try {
      if (this.stopped) return;
      super.doRender();
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
        }
      }
    } catch (error) {
      failure = error;
      throw error;
    } finally {
      try { this.renderCompleteCallback?.(failure); } catch { }
    }
  }
}
