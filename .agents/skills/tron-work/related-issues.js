// Related-issue check: the body of an async function (tools, input) run by the
// codemode tool (SKILL.md, "Check for related issues"). It sends only the
// request and the `scripts/tron work issues` corpus to Jev, in two stages:
//   1. one choice over every issue title (paged when the corpus exceeds one call);
//   2. a duplicate/related/unrelated verdict per shortlisted issue, with its body.
// input: { request: string, corpus: { issues: [...] } }
// It returns every non-unrelated verdict, or throws; a failed check never reads
// as "no related issues".

// Jev's request bounds (packages/gateway/src/knowledge/jev-client.ts). Every
// request is checked against them before dispatch; the stage budgets below
// leave headroom under each.
const JEV = { state: 24000, stateQuestion: 28000, body: 60000, questions: 16, options: 255 };
const REQUEST_BYTES = 4000;
const TITLE_CHUNK_BYTES = 20000;
const TITLE_CHUNK_OPTIONS = 200;
const VERDICT_STATE_BYTES = 22000;
const VERDICT_BATCH = 12;
const SHORTLIST_MAX = 24;
const SHORTLIST_FLOOR = 0.002;
const MAX_CHARGE_CENTS = 0.5;

function utf8Bytes(text) {
  let bytes = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (code < 0x80) bytes += 1;
    else if (code < 0x800) bytes += 2;
    else if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) { bytes += 4; i++; }
    else bytes += 3;
  }
  return bytes;
}
function jsonBytes(value) { return utf8Bytes(JSON.stringify(value)); }
// Clips by encoded JSON size, so escapes in hostile text cannot overrun a bound.
function clip(text, maxBytes) {
  let out = String(text);
  while (jsonBytes(out) > maxBytes) out = out.slice(0, Math.max(0, Math.floor(out.length * 0.9) - 1));
  // Never leave a lone high surrogate at the cut.
  return /[\ud800-\udbff]$/.test(out) ? out.slice(0, -1) : out;
}
function assertBounds(state, questions) {
  const entries = Object.entries(questions);
  if (!entries.length || entries.length > JEV.questions) throw new Error(`Jev request has ${entries.length} questions`);
  const stateBytes = jsonBytes(state);
  if (stateBytes > JEV.state) throw new Error(`Jev state is ${stateBytes} bytes`);
  for (const [, question] of entries) {
    if (question.type === "choice" && Object.keys(question.criteria).length > JEV.options) throw new Error("Jev choice has too many options");
    if (stateBytes + jsonBytes(question) > JEV.stateQuestion) throw new Error("Jev state plus question exceeds its bound");
  }
  if (jsonBytes({ model: "jev-latest", state, questions }) > JEV.body) throw new Error("Jev request body exceeds its bound");
}
async function classify(stage, state, questions) {
  assertBounds(state, questions);
  let response;
  try {
    response = JSON.parse(await tools.jev({ maxChargeCents: MAX_CHARGE_CENTS, state, questions }));
  } catch (error) {
    throw new Error(`related-issue check failed in ${stage}: ${error && error.message ? error.message : error}`);
  }
  for (const [key, question] of Object.entries(questions)) {
    const answer = response && response.answers && response.answers[key];
    const options = Object.keys(question.criteria);
    if (!answer || answer.type !== "choice" || !options.includes(answer.choice) || !answer.probabilities
      || options.some(option => typeof answer.probabilities[option] !== "number")) {
      throw new Error(`related-issue check failed in ${stage}: invalid Jev answer for ${key}`);
    }
  }
  return response;
}
function chunkTitles(issues) {
  const chunks = [];
  let current = {};
  let bytes = 0;
  for (const issue of issues) {
    const criterion = clip(`${issue.title} [${issue.labels.join(", ")}]${issue.state === "closed" ? ` (closed${issue.stateReason ? `: ${issue.stateReason}` : ""})` : ""}`, 1200);
    const size = jsonBytes(issue.key) + jsonBytes(criterion) + 2;
    if (Object.keys(current).length && (bytes + size > TITLE_CHUNK_BYTES || Object.keys(current).length >= TITLE_CHUNK_OPTIONS)) {
      chunks.push(current); current = {}; bytes = 0;
    }
    current[issue.key] = criterion;
    bytes += size;
  }
  if (Object.keys(current).length) chunks.push(current);
  return chunks;
}

