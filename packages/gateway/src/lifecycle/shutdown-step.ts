export async function shutdownStep<T>(
  step: string,
  operation: () => Promise<T>,
  record: (step: string, durationMs: number) => void,
): Promise<T> {
  const startedAt = performance.now();
  try { return await operation(); }
  finally { record(step, performance.now() - startedAt); }
}
