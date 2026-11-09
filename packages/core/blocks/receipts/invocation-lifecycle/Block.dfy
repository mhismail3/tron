// Block receipts/invocation-lifecycle: definitions and proofs of laws/receipts/InvocationLifecycle.dfy.
include "../../../laws/receipts/InvocationLifecycle.dfy"

module ReceiptsInvocationLifecycle refines ReceiptsInvocationLifecycleLaws {
  // ---------- definitions (compiled to JS) ----------

  // Machine integers (compiled to JS numbers) for the by-method loop indices and tokens.
  newtype i53 = x: int | -0x20_0000_0000_0000 < x < 0x20_0000_0000_0000
  const LIMIT: i53 := 0x10_0000

  // The receipt's invocation and entry tokens are array indices below n.
  ghost predicate InRange(r: Receipt, n: i53) {
    0 <= r.inv < n as int && (r.entry.Some? ==> 0 <= r.entry.v < n as int)
  }

  // The index of the first state of invocation inv, or -1.
  function FindIndex(projs: seq<Proj>, inv: int): int
    decreases |projs|
    ensures -1 <= FindIndex(projs, inv) < |projs|
  {
    if |projs| == 0 then -1
    else if projs[0].inv == inv then 0
    else var k := FindIndex(projs[1..], inv); if k < 0 then -1 else k + 1
  }

  predicate Legal(from: Life, to: MaybeLife, settle: bool) {
    if TerminalLife(from) || to.NoLife? then false
    else if settle then TerminalLife(to.l)
    else
      // Written without set literals: the compiled code would build a set on every call.
      var t := to.l;
      match from
      case Staged => t.Accepted? || t.Queued? || t.Running? || t.WaitingForInput? || t.Retrying? || t.Settling?
      case Accepted => t.Queued? || t.Running? || t.WaitingForInput? || t.Retrying? || t.Settling?
      case Queued => t.Running? || t.Settling?
      case Running => t.WaitingForInput? || t.Retrying? || t.Settling?
      case WaitingForInput => t.Running? || t.Settling?
      case Retrying => t.Running? || t.Settling?
      case _ => false
  }

  function StepOf(st: State, r: Receipt): Step {
    var i := FindIndex(st.projs, r.inv);
    if r.kind.Start? then
      if i >= 0 then Refused(DuplicateStart)
      else Next(st.(projs := st.projs + [Proj(r.inv, r.op, r.src, r.name, r.origin,
        if r.life.LifeOf? then r.life.l else Accepted, None, NoFlag, r.sequence, r.at, false)]))
    else if i < 0 then Refused(NoStart)
    else
      var p := st.projs[i];
      if p.op != r.op || p.src != r.src then Refused(OwnershipChanged)
      else if r.kind.Binding? && r.entry in st.entries then Refused(EntryBound)
      else if r.kind.Binding? && r.inv in st.bound then Refused(InvocationBound)
      else if r.name.Some? && r.name != p.name then Refused(NameChanged)
      else if r.origin.Some? && r.origin != p.origin then Refused(OriginChanged)
      else if r.kind.Terminal? && p.terminal && r.life != LifeOf(p.life) then Refused(ContradictoryTerminal)
      else if r.kind.Terminal? && !p.terminal && !Legal(p.life, r.life, true) then Refused(IllegalTerminal)
      else if r.kind.Transition? && !Legal(p.life, r.life, false) then Refused(IllegalTransition)
      else
        var settled := p.terminal || r.kind.Terminal?;
        Next(State(st.projs[i := p.(
            life := if r.life.LifeOf? && (r.kind.Terminal? || !settled) then r.life.l else p.life,
            entry := if r.entry.Some? then r.entry else p.entry,
            retryable := if r.retryable.FlagOf? then r.retryable else p.retryable,
            updated := r.at, terminal := settled)],
          if r.kind.Binding? then st.entries + [r.entry] else st.entries,
          if r.kind.Binding? then st.bound + [r.inv] else st.bound))
  }

  // The receipts from position k folded into the state.
  function RunAt(st: State, rs: seq<Receipt>, k: nat): Outcome
    requires k <= |rs|
    decreases |rs| - k
  {
    if k == |rs| then Projected(st.projs)
    else match StepOf(st, rs[k])
      case Refused(why) => Rejected(why, k)
      case Next(st2) => RunAt(st2, rs, k + 1)
  }

