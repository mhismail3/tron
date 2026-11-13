// Preserve Node TAP output while exposing per-test evidence to the ledger runner.
import { tap } from 'node:test/reporters';
import { hostSampler } from './ledger-host.mjs';

export default async function* report(source) {
  const sample = hostSampler();
  async function* observe() {
    for await (const event of source) {
      if ((event.type === 'test:pass' || event.type === 'test:fail') && event.data.file && event.data.details?.type !== 'suite') {
        const data = event.data;
        process.stdout.write(`@@tron-test-case ${JSON.stringify({ file: data.file, name: `${data.line}:${data.column} ${data.name}`, outcome: data.skip || data.todo ? 'skipped' : event.type === 'test:pass' ? 'passed' : 'failed', seconds: data.details.duration_ms / 1000, ...sample() })}\n`);
      }
      yield event;
    }
  }
  yield* tap(observe());
}
