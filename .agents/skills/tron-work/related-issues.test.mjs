// Isolated checks for the related-issue check's failure modes (SKILL.md, "Check
// for related issues"). The script runs exactly as codemode runs it: its source
// is the body of an async function (tools, input). Jev is replaced by a stand-in
// that enforces Jev's request bounds and answers by a marker word, so these
// tests catch what a live run on today's small corpus cannot: a request that
// breaks a bound at scale, a match lost in a later page, and a failure that
// reads as "nothing related".
// Run: node --test .agents/skills/tron-work/related-issues.test.mjs
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const source = readFileSync(new URL("./related-issues.js", import.meta.url), "utf8");
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const check = (tools, input) => new AsyncFunction("tools", "input", source)(tools, input);

const bytes = value => Buffer.byteLength(JSON.stringify(value), "utf8");
// Mirrors validatedContext in packages/gateway/src/knowledge/jev-client.ts.
function enforceJevBounds({ state, questions }) {
  const entries = Object.entries(questions);
  assert.ok(entries.length >= 1 && entries.length <= 16, `question count ${entries.length}`);
  assert.ok(bytes(state) <= 24000, `state ${bytes(state)} bytes`);
  for (const [id, question] of entries) {
    assert.match(id, /^[A-Za-z][A-Za-z0-9_-]{0,63}$/);
    const options = Object.keys(question.criteria).length;
    assert.ok(options >= 2 && options <= 255, `choice options ${options}`);
    assert.ok(bytes(state) + bytes(question) <= 28000, "state plus question");
  }
  assert.ok(bytes({ model: "jev-latest", state, questions }) <= 60000, "request body");
}

// Answers by marker: an option whose text holds MARKER wins stage 1; an issue
// whose title or body holds it is a duplicate in stage 2.
const MARKER = "zebrafish";
function fakeJev(log, override) {
  return {
    async jev(request) {
      log.push(request);
      enforceJevBounds(request);
      if (override) return override(request);
      const answers = {};
      for (const [key, question] of Object.entries(request.questions)) {
        const options = Object.keys(question.criteria);
        let winner;
        let probabilities;
        if (key === "match") {
          // A page holding the match gives it a narrow lead (0.12 against
          // 0.11s); every other page puts 0.2 on five noise options, which
          // outranks the match globally.
          const match = options.find(o => String(question.criteria[o]).includes(MARKER));
          const others = options.filter(o => o !== match && o !== "none");
          const weights = match ? [[match, 0.12], ...others.slice(0, 8).map(o => [o, 0.11])] : others.slice(0, 5).map(o => [o, 0.2]);
          probabilities = Object.fromEntries(options.map(o => [o, 0]));
          for (const [o, w] of weights) probabilities[o] = w;
          const total = Object.values(probabilities).reduce((a, b) => a + b, 0);
          probabilities.none += 1 - total;
          winner = Object.entries(probabilities).sort((a, b) => b[1] - a[1])[0][0];
        } else {
          const issue = request.state.issues[key];
          winner = `${issue.title} ${issue.body}`.includes(MARKER) ? "duplicate" : "unrelated";
          probabilities = Object.fromEntries(options.map(o => [o, o === winner ? 1 : 0]));
        }
        answers[key] = { type: "choice", choice: winner, probabilities, confidence: 0.9 };
      }
      return JSON.stringify({ answers, usage: { input_tokens: 1 }, estimatedCostCents: 0.01 });
    },
  };
}

const wide = "界🙂\"\n".repeat(400);
function issue(number, extra = {}) {
  return { number, state: "open", stateReason: null, epic: false, title: `Issue ${number} ${wide}`.slice(0, 200), labels: ["area:gateway", "kind:bug"], body: wide.slice(0, 1000), ...extra };
}

test("a maximal corpus stays within every Jev bound and still finds a match on the last page", async () => {
  const issues = [];
  for (let n = 1; n <= 500; n++) issues.push(issue(n));
  for (let n = 501; n <= 1000; n++) issues.push(issue(n, { state: "closed", stateReason: "completed" }));
  issues[999] = issue(1000, { state: "closed", stateReason: "completed", title: `Fix the ${MARKER} parser` });
  const log = [];
  const result = await check(fakeJev(log), { request: `${MARKER} ${wide.repeat(20)}`, corpus: { issues } });
  const titleCalls = log.filter(r => r.questions.match);
  assert.ok(titleCalls.length > 1, "a 1000-issue corpus needs more than one title page");
  assert.equal(new Set(titleCalls.flatMap(r => Object.keys(r.questions.match.criteria).filter(k => k !== "none"))).size, 1000, "every issue is offered exactly once");
  assert.deepEqual(result.hits.map(h => [h.number, h.verdict, h.state]), [[1000, "duplicate", "closed"]]);
  assert.equal(result.checked, 1000);
});

test("a Jev failure fails the check instead of reporting nothing related", async () => {
  const tools = fakeJev([], () => { throw new Error("Jev is not configured"); });
  await assert.rejects(check(tools, { request: "anything", corpus: { issues: [issue(1), issue(2)] } }), /title stage 1\/1: Jev is not configured/);
});

test("an answer missing an issue fails the check", async () => {
  const log = [];
  const good = fakeJev(log);
  const tools = { async jev(request) {
    const response = JSON.parse(await good.jev(request));
    if (!request.questions.match) delete response.answers.i2;
    return JSON.stringify(response);
  } };
  await assert.rejects(check(tools, { request: MARKER, corpus: { issues: [issue(1), issue(2, { title: MARKER })] } }), /invalid Jev answer for i2/);
});

test("an empty corpus makes no Jev call and finds nothing", async () => {
  const log = [];
  const result = await check(fakeJev(log), { request: "anything", corpus: { issues: [] } });
  assert.equal(log.length, 0);
  assert.deepEqual(result.hits, []);
});

test("a missing corpus or request is an error, not an empty result", async () => {
  await assert.rejects(check(fakeJev([]), { request: "x" }), /corpus/);
  await assert.rejects(check(fakeJev([]), { request: "  ", corpus: { issues: [] } }), /non-empty request/);
});
