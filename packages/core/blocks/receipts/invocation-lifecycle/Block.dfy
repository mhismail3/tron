// Block receipts/invocation-lifecycle: the compiled fold the shell runs, and the proofs of
// laws/receipts/InvocationLifecycle.dfy.
include "../../../laws/receipts/InvocationLifecycle.dfy"

module ReceiptsInvocationLifecycle refines ReceiptsInvocationLifecycleLaws {
  // ---------- definitions (compiled to JS) ----------

  predicate Legal(from: Life, to: MaybeLife, settle: bool) {
    if TerminalLife(from) || to.NoLife? then false
    else if settle then TerminalLife(to.l)
    else
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

  // A terminal receipt's lifecycle `to` is the one the invocation settled with.
  predicate Repeats(to: MaybeLife, settled: Life) {
    to.LifeOf? && ((to.l.Staged? && settled.Staged?) || (to.l.Accepted? && settled.Accepted?) || (to.l.Queued? && settled.Queued?)
      || (to.l.Running? && settled.Running?) || (to.l.WaitingForInput? && settled.WaitingForInput?) || (to.l.Retrying? && settled.Retrying?)
      || (to.l.Settling? && settled.Settling?) || (to.l.Completed? && settled.Completed?) || (to.l.Failed? && settled.Failed?)
      || (to.l.Interrupted? && settled.Interrupted?) || (to.l.OutcomeUnknown? && settled.OutcomeUnknown?))
  }

  // A later receipt's mark says it carries a name (or origin) that its start, with mark `start`, does not.
  predicate Changed(mark: Mark, start: Mark) { (mark.Same? && !start.Same?) || (mark.Differs? && !start.Differs?) }

  // The cell of an invocation whose start is the fact f at position k.
  function Begin(f: Fact, k: Index): Cell { Cell(k, if f.life.LifeOf? then f.life.l else Accepted, false, false, -1, NoFlag, k) }

  datatype Verdict = Refuse(why: Refusal) | Accept(cell: Cell)

  // A later fact f at position k against its invocation's cell p, whose start is the fact s; entryBound says
  // whether f's entry is already bound.
  function Advance(s: Fact, p: Cell, f: Fact, k: Index, entryBound: bool): Verdict {
    if s.owned != f.owned then Refuse(OwnershipChanged)
    else if f.kind.Binding? && entryBound then Refuse(EntryBound)
    else if f.kind.Binding? && p.bound then Refuse(InvocationBound)
    else if Changed(f.name, s.name) then Refuse(NameChanged)
    else if Changed(f.origin, s.origin) then Refuse(OriginChanged)
    else if f.kind.Terminal? && p.settled && !Repeats(f.life, p.life) then Refuse(ContradictoryTerminal)
    else if f.kind.Terminal? && !p.settled && !Legal(p.life, f.life, true) then Refuse(IllegalTerminal)
    else if f.kind.Transition? && !Legal(p.life, f.life, false) then Refuse(IllegalTransition)
    else
      var settled := p.settled || f.kind.Terminal?;
      Accept(Cell(p.start, if f.life.LifeOf? && (f.kind.Terminal? || !settled) then f.life.l else p.life, settled,
        p.bound || f.kind.Binding?, if f.entry.IndexOf? then k else p.entryAt, if f.retryable.FlagOf? then f.retryable else p.retryable, k))
  }

  // The cells below `count` as a list, in order.
  method Collect(cells: array<Cell>, count: Index) returns (list: List<Cell>)
    requires 0 <= count as int <= cells.Length
    ensures Elems(list) == cells[..count]
  {
    list := Nil;
    var i := count;
    while i > 0
      invariant 0 <= i <= count && Elems(list) == cells[i..count]
    {
      i := i - 1;
      list := Cons(cells[i], list);
      assert cells[i..count] == [cells[i]] + cells[i + 1..count];
    }
  }

  method Fold(facts: seq<Fact>, cells: array<Cell>, slots: array<Index>, entries: array<bool>) returns (out: Folding)
  {
    var n := |facts| as Index;
    ghost var rs := ReceiptsOf(facts);
    // Nothing the arrays held is read: every slot and entry mark is reset, and a cell is read only below `count`.
    var k: Index := 0;
    while k < n
      invariant 0 <= k <= n
      invariant forall t | 0 <= t < k :: slots[t] == -1 && !entries[t]
    {
      slots[k] := -1;
      entries[k] := false;
      k := k + 1;
    }
    var noneBound := false;
    var count: Index := 0;
    ghost var st := State([], [], []);
    k := 0;
    assert rs[0..] == rs;
    while k < n
      invariant 0 <= count <= k <= n && |st.projs| == count as int
      invariant forall i | 0 <= i < count :: Held(cells[i], st, i as int, rs, k as int)
      invariant forall t | 0 <= t < n :: slots[t] as int == FindIndex(st.projs, t as int)
      invariant forall t | 0 <= t < n :: entries[t] == (Some(t as int) in st.entries)
      invariant noneBound == (None in st.entries)
      invariant forall x | x in st.bound :: FindIndex(st.projs, x) >= 0
      invariant Run(st, rs[k..], k as int) == Project(rs)
    {
      var f := facts[k];
      if f.inv < 0 || f.inv >= n || (f.entry.IndexOf? && (f.entry.i < 0 || f.entry.i >= n)) {
        return Unfit(k);
      }
      ghost var r := rs[k];
      assert r == ReceiptOf(f, k as int);
      RunStep(st, rs, k as int);
      var i := slots[f.inv];
      FindIndexSpec(st.projs, r.inv);
      if f.kind.Start? {
        if i >= 0 {
          return Stopped(DuplicateStart, k);
        }
        ghost var p := Proj(r.inv, r.op, r.src, r.name, r.origin, if r.life.LifeOf? then r.life.l else Accepted, None, NoFlag, r.sequence, r.at, false);
        FindIndexAppend(st.projs, p);
        BeginSpec(facts, k as int);
        cells[count] := Begin(f, k);
        slots[f.inv] := count;
        st := st.(projs := st.projs + [p]);
        count := count + 1;
      } else {
        if i < 0 {
          return Stopped(NoStart, k);
        }
        var p := cells[i];
        var entryBound := if f.entry.IndexOf? then entries[f.entry.i] else noneBound;
        AdvanceSpec(st, facts, k as int, i as int, p, entryBound);
        var verdict := Advance(facts[p.start], p, f, k, entryBound);
        if verdict.Refuse? {
          return Stopped(verdict.why, k);
        }
        FindIndexUpdate(st.projs, i as int, ProjOf(verdict.cell, rs));
        cells[i] := verdict.cell;
        if f.kind.Binding? {
          if f.entry.IndexOf? { entries[f.entry.i] := true; } else { noneBound := true; }
        }
        st := StepOf(st, r).st;
      }
      k := k + 1;
    }
    assert rs[k..] == [];
    var list := Collect(cells, count);
    return Finished(list);
  }

  // ---------- proofs: Fold computes Project ----------

  // The fold from position k is the fold of the receipt at k, then the fold from k + 1.
  lemma RunStep(st: State, rs: seq<Receipt>, k: int)
    requires 0 <= k < |rs|
    ensures Run(st, rs[k..], k) == match StepOf(st, rs[k])
      case Refused(why) => Rejected(why, k)
      case Next(st2) => Run(st2, rs[k + 1..], k + 1)
  { assert rs[k..][0] == rs[k] && rs[k..][1..] == rs[k + 1..]; }

  // Held: cell c is the fold's cell for the state's i-th invocation, with positions before k: it stands for that
  // invocation's state, says whether the invocation is bound, and no other state is of the same invocation.
  ghost predicate Held(c: Cell, st: State, i: int, rs: seq<Receipt>, k: int)
    requires 0 <= i < |st.projs|
  {
    Placed(c, rs) && c.start as int < k && c.entryAt as int < k && c.updated as int < k
    && ProjOf(c, rs) == st.projs[i]
    && c.bound == (st.projs[i].inv in st.bound)
    && FindIndex(st.projs, st.projs[i].inv) == i
  }

  // A start's cell stands for the state StepOf appends.
  lemma BeginSpec(fs: seq<Fact>, k: int)
    requires 0 <= k < |fs| < 0x1_0000_0000
    ensures var rs := ReceiptsOf(fs); var r := rs[k]; var c := Begin(fs[k], k as Index);
      Placed(c, rs) && c.start as int == k && c.entryAt == -1 && c.updated as int == k && !c.bound
      && ProjOf(c, rs) == Proj(r.inv, r.op, r.src, r.name, r.origin, if r.life.LifeOf? then r.life.l else Accepted, None, NoFlag, r.sequence, r.at, false)
  {}

  lemma SameSpec(to: MaybeLife, settled: Life, mark: Mark, start: Mark)
    ensures Repeats(to, settled) <==> to == LifeOf(settled)
    ensures Changed(mark, start) <==> MarkOf(mark).Some? && MarkOf(mark) != MarkOf(start)
  {}

  // Advance decides a later receipt as StepOf does, and its cell stands for the updated state.
  lemma AdvanceSpec(st: State, fs: seq<Fact>, k: int, i: int, p: Cell, entryBound: bool)
    requires 0 <= k < |fs| < 0x1_0000_0000 && !fs[k].kind.Start?
    requires 0 <= i < |st.projs| && FindIndex(st.projs, fs[k].inv as int) == i
    requires Held(p, st, i, ReceiptsOf(fs), k)
    requires entryBound == (ReceiptsOf(fs)[k].entry in st.entries)
    ensures var rs := ReceiptsOf(fs);
      var verdict := Advance(fs[p.start], p, fs[k], k as Index, entryBound);
      (verdict.Refuse? ==> StepOf(st, rs[k]) == Refused(verdict.why))
      && (verdict.Accept? ==> (StepOf(st, rs[k]).Next?
        && Placed(verdict.cell, rs) && verdict.cell.start as int < k + 1 && verdict.cell.entryAt as int < k + 1 && verdict.cell.updated as int < k + 1
        && StepOf(st, rs[k]).st == State(st.projs[i := ProjOf(verdict.cell, rs)],
          if fs[k].kind.Binding? then st.entries + [rs[k].entry] else st.entries,
          if fs[k].kind.Binding? then st.bound + [rs[k].inv] else st.bound)
        && ProjOf(verdict.cell, rs).inv == st.projs[i].inv
        && verdict.cell.bound == (p.bound || fs[k].kind.Binding?)))
  {
    var rs := ReceiptsOf(fs);
    var f, s, r := fs[k], fs[p.start], rs[k];
    FindIndexSpec(st.projs, r.inv);
    SameSpec(f.life, p.life, f.name, s.name);
    SameSpec(f.life, p.life, f.origin, s.origin);
    assert st.projs[i] == ProjOf(p, rs);
    assert rs[p.start] == ReceiptOf(s, p.start as int);
  }

  // ---------- proofs: what the fold does ----------

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
    assert rs[1..] == [r1, r2, r3, r4] && rs[1..][1..] == [r2, r3, r4] && rs[1..][1..][1..] == [r3, r4] && rs[1..][1..][1..][1..] == [r4];
    assert Run(st4, [], 5) == Projected(st4.projs);
    assert Run(st3, [r4], 4) == Run(st4, [], 5) by { assert [r4][1..] == []; }
    assert Run(st2, [r3, r4], 3) == Run(st3, [r4], 4) by { assert [r3, r4][1..] == [r4]; }
    assert Run(st1, [r2, r3, r4], 2) == Run(st2, [r3, r4], 3) by { assert [r2, r3, r4][1..] == [r3, r4]; }
    assert Run(State([p0], [], []), [r1, r2, r3, r4], 1) == Run(st1, [r2, r3, r4], 2) by { assert [r1, r2, r3, r4][1..] == [r2, r3, r4]; }
    assert Run(st0, rs, 0) == Run(State([p0], [], []), [r1, r2, r3, r4], 1);
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
    RunOneBinding(State([], [], []), rs, 0, j, k);
  }
}
