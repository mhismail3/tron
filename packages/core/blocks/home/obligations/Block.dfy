// Block home/obligations: definitions and proofs of laws/home/Obligations.dfy.
include "../../../laws/home/Obligations.dfy"

module HomeObligations refines HomeObligationsLaws {
  // ---------- definitions (compiled to JS) ----------

  predicate Owed(s: State) { s.request? || s.reopened? }

  function Step(p: Prior, a: State, size: Count): Outcome {
    if a.request? then (if p.Present? then Contradictory else if size >= Cap then Full else Next(request))
    else if p.Absent? then Contradictory
    else if a.reopened? then (if Owed(p.state) then Contradictory else Next(reopened))
    else if Owed(p.state) || (a.verified? && p.state.reportedDone?) then Next(a)
    else Contradictory
  }

  // ---------- proofs ----------

  lemma O1Owed(s: State) {}

  lemma T1Transitions(p: Prior, a: State, size: Count) {}

  lemma C1Contradiction(p: Prior, a: State, size: Count) {}

  lemma K1Cap(p: Prior, a: State, size: Count) {}
}