  function Project(rs: seq<Receipt>): Outcome {
    ProjectFast(rs)
  }

  // The fold, compiled from the method below and proven equal to RunAt. (Dafny 4.11 drops a `by method` on a
  // function that refines a laws declaration, neither verifying nor compiling it, so it sits on this function.)
  function ProjectFast(rs: seq<Receipt>): Outcome {
    RunAt(State([], [], []), rs, 0)
  } by method {
    // The same fold with mutable arrays indexed by the call's tokens and machine-integer indices, so each receipt
    // costs O(1) when the tokens are dense, as the shell numbers them (arrays are sized by the largest token); tokens
    // outside [0, LIMIT) take the fold above.
    if |rs| >= LIMIT as int { return RunAt(State([], [], []), rs, 0); }
    var len := |rs| as i53;
    var n: i53 := 1;
    var k: i53 := 0;
    while k < len
      invariant 0 <= k <= len && 1 <= n <= LIMIT
      invariant forall j | 0 <= j < k as int :: InRange(rs[j], n)
    {
      var r := rs[k];
      if !(0 <= r.inv < LIMIT as int) || (r.entry.Some? && !(0 <= r.entry.v < LIMIT as int)) {
        return RunAt(State([], [], []), rs, 0);
      }
      if r.inv as i53 >= n { n := r.inv as i53 + 1; }
      if r.entry.Some? && r.entry.v as i53 >= n { n := r.entry.v as i53 + 1; }
      k := k + 1;
    }
    var slot := new i53[n](_ => -1);
    var invBound := new bool[n](_ => false);
    var entryBound := new bool[n](_ => false);
    var noneBound := false;
    var projs := new Proj[len](_ => Proj(0, 0, 0, None, None, Staged, None, NoFlag, 0, 0, false));
    var count: i53 := 0;
    ghost var st := State([], [], []);
    k := 0;
    while k < len
      invariant 0 <= count <= k <= len && st.projs == projs[..count]
      invariant forall t | 0 <= t < n :: slot[t] as int == FindIndex(st.projs, t as int)
      invariant forall t | 0 <= t < n :: invBound[t] == (t as int in st.bound)
      invariant forall t | 0 <= t < n :: entryBound[t] == (Some(t as int) in st.entries)
      invariant noneBound == (None in st.entries)
      invariant RunAt(st, rs, k as int) == RunAt(State([], [], []), rs, 0)
    {
      var r := rs[k];
      assert InRange(r, n);
      var inv := r.inv as i53;
      var i := slot[inv];
      assert i as int == FindIndex(st.projs, r.inv);
      if r.kind.Start? {
        if i >= 0 { return Rejected(DuplicateStart, k as int); }
        var p := Proj(r.inv, r.op, r.src, r.name, r.origin, if r.life.LifeOf? then r.life.l else Accepted, None, NoFlag, r.sequence, r.at, false);
        FindIndexAppend(st.projs, p);
        projs[count] := p;
        slot[inv] := count;
        st := st.(projs := st.projs + [p]);
        count := count + 1;
        assert st.projs == projs[..count];
      } else {
        if i < 0 { return Rejected(NoStart, k as int); }
        var p := projs[i];
        var entryIn := if r.entry.Some? then entryBound[r.entry.v as i53] else noneBound;
        if p.op != r.op || p.src != r.src { return Rejected(OwnershipChanged, k as int); }
        if r.kind.Binding? && entryIn { return Rejected(EntryBound, k as int); }
        if r.kind.Binding? && invBound[inv] { return Rejected(InvocationBound, k as int); }
        if r.name.Some? && r.name != p.name { return Rejected(NameChanged, k as int); }
        if r.origin.Some? && r.origin != p.origin { return Rejected(OriginChanged, k as int); }
        if r.kind.Terminal? && p.terminal && r.life != LifeOf(p.life) { return Rejected(ContradictoryTerminal, k as int); }
        if r.kind.Terminal? && !p.terminal && !Legal(p.life, r.life, true) { return Rejected(IllegalTerminal, k as int); }
        if r.kind.Transition? && !Legal(p.life, r.life, false) { return Rejected(IllegalTransition, k as int); }
        var settled := p.terminal || r.kind.Terminal?;
        var q := p.(life := if r.life.LifeOf? && (r.kind.Terminal? || !settled) then r.life.l else p.life,
          entry := if r.entry.Some? then r.entry else p.entry,
          retryable := if r.retryable.FlagOf? then r.retryable else p.retryable,
          updated := r.at, terminal := settled);
        FindIndexUpdate(st.projs, i as int, q);
        projs[i] := q;
        if r.kind.Binding? {
          invBound[inv] := true;
          if r.entry.Some? { entryBound[r.entry.v as i53] := true; } else { noneBound := true; }
        }
        st := StepOf(st, r).st;
        assert st.projs == projs[..count];
      }
      k := k + 1;
    }
    return Projected(projs[..count]);
  }

