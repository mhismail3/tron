// Stand-in shadow comparison for tools/proof/tests/gates.test.mjs: prints what a comparison would and exits
// as told, so `proof shadow` can be shown to record each outcome correctly.
const outcomes = {
  match: [{ requests: 3, agree: 3, diffs: [] }, 0],
  mismatch: [{ requests: 3, agree: 2, diffs: [{ input: 1 }] }, 1],
  crash: [{ requests: 3, agree: 3, diffs: [] }, 3],
  garbage: ["not json", 0],
  none: [{ requests: 0, agree: 0, diffs: [] }, 0],
  lie: [{ requests: 3, agree: 2, diffs: [{ input: 1 }] }, 0],
};
const [output, code] = outcomes[process.argv[2]];
console.log(typeof output === "string" ? output : JSON.stringify(output));
process.exitCode = code;
