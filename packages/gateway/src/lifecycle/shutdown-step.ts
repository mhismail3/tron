export async function shutdownStep<T>(
  step: string,
  operation: () => Promise<T>,
  record: (step: string, durationMs: number) => void,
  now: () => number = performance.now.bind(performance),
): Promise<T> {
  const startedAt = now();
  try { return await operation(); }
  finally { record(step, now() - startedAt); }
}