  // ---------- proofs ----------

  // Appending a new invocation's state finds it at the end and finds every other invocation where it was.
  lemma FindIndexAppend(projs: seq<Proj>, p: Proj)
    requires FindIndex(projs, p.inv) < 0
    ensures forall t :: FindIndex(projs + [p], t) == if t == p.inv then |projs| else FindIndex(projs, t)
  {
    forall t ensures FindIndex(projs + [p], t) == if t == p.inv then |projs| else FindIndex(projs, t) {
      FindIndexSpec(projs, t);
      FindIndexSpec(projs + [p], t);
      if t == p.inv { FindIndexAt(projs + [p], t, |projs|); }
      else if FindIndex(projs, t) >= 0 { FindIndexAt(projs + [p], t, FindIndex(projs, t)); }
      else { assert forall i | 0 <= i < |projs + [p]| :: (projs + [p])[i].inv != t; }
    }
  }

  // Updating an invocation's state in place (same invocation) finds every invocation where it was.
  lemma FindIndexUpdate(projs: seq<Proj>, i: int, q: Proj)
    requires 0 <= i < |projs| && q.inv == projs[i].inv
    ensures forall t :: FindIndex(projs[i := q], t) == FindIndex(projs, t)
  {
    forall t ensures FindIndex(projs[i := q], t) == FindIndex(projs, t) {
      FindIndexSpec(projs, t);
      FindIndexSpec(projs[i := q], t);
      if FindIndex(projs, t) >= 0 { FindIndexAt(projs[i := q], t, FindIndex(projs, t)); }
      else { var u := projs[i := q]; assert forall j | 0 <= j < |u| :: u[j].inv != t; }
    }
  }

  lemma L1LegalMoves(from: Life, to: Life, settle: bool) {}

  // FindIndex finds the first state of the invocation, or -1 when there is none.
  lemma FindIndexSpec(projs: seq<Proj>, inv: int)
    decreases |projs|
    ensures var k := FindIndex(projs, inv);
      (k >= 0 <==> exists i | 0 <= i < |projs| :: projs[i].inv == inv)
      && (k >= 0 ==> projs[k].inv == inv && forall j | 0 <= j < k :: projs[j].inv != inv)
  {
    if |projs| > 0 && projs[0].inv != inv {
      FindIndexSpec(projs[1..], inv);
      if exists i | 0 <= i < |projs| :: projs[i].inv == inv {
        var i :| 0 <= i < |projs| && projs[i].inv == inv;
        assert projs[1..][i - 1].inv == inv;
      }
    }
  }

  // The first state of the invocation is the one at index i.
  lemma FindIndexAt(projs: seq<Proj>, inv: int, i: int)
    requires 0 <= i < |projs| && projs[i].inv == inv && forall j | 0 <= j < i :: projs[j].inv != inv
    ensures FindIndex(projs, inv) == i
  { FindIndexSpec(projs, inv); }

  lemma RunAtRun(st: State, rs: seq<Receipt>, k: nat)
    requires k <= |rs|
    decreases |rs| - k
    ensures RunAt(st, rs, k) == Run(st, rs[k..], k)
  {
    if k < |rs| {
      assert rs[k..][0] == rs[k] && rs[k..][1..] == rs[k + 1..];
      if StepOf(st, rs[k]).Next? { RunAtRun(StepOf(st, rs[k]).st, rs, k + 1); }
    }
  }

  lemma H1History(rs: seq<Receipt>)
  { RunAtRun(State([], [], []), rs, 0); assert rs[0..] == rs; }

