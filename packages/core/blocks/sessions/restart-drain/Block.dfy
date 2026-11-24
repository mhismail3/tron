// Block sessions/restart-drain: definitions and proofs of laws/sessions/RestartDrain.dfy.
include "../../../laws/sessions/RestartDrain.dfy"

module SessionsRestartDrain refines SessionsRestartDrainLaws {
  // ---------- definitions (compiled to JS) ----------
  // Every walk is tail-recursive, so it compiles to a loop and a snapshot of any size is safe.

  // Whether two states are the same.
  predicate SameState(a: State, b: State) { if a.active? then b.active? else if a.settling? then b.settling? else b.suspect? }

  // Whether two times are the same.
  predicate SameTime(a: Time, b: Time) { if a.Unset? then b.Unset? else b.At? && a.ms == b.ms }

  // Whether the n remaining blockers are exactly the listed ones and each is a suspect terminal-receipt persistence
  // write of a session.
  predicate AllOwners(n: Count, bs: List<Blocker>) {
    if bs.Nil? then n == 0
    else if n == 0 || !(bs.head.receipt && bs.head.state.suspect? && bs.head.session.InSession?) then false
    else AllOwners(n - 1, bs.tail)
  }

  // The first blocker admitted at the earliest admission time, of best and the blockers after it.
  function OldestOf(bs: List<Blocker>, best: Blocker): Blocker {
    if bs.Nil? then best
    else if bs.head.admitted.At? && (best.admitted.Unset? || bs.head.admitted.ms < best.admitted.ms) then OldestOf(bs.tail, bs.head)
    else OldestOf(bs.tail, best)
  }

  // The latest of latest and the progress times of the blockers of session s.
  function LatestFor(bs: List<Blocker>, s: Token, latest: Time): Time {
    if bs.Nil? then latest
    else if bs.head.session.InSession? && bs.head.session.session == s && bs.head.progress.At?
      && (latest.Unset? || bs.head.progress.ms > latest.ms) then LatestFor(bs.tail, s, bs.head.progress)
    else LatestFor(bs.tail, s, latest)
  }

  function Evaluate(count: Count, blockers: List<Blocker>, tracked: Tracked, now: Ms, limit: Ms): Step {
    if count == 0 then Step(Completed, Untracked)
    else if AllOwners(count, blockers) then Step(UnresolvedOwners, Untracked)
    else if blockers.Nil? then Step(Waiting, tracked)
    else
      var o := OldestOf(blockers.tail, blockers.head);
      var p := if o.session.NoSession? then o.progress else LatestFor(blockers, o.session.session, Unset);
      var since := if tracked.Tracking? && tracked.id == o.id && SameState(tracked.state, o.state)
        && SameTime(tracked.progress, p) && SameTime(tracked.admitted, o.admitted) then tracked.since
        else if p.At? then p.ms else if o.admitted.At? then o.admitted.ms else now;
      var age := if now <= since then 0 else now - since;
      Step(if age >= limit then Stalled(o.id, age) else Waiting, Tracking(o.id, o.state, p, o.admitted, since))
  }

  // ---------- proofs ----------

  // The items of a non-empty list: its head, then the items of its tail.
  lemma ElemsCons<T>(l: List<T>)
    requires l.Cons?
    ensures Elems(l) == [l.head] + Elems(l.tail) && |Elems(l)| == 1 + |Elems(l.tail)| && Elems(l)[1..] == Elems(l.tail)
  {}

  // SameState and SameTime are equality.
  lemma SameSpec(a: State, b: State, s: Time, t: Time)
    ensures SameState(a, b) <==> a == b
    ensures SameTime(s, t) <==> s == t
  {}

  // AllOwners holds exactly when n is the number of blockers and each is an owner.
  lemma AllOwnersSpec(n: Count, bs: List<Blocker>)
    ensures AllOwners(n, bs) <==> (n as int == |Elems(bs)| && forall i | 0 <= i < |Elems(bs)| :: Owner(Elems(bs)[i]))
    decreases bs
  {
    if bs.Cons? {
      ElemsCons(bs);
      if n != 0 { AllOwnersSpec(n - 1, bs.tail); }
      if forall i | 0 <= i < |Elems(bs)| :: Owner(Elems(bs)[i]) {
        assert Owner(Elems(bs)[0]);
        forall i | 0 <= i < |Elems(bs.tail)| ensures Owner(Elems(bs.tail)[i]) { assert Elems(bs.tail)[i] == Elems(bs)[i + 1]; }
      }
      if n != 0 && Owner(bs.head) && AllOwners(n - 1, bs.tail) {
        forall i | 0 <= i < |Elems(bs)| ensures Owner(Elems(bs)[i]) { if i > 0 { assert Elems(bs)[i] == Elems(bs.tail)[i - 1]; } }
      }
    }
  }

  // At most one blocker is the oldest.
  lemma OldestUnique(bs: seq<Blocker>, i: int, k: int)
    requires Oldest(bs, i) && Oldest(bs, k)
    ensures i == k
  {
    if i < k { assert Before(bs[k].admitted, bs[i].admitted); }
    if k < i { assert Before(bs[i].admitted, bs[k].admitted); }
  }

