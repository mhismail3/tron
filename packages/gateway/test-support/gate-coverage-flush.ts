import { afterAll } from "vitest";
import { takeCoverage } from "node:v8";

// Vitest executes tests in a worker isolate, whose V8 profile is not flushed
// with the parent runner's exit profile. In the observer-only config this hook
// flushes that worker after test-file afterAll hooks have completed.
if (process.env.NODE_V8_COVERAGE) {
  afterAll(() => takeCoverage());
}