  lemma S1Start(st: State, r: Receipt)
  { FindIndexSpec(st.projs, r.inv); }

  lemma S2Checks(st: State, r: Receipt, i: int)
  { FindIndexAt(st.projs, r.inv, i); }

  lemma S3NoStart(st: State, r: Receipt)
  { FindIndexSpec(st.projs, r.inv); }

  lemma S4Settle(st: State, r: Receipt, i: int)
  { FindIndexAt(st.projs, r.inv, i); }

  lemma S5Update(st: State, r: Receipt, i: int)
  { FindIndexAt(st.projs, r.inv, i); }
  lemma P1Progress(inv: int, op: int, src: int, origin: int, e: int, s: int)
  {
    var r0 := Receipt(inv, op, src, Start, LifeOf(Staged), None, Some(origin), None, NoFlag, s, 1);
    var r1 := Receipt(inv, op, src, Transition, LifeOf(Accepted), None, None, None, NoFlag, s, 2);
    var r2 := Receipt(inv, op, src, Transition, LifeOf(Running), None, None, None, NoFlag, s, 3);
    var r3 := Receipt(inv, op, src, Terminal, LifeOf(Completed), None, None, None, FlagOf(false), s, 4);
    var r4 := Receipt(inv, op, src, Binding, NoLife, None, None, Some(e), NoFlag, s, 5);
    var rs := [r0, r1, r2, r3, r4];
    var st0 := State([], [], []);
    var p0 := Proj(inv, op, src, None, Some(origin), Staged, None, NoFlag, s, 1, false);
    assert StepOf(st0, r0) == Next(State([p0], [], []));
    var st1 := State([p0.(life := Accepted, updated := 2)], [], []);
    assert StepOf(State([p0], [], []), r1) == Next(st1);
    var st2 := State([p0.(life := Running, updated := 3)], [], []);
    assert StepOf(st1, r2) == Next(st2);
    var st3 := State([p0.(life := Completed, retryable := FlagOf(false), updated := 4, terminal := true)], [], []);
    assert StepOf(st2, r3) == Next(st3);
    var st4 := State([p0.(life := Completed, entry := Some(e), retryable := FlagOf(false), updated := 5, terminal := true)], [Some(e)], [inv]);
    assert StepOf(st3, r4) == Next(st4);
    assert rs[0] == r0 && rs[1] == r1 && rs[2] == r2 && rs[3] == r3 && rs[4] == r4;
    assert RunAt(st4, rs, 5) == Projected(st4.projs);
    assert RunAt(st3, rs, 4) == RunAt(st4, rs, 5);
    assert RunAt(st2, rs, 3) == RunAt(st3, rs, 4);
    assert RunAt(st1, rs, 2) == RunAt(st2, rs, 3);
    assert RunAt(State([p0], [], []), rs, 1) == RunAt(st1, rs, 2);
    assert RunAt(st0, rs, 0) == RunAt(State([p0], [], []), rs, 1);
  }

  // Settled: the state holds a settled state of inv with lifecycle l.
  ghost predicate SettledIn(st: State, inv: int, l: Life) {
    exists i | 0 <= i < |st.projs| :: st.projs[i].inv == inv && st.projs[i].terminal && st.projs[i].life == l
  }

  // An accepted receipt keeps a settled invocation settled with its lifecycle.
  lemma StepKeepsSettled(st: State, r: Receipt, inv: int, l: Life)
    requires SettledIn(st, inv, l) && StepOf(st, r).Next?
    ensures SettledIn(StepOf(st, r).st, inv, l)
  {
    var w :| 0 <= w < |st.projs| && st.projs[w].inv == inv && st.projs[w].terminal && st.projs[w].life == l;
    var st2 := StepOf(st, r).st;
    var i := FindIndex(st.projs, r.inv);
    if r.kind.Start? { assert st2.projs[w] == st.projs[w]; }
    else if i != w { assert st2.projs[w] == st.projs[w]; }
    else { assert st2.projs[w].inv == inv && st2.projs[w].terminal && st2.projs[w].life == l; }
  }