  // OldestOf, started with the oldest of the blockers already walked, finds the oldest of them and the rest.
  lemma OldestWalk(rest: List<Blocker>, pre: seq<Blocker>, m: int) returns (k: int)
    requires Oldest(pre, m)
    ensures Oldest(pre + Elems(rest), k) && OldestOf(rest, pre[m]) == (pre + Elems(rest))[k]
    decreases rest
  {
    if rest.Nil? {
      assert pre + Elems(rest) == pre;
      return m;
    }
    ElemsCons(rest);
    var h, next := rest.head, pre + [rest.head];
    assert pre + Elems(rest) == next + Elems(rest.tail);
    if h.admitted.At? && (pre[m].admitted.Unset? || h.admitted.ms < pre[m].admitted.ms) {
      assert Before(h.admitted, pre[m].admitted);
      forall j | 0 <= j < |pre| ensures Before(next[|pre|].admitted, next[j].admitted) {
        assert next[j] == pre[j];
        if j < m { assert Before(pre[m].admitted, pre[j].admitted); }
        if j > m { assert !Before(pre[j].admitted, pre[m].admitted); }
      }
      k := OldestWalk(rest.tail, next, |pre|);
    } else {
      assert !Before(next[|pre|].admitted, next[m].admitted);
      k := OldestWalk(rest.tail, next, m);
    }
  }

  // The blocker Evaluate tracks is the oldest blocker.
  lemma OldestSpec(blockers: List<Blocker>, i: int)
    requires Oldest(Elems(blockers), i)
    ensures OldestOf(blockers.tail, blockers.head) == Elems(blockers)[i]
  {
    ElemsCons(blockers);
    var k := OldestWalk(blockers.tail, [blockers.head], 0);
    OldestUnique(Elems(blockers), i, k);
  }

  // Later is associative.
  lemma LaterAssoc(a: Time, b: Time, c: Time)
    ensures Later(Later(a, b), c) == Later(a, Later(b, c))
  {}

  // LatestFor finds the latest of latest and the progress times of the blockers of session s.
  lemma LatestSpec(bs: List<Blocker>, s: Token, latest: Time)
    ensures LatestFor(bs, s, latest) == Later(latest, LatestOf(Elems(bs), s))
    decreases bs
  {
    if bs.Nil? {
      assert Later(latest, Unset) == latest;
    } else {
      ElemsCons(bs);
      var h := bs.head;
      var step := if h.session.InSession? && h.session.session == s && h.progress.At?
        && (latest.Unset? || h.progress.ms > latest.ms) then h.progress else latest;
      assert step == Later(latest, Own(h, s));
      LatestSpec(bs.tail, s, step);
      LaterAssoc(latest, Own(h, s), LatestOf(Elems(bs.tail), s));
    }
  }

  // Evaluate's progress time is the one that judges the oldest blocker.
  lemma ProgressSpec(blockers: List<Blocker>, o: Blocker)
    ensures (if o.session.NoSession? then o.progress else LatestFor(blockers, o.session.session, Unset))
      == Progress(Elems(blockers), o)
  {
    if o.session.InSession? { LatestSpec(blockers, o.session.session, Unset); }
  }

  lemma C1Completed(count: Count, blockers: List<Blocker>, tracked: Tracked, now: Ms, limit: Ms)
  {}

  lemma U1UnresolvedOwners(count: Count, blockers: List<Blocker>, tracked: Tracked, now: Ms, limit: Ms)
  { AllOwnersSpec(count, blockers); }

  lemma W1Unlisted(count: Count, blockers: List<Blocker>, tracked: Tracked, now: Ms, limit: Ms)
  {}

  // Under O1's premises: not every blocker is an owner, Evaluate takes the oldest blocker, and the progress time it
  // computes is the one that judges that blocker.
  lemma Facts(count: Count, blockers: List<Blocker>, i: int)
    requires count != 0 && !OnlyOwners(count, Elems(blockers)) && Oldest(Elems(blockers), i)
    ensures !AllOwners(count, blockers) && blockers.Cons? && OldestOf(blockers.tail, blockers.head) == Elems(blockers)[i]
    ensures var o := Elems(blockers)[i];
      (if o.session.NoSession? then o.progress else LatestFor(blockers, o.session.session, Unset)) == Progress(Elems(blockers), o)
  {
    AllOwnersSpec(count, blockers);
    OldestSpec(blockers, i);
    ProgressSpec(blockers, Elems(blockers)[i]);
  }

  lemma O1OldestTracked(count: Count, blockers: List<Blocker>, tracked: Tracked, now: Ms, limit: Ms, i: int)
  { Facts(count, blockers, i); }

  lemma R1TimerReset(count: Count, blockers: List<Blocker>, tracked: Tracked, now: Ms, limit: Ms, i: int)
  {
    Facts(count, blockers, i);
    var o := Elems(blockers)[i];
    if tracked.Tracking? {
      SameSpec(tracked.state, o.state, tracked.progress, Progress(Elems(blockers), o));
      SameSpec(tracked.state, o.state, tracked.admitted, o.admitted);
    }
  }

  lemma T1Stalled(count: Count, blockers: List<Blocker>, tracked: Tracked, now: Ms, limit: Ms, i: int)
  { Facts(count, blockers, i); }
}
