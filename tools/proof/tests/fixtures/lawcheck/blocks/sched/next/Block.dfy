// Proofs of the fixture block sched/next.
include "../../../laws/sched/Next.dfy"
abstract module NextProof refines NextLaws {
  lemma NextAfter(anchor: int, every: int, after: int)
  {
    if after >= anchor { var q := A.DivFacts(after - anchor, every); A.MulMono(q, q + 1, every); }
  }
}
