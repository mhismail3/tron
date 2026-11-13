// Record native Vitest case results and execution-host readings for the Gateway runner.
import { appendFileSync } from 'node:fs';
import { hostSampler } from './ledger-host.mjs';

export default class LedgerReporter {
  sample = hostSampler();

  onTestCaseResult(test) {
    const task = test.task;
    const titles = [task.name];
    for (let suite = task.suite; suite; suite = suite.suite) titles.unshift(suite.name);
    const outcome = { pass: 'passed', fail: 'failed', skip: 'skipped', todo: 'skipped' }[task.result?.state || task.mode];
    if (outcome) appendFileSync(process.env.TRON_TEST_LEDGER_CASES, `${JSON.stringify({ file: task.file.filepath, fullName: titles.join(' '), outcome, seconds: (task.result?.duration || 0) / 1000, ...this.sample() })}\n`);
  }
}
