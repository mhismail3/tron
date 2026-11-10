// Purpose: the one seeded generator for the proof tool tests. mulberry32 steps in exact 32-bit integer
// arithmetic, so its stream does not fall into the short cycles a floating-point LCG (whose product passes 2^53)
// falls into; rnd() returns a float in [0, 1).
export function mulberry32(seed) {
  let s = seed | 0;
  return () => {
    s = (s + 0x6d2b79f5) | 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
