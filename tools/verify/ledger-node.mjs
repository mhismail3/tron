import { tap } from 'node:test/reporters';

export default async function* report(source) {
  async function* observe() {
    for await (const event of source) {
      if ((event.type === 'test:pass' || event.type === 'test:fail') && event.data.file && event.data.details?.type !== 'suite') {
        const data = event.data;
        process.stdout.write(`@@tron-test-case ${JSON.stringify({ file: data.file, name: `${data.line}:${data.column} ${data.name}`, outcome: data.skip || data.todo ? 'skipped' : event.type === 'test:pass' ? 'passed' : 'failed', seconds: data.details.duration_ms / 1000 })}\n`);
      }
      yield event;
    }
  }
  yield* tap(observe());
}