  // An accepted terminal receipt leaves its invocation settled with the receipt's lifecycle.
  lemma StepSettles(st: State, r: Receipt)
    requires r.kind.Terminal? && StepOf(st, r).Next?
    ensures r.life.LifeOf? && SettledIn(StepOf(st, r).st, r.inv, r.life.l)
  {
    var i := FindIndex(st.projs, r.inv);
    FindIndexSpec(st.projs, r.inv);
    assert i >= 0;
    var st2 := StepOf(st, r).st;
    assert st2.projs[i].inv == r.inv && st2.projs[i].terminal;
  }

  lemma RunKeepsSettled(st: State, rs: seq<Receipt>, k: int, inv: int, l: Life)
    requires SettledIn(st, inv, l) && Run(st, rs, k).Projected?
    decreases |rs|
    ensures SettledIn(State(Run(st, rs, k).projs, [], []), inv, l)
  {
    if |rs| > 0 {
      StepKeepsSettled(st, rs[0], inv, l);
      RunKeepsSettled(StepOf(st, rs[0]).st, rs[1..], k + 1, inv, l);
    }
  }

  lemma RunSettles(st: State, rs: seq<Receipt>, k: int, m: int)
    requires Run(st, rs, k).Projected? && 0 <= m < |rs| && rs[m].kind.Terminal?
    decreases |rs|
    ensures rs[m].life.LifeOf? && SettledIn(State(Run(st, rs, k).projs, [], []), rs[m].inv, rs[m].life.l)
  {
    var st2 := StepOf(st, rs[0]).st;
    if m == 0 {
      StepSettles(st, rs[0]);
      RunKeepsSettled(st2, rs[1..], k + 1, rs[0].inv, rs[0].life.l);
    } else {
      assert rs[1..][m - 1] == rs[m];
      RunSettles(st2, rs[1..], k + 1, m - 1);
    }
  }

  lemma I1SettledStays(rs: seq<Receipt>, k: int)
  {
    H1History(rs);
    RunSettles(State([], [], []), rs, 0, k);
  }

  // A binding whose entry or invocation is already bound is refused.
  lemma BoundRefused(st: State, r: Receipt)
    requires r.kind.Binding? && (r.entry in st.entries || r.inv in st.bound)
    ensures StepOf(st, r).Refused?
  {}

  // Bound entries and invocations only grow.
  lemma StepGrows(st: State, r: Receipt)
    requires StepOf(st, r).Next?
    ensures var st2 := StepOf(st, r).st;
      (forall x | x in st.entries :: x in st2.entries) && (forall x | x in st.bound :: x in st2.bound)
      && (r.kind.Binding? ==> r.entry in st2.entries && r.inv in st2.bound)
  {}

  // In a history that is not refused, a binding's entry and invocation were not bound before it.
  lemma RunUnbound(st: State, rs: seq<Receipt>, k: int, m: int)
    requires Run(st, rs, k).Projected? && 0 <= m < |rs| && rs[m].kind.Binding?
    decreases |rs|
    ensures rs[m].entry !in st.entries && rs[m].inv !in st.bound
  {
    if rs[0].entry in st.entries && m == 0 { BoundRefused(st, rs[0]); }
    if rs[0].inv in st.bound && m == 0 { BoundRefused(st, rs[0]); }
    if m > 0 {
      var st2 := StepOf(st, rs[0]).st;
      StepGrows(st, rs[0]);
      assert rs[1..][m - 1] == rs[m];
      RunUnbound(st2, rs[1..], k + 1, m - 1);
    }
  }

  lemma RunOneBinding(st: State, rs: seq<Receipt>, k: int, j: int, m: int)
    requires Run(st, rs, k).Projected? && 0 <= j < m < |rs| && rs[j].kind.Binding? && rs[m].kind.Binding?
    decreases |rs|
    ensures rs[j].entry != rs[m].entry && rs[j].inv != rs[m].inv
  {
    var st2 := StepOf(st, rs[0]).st;
    assert rs[1..][m - 1] == rs[m];
    if j == 0 {
      StepGrows(st, rs[0]);
      RunUnbound(st2, rs[1..], k + 1, m - 1);
    } else {
      assert rs[1..][j - 1] == rs[j];
      RunOneBinding(st2, rs[1..], k + 1, j - 1, m - 1);
    }
  }

  lemma I2OneBinding(rs: seq<Receipt>, j: int, k: int)
  {
    H1History(rs);
    RunOneBinding(State([], [], []), rs, 0, j, k);
  }
}