if (!input || typeof input.request !== "string" || !input.request.trim()) throw new Error("related-issue check needs a non-empty request");
if (!input.corpus || !Array.isArray(input.corpus.issues)) throw new Error("related-issue check needs the `scripts/tron work issues` corpus");
const started = Date.now();
const request = clip(input.request.trim(), REQUEST_BYTES);
const issues = input.corpus.issues.map(issue => ({
  ...issue, key: `i${issue.number}`, labels: Array.isArray(issue.labels) ? issue.labels : [], body: String(issue.body || ""), title: String(issue.title || ""),
}));
const byKey = Object.fromEntries(issues.map(issue => [issue.key, issue]));
let calls = 0;
let cents = 0;
function account(response) { calls += 1; cents += Number(response.estimatedCostCents) || 0; }

if (!issues.length) return { hits: [], checked: 0, shortlisted: 0, calls, cents, ms: Date.now() - started };

// Stage 1: titles. Each chunk is an independent choice with its own "none".
const chunks = chunkTitles(issues);
const instructions = "The user asked an agent to do the request in state. Pick the GitHub issue that the request duplicates or most directly overlaps (same bug, same feature, or same code area and goal).";
const titleResults = await Promise.all(chunks.map(async (criteria, index) => {
  const questions = { match: { type: "choice", instructions, criteria: { ...criteria, none: "None: no listed issue covers this request" } } };
  const response = await classify(`title stage ${index + 1}/${chunks.length}`, { request }, questions);
  account(response);
  return Object.entries(response.answers.match.probabilities).filter(([key]) => key !== "none");
}));
// Each chunk's leaders are always kept, so a match in one page is never
// crowded out by noise from the others; the remaining slots go to the most
// probable of the rest.
const perChunk = Math.max(1, Math.ceil(8 / chunks.length));
const ranked = titleResults.map(entries => entries.sort((a, b) => b[1] - a[1]));
const leaders = ranked.flatMap(entries => entries.slice(0, perChunk));
const rest = ranked.flatMap(entries => entries.slice(perChunk)).filter(([, p]) => p >= SHORTLIST_FLOOR).sort((a, b) => b[1] - a[1]);
const shortlist = leaders.concat(rest).slice(0, Math.max(SHORTLIST_MAX, leaders.length)).map(([key]) => key);

// Stage 2: bodies. Batches share the state budget evenly.
const batches = [];
for (let i = 0; i < shortlist.length; i += VERDICT_BATCH) batches.push(shortlist.slice(i, i + VERDICT_BATCH));
const verdicts = (await Promise.all(batches.map(async (keys, index) => {
  const entries = keys.map(key => [key, { title: byKey[key].title, labels: byKey[key].labels.join(", "), state: byKey[key].state, body: "" }]);
  const fixed = jsonBytes({ request, issues: Object.fromEntries(entries) });
  const perBody = Math.max(0, Math.floor((VERDICT_STATE_BYTES - fixed) / keys.length) - 8);
  for (const [key, entry] of entries) entry.body = clip(byKey[key].body, perBody);
  const state = { request, issues: Object.fromEntries(entries) };
  const questions = Object.fromEntries(keys.map(key => [key, { type: "choice", instructions: `How does the request relate to issue ${key}? Judge only ${key}.`, criteria: {
    duplicate: `Doing the request would fix or implement the same bug or feature ${key} tracks`,
    related: `Same subsystem, symptom, or goal as ${key} even if scoped differently; the agent should read ${key} before starting`,
    unrelated: `Different subsystem and goal from ${key}`,
  } }]));
  const response = await classify(`verdict stage ${index + 1}/${batches.length}`, state, questions);
  account(response);
  return keys.map(key => [key, response.answers[key]]);
}))).flat();

const hits = verdicts
  .filter(([, answer]) => answer.choice !== "unrelated")
  .map(([key, answer]) => {
    const issue = byKey[key];
    return {
      number: issue.number, title: issue.title, state: issue.state, stateReason: issue.stateReason || null, epic: Boolean(issue.epic),
      verdict: answer.choice, score: Math.round((answer.probabilities.duplicate + 0.5 * answer.probabilities.related) * 100) / 100,
    };
  })
  .sort((a, b) => b.score - a.score);
return { hits, checked: issues.length, shortlisted: shortlist.length, calls, cents: Math.round(cents * 10000) / 10000, ms: Date.now() - started };
