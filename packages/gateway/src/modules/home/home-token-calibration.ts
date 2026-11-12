export interface HomeTokenEstimate {
  memory: number;
  other: number;
}

interface Sums {
  tokens: number;
  estimate: number;
  samples: number;
}

interface ModelSums {
  whole: Sums;
  memory: Sums;
  other: Sums;
}

const PLAUSIBLE_MINIMUM = 0.5;
const PLAUSIBLE_MAXIMUM = 4;
const MINIMUM_STEP_ESTIMATE = 64;
const MINIMUM_STEP_SAMPLES = 3;
const RECENT_SAMPLES_KEEP = 0.8;
const MAXIMUM_MODELS = 8;

function plausible(tokens: number, estimate: number): boolean {
  return tokens > 0 && estimate > 0 && tokens / estimate >= PLAUSIBLE_MINIMUM && tokens / estimate <= PLAUSIBLE_MAXIMUM;
}

function add(sums: Sums, tokens: number, estimate: number): void {
  sums.tokens = sums.tokens * RECENT_SAMPLES_KEEP + tokens;
  sums.estimate = sums.estimate * RECENT_SAMPLES_KEEP + estimate;
  sums.samples += 1;
}

const empty = (): Sums => ({ tokens: 0, estimate: 0, samples: 0 });

export class HomeTokenCalibration {
  private readonly models = new Map<string, ModelSums>();
  private previous: { model: string; activation: string; tokens: number; estimate: HomeTokenEstimate } | undefined;

  factors(model: string): HomeTokenEstimate {
    const sums = this.models.get(model);
    if (!sums) return { memory: 1, other: 1 };
    const whole = sums.whole.tokens / sums.whole.estimate;
    const split = sums.other.samples >= MINIMUM_STEP_SAMPLES && sums.memory.samples > 0;
    return split
      ? { memory: sums.memory.tokens / sums.memory.estimate, other: sums.other.tokens / sums.other.estimate }
      : { memory: whole, other: whole };
  }

  observe(model: string, activation: string, estimate: HomeTokenEstimate, tokens: number): boolean {
    if (!plausible(tokens, estimate.memory + estimate.other)) return false;
    const sums = this.models.get(model) ?? { whole: empty(), memory: empty(), other: empty() };
    this.models.delete(model);
    if (this.models.size >= MAXIMUM_MODELS) this.models.delete(this.models.keys().next().value!);
    this.models.set(model, sums);
    const previous = this.previous?.model === model && this.previous.activation === activation ? this.previous : undefined;
    this.previous = { model, activation, tokens, estimate };
    add(sums.whole, tokens, estimate.memory + estimate.other);
    if (previous && previous.estimate.memory === estimate.memory) {
      const grown = estimate.other - previous.estimate.other;
      if (grown >= MINIMUM_STEP_ESTIMATE && plausible(tokens - previous.tokens, grown)) add(sums.other, tokens - previous.tokens, grown);
    }
    if (sums.other.samples < MINIMUM_STEP_SAMPLES || estimate.memory === 0) return true;
    const memory = tokens - estimate.other * sums.other.tokens / sums.other.estimate;
    if (plausible(memory, estimate.memory)) add(sums.memory, memory, estimate.memory);
    return true;
  }
}
