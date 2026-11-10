// Laws of block receipts/invocation-lifecycle: how a session's invocation receipts (start, transition, terminal
// and binding facts the Gateway writes for each prompt, skill, command or wake it runs) fold into each
// invocation's lifecycle, and which receipt histories are refused as contradictory.
// The fold is defined here over receipts with tokens for identities (Receipt, StepOf, Run, Project), and laws L1 to
// I2 say what it does. The shell runs Fold, which reads the same history as facts (Fact) and works in arrays the
// shell lends it; law F1 says Fold's answer is exactly Project's.
// Shell: packages/gateway/src/kernel/receipts/invocation-receipts.ts (invocationProjection's fold; ordering the
// result by sequence and the receipt grammar stay in the shell).
// The block refines this module. Edit a definition or a law only with a new independent review.
abstract module ReceiptsInvocationLifecycleLaws {
  datatype Kind = Start | Transition | Terminal | Binding
  datatype Life = Staged | Accepted | Queued | Running | WaitingForInput | Retrying | Settling
    | Completed | Failed | Interrupted | OutcomeUnknown
  datatype MaybeLife = NoLife | LifeOf(l: Life)
  // The fold as it is defined works on the types below, which exist for the laws only (their constructors are
  // ghost: nothing compiled builds one).
  datatype Opt = ghost None | ghost Some(v: int)
  datatype Flag = NoFlag | FlagOf(b: bool)
  // One receipt: its invocation, operation and source, kind, lifecycle (if it carries one), resource name,
  // origin and canonical entry (if it carries them), retryable flag, sequence and creation time.
  datatype Receipt = ghost Receipt(inv: int, op: int, src: int, kind: Kind, life: MaybeLife, name: Opt, origin: Opt,
    entry: Opt, retryable: Flag, sequence: int, at: int)
  // One invocation's folded state: identity from its start, the current lifecycle, its canonical entry and
  // retryable flag, its start's sequence, the creation time of its latest receipt, and whether it has settled.
  datatype Proj = ghost Proj(inv: int, op: int, src: int, name: Opt, origin: Opt, life: Life, entry: Opt, retryable: Flag,
    sequence: int, updated: int, terminal: bool)
  // The fold's state: the invocations in order of their start, and the entries and invocations already bound.
  datatype State = ghost State(projs: seq<Proj>, entries: seq<Opt>, bound: seq<int>)
  datatype Refusal = DuplicateStart | OwnershipChanged | NoStart | EntryBound | InvocationBound | NameChanged
    | OriginChanged | ContradictoryTerminal | IllegalTerminal | IllegalTransition
  datatype Step = ghost Refused(why: Refusal) | ghost Next(st: State)
  datatype Checked = ghost Passes | ghost Fails(why: Refusal)
  datatype Outcome = ghost Rejected(why: Refusal, at: int) | ghost Projected(projs: seq<Proj>)

  // Index: a position in the session's receipts (or -1 for none), and the number the shell gives an invocation
  // or a canonical entry. A JavaScript number in the compiled block.
  newtype Index = x: int | -1 <= x < 0x1_0000_0000
  // Mark: a receipt's resource name or origin as the shell states it: it carries none, the one its invocation's
  // start carries, or another.
  datatype Mark = Absent | Same | Differs
  datatype MaybeIndex = NoIndex | IndexOf(i: Index)
  // Fact: one receipt as the shell states it to the compiled fold: its invocation's number; its kind and
  // lifecycle; whether its operation and source are those of its invocation's start; its name and origin marks;
  // its canonical entry's number, if it carries one; its retryable flag.
  datatype Fact = Fact(inv: Index, kind: Kind, life: MaybeLife, owned: bool, name: Mark, origin: Mark, entry: MaybeIndex,
    retryable: Flag)
  // Cell: one invocation's folded state as the compiled fold keeps it: the position of its start receipt, its
  // lifecycle, whether it has settled and whether it is bound, the position of the receipt its canonical entry
  // comes from (-1 for none), its retryable flag, and the position of its latest receipt.
  datatype Cell = Cell(start: Index, life: Life, settled: bool, bound: bool, entryAt: Index, retryable: Flag, updated: Index)
  // List: a linked list, the form in which the compiled block builds its result.
  datatype List<T> = Nil | Cons(head: T, tail: List<T>)
  // Folding: the compiled fold's answer: the first refusal and its position, each invocation's cell in start
  // order, or the position of a fact whose numbers the fold cannot use.
  datatype Folding = Stopped(why: Refusal, at: Index) | Finished(cells: List<Cell>) | Unfit(at: Index)

  // Assumption A1: the facts are the receipts invocationReceipts parsed from the session branch, in branch order.
  // The shell numbers invocations and canonical entries from 0 in order of first appearance, so every number is
  // below the number of receipts. A start receipt is stated as owned, with name and origin marks Same when it
  // carries them (else Absent). A later receipt is owned exactly when its operation and source equal those of the
  // first start receipt of its invocation before it; its name mark is Absent when it carries no name, Same when
  // its name is that start's and Differs otherwise, and its origin mark likewise (origins compared by canonical
  // JSON, the start's being the default origin of its source when it carries none). A receipt with no start
  // before it is refused whatever its marks say. The fold reads any facts the way Project reads the receipts
  // they stand for (law F1), so its laws do not depend on A1; A1 is what the facts mean.
  // Assumption A2: the shell reads each invocation's identity, name, origin and sequence from the receipt at its
  // cell's start position, its canonical entry from the receipt at entryAt and its time from the receipt at
  // updated, and orders the result by start sequence (a stable sort, ties in start order), as
  // invocationProjection does; the block returns invocations in start order.

  // TerminalLife: completed, failed, interrupted and outcome-unknown are settled; nothing follows them.
  predicate TerminalLife(l: Life) { l.Completed? || l.Failed? || l.Interrupted? || l.OutcomeUnknown? }

  // Allowed: the lifecycle moves a transition receipt may make (a terminal receipt may settle any unsettled one).
  ghost predicate Allowed(from: Life, to: Life) {
    match from
    case Staged => to in {Accepted, Queued, Running, WaitingForInput, Retrying, Settling}
    case Accepted => to in {Queued, Running, WaitingForInput, Retrying, Settling}
    case Queued => to in {Running, Settling}
    case Running => to in {WaitingForInput, Retrying, Settling}
    case WaitingForInput => to in {Running, Settling}
    case Retrying => to in {Running, Settling}
    case _ => false
  }

  // Seen: the state already holds invocation inv (its start was folded).
  ghost predicate Seen(st: State, inv: int) { exists i | 0 <= i < |st.projs| :: st.projs[i].inv == inv }

  // Run: the receipts folded one after another from the state, positions counted from k; the first refused
  // receipt refuses the whole history, naming its position.
  ghost function Run(st: State, rs: seq<Receipt>, k: int): Outcome
    decreases |rs|
  {
    if |rs| == 0 then Projected(st.projs)
    else match StepOf(st, rs[0])
      case Refused(why) => Rejected(why, k)
      case Next(st2) => Run(st2, rs[1..], k + 1)
  }

  // Whether a transition (or, with settle, a terminal) receipt may move the lifecycle from `from` to `to`.
  predicate Legal(from: Life, to: MaybeLife, settle: bool)

  // The index of the first state of invocation inv, or -1.
  ghost function FindIndex(projs: seq<Proj>, inv: int): int
    decreases |projs|
    ensures -1 <= FindIndex(projs, inv) < |projs|
  {
    if |projs| == 0 then -1
    else if projs[0].inv == inv then 0
    else var k := FindIndex(projs[1..], inv); if k < 0 then -1 else k + 1
  }

  // StepOf: one receipt folded into the state. A start appends its invocation's state, or is refused when the
  // invocation has one. A later receipt is refused when its invocation has no start, and otherwise for the first
  // check it fails: ownership, an entry already bound, an invocation already bound, another name, another origin,
  // a contradictory terminal, an illegal terminal, an illegal transition; when it passes them all it updates its
  // invocation's state, and a binding records its entry and invocation as bound.
  ghost function StepOf(st: State, r: Receipt): Step {
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

  // Project: the receipts of one session folded one after another from no invocations: the invocations' states in
  // start order, or the first refusal.
  ghost function Project(rs: seq<Receipt>): Outcome { Run(State([], [], []), rs, 0) }

  // MarkOf: a mark as a name or origin token: none, the start's (0) or another (1).
  ghost function MarkOf(m: Mark): Opt {
    match m
    case Absent => None
    case Same => Some(0)
    case Differs => Some(1)
  }

  // ReceiptOf: the receipt the fact at position k stands for: its invocation and entry numbers as tokens; an
  // operation that is its start's (0) or not (1); its position as its sequence and its time.
  ghost function ReceiptOf(f: Fact, k: nat): Receipt {
    Receipt(f.inv as int, if f.owned then 0 else 1, 0, f.kind, f.life, MarkOf(f.name), MarkOf(f.origin),
      if f.entry.IndexOf? then Some(f.entry.i as int) else None, f.retryable, k, k)
  }

  // ReceiptsOf: the history the facts stand for.
  ghost function ReceiptsOf(fs: seq<Fact>): seq<Receipt> {
    seq(|fs|, k requires 0 <= k < |fs| => ReceiptOf(fs[k], k))
  }

  // Elems: the items of a linked list, in order.
  ghost function Elems<T>(l: List<T>): seq<T> {
    match l
    case Nil => []
    case Cons(head, tail) => [head] + Elems(tail)
  }

  // Placed: the cell's positions are positions of the history (entryAt and none: -1).
  ghost predicate Placed(c: Cell, rs: seq<Receipt>) {
    0 <= c.start as int < |rs| && -1 <= c.entryAt as int < |rs| && 0 <= c.updated as int < |rs|
  }

  // ProjOf: the invocation state a cell stands for: identity, name, origin and sequence of the receipt at its
  // start; the entry of the receipt at entryAt; its position `updated` as its time.
  ghost function ProjOf(c: Cell, rs: seq<Receipt>): Proj
    requires Placed(c, rs)
  {
    var s := rs[c.start];
    Proj(s.inv, s.op, s.src, s.name, s.origin, c.life, if c.entryAt >= 0 then rs[c.entryAt].entry else None, c.retryable,
      s.sequence, c.updated as int, c.settled)
  }

  // Fits: every invocation and entry number is at least 0 and below the number of facts.
  ghost predicate Fits(fs: seq<Fact>) {
    forall k | 0 <= k < |fs| :: 0 <= fs[k].inv as int < |fs| && (fs[k].entry.IndexOf? ==> 0 <= fs[k].entry.i as int < |fs|)
  }

  // Agrees: the answer is Project's for the history the facts stand for: the same refusal at the same position,
  // or one cell for each invocation state, in the same order, standing for it.
  ghost predicate Agrees(out: Folding, fs: seq<Fact>) {
    var rs := ReceiptsOf(fs);
    match Project(rs)
    case Rejected(why, at) => out.Stopped? && out.why == why && out.at as int == at
    case Projected(projs) => out.Finished? && |Elems(out.cells)| == |projs|
      && forall i | 0 <= i < |projs| :: Placed(Elems(out.cells)[i], rs) && ProjOf(Elems(out.cells)[i], rs) == projs[i]
  }

  // F1 fold-computed: for any facts, Fold answers exactly what Project answers for the history they stand for: the
  // same refusal at the same position, or the same invocation states in the same order. It answers Unfit, naming a
  // position, only when an invocation or entry number is not below the number of facts. It needs three arrays as
  // long as the facts to work in, and what they held before does not matter.
  method Fold(facts: seq<Fact>, cells: array<Cell>, slots: array<Index>, entries: array<bool>) returns (out: Folding)
    requires |facts| < 0x1_0000_0000 && cells.Length == |facts| && slots.Length == |facts| && entries.Length == |facts|
    modifies cells, slots, entries
    ensures out.Unfit? ==> !Fits(facts)
    ensures !out.Unfit? ==> Agrees(out, facts)

  // L1 legal-moves: a settled lifecycle never moves; a terminal receipt may settle any unsettled lifecycle into a
  // settled one; a transition receipt may make exactly the allowed moves; a receipt without a lifecycle moves
  // nothing.
  lemma L1LegalMoves(from: Life, to: Life, settle: bool)
    ensures !Legal(from, NoLife, settle)
    ensures Legal(from, LifeOf(to), settle) == (!TerminalLife(from) && (if settle then TerminalLife(to) else Allowed(from, to)))

  // S1 start: a start receipt for a new invocation appends its state (lifecycle from the receipt, accepted if it
  // carries none; name, origin, sequence and time from the receipt; no entry, flag or settlement) and changes
  // nothing else; a second start for the same invocation is refused.
  lemma S1Start(st: State, r: Receipt)
    requires r.kind.Start?
    ensures StepOf(st, r) == if Seen(st, r.inv) then Refused(DuplicateStart)
      else Next(st.(projs := st.projs + [Proj(r.inv, r.op, r.src, r.name, r.origin,
        if r.life.LifeOf? then r.life.l else Accepted, None, NoFlag, r.sequence, r.at, false)]))

  // Check: the checks a later receipt for a started invocation p must pass, in this order: the same operation
  // and source as the start; for a binding, an entry not yet bound and an invocation not yet bound; no resource
  // name other than the start's; no origin other than the start's.
  ghost function Check(st: State, r: Receipt, p: Proj): Checked {
    if p.op != r.op || p.src != r.src then Fails(OwnershipChanged)
    else if r.kind.Binding? && r.entry in st.entries then Fails(EntryBound)
    else if r.kind.Binding? && r.inv in st.bound then Fails(InvocationBound)
    else if r.name.Some? && r.name != p.name then Fails(NameChanged)
    else if r.origin.Some? && r.origin != p.origin then Fails(OriginChanged)
    else Passes
  }

  // S2 checks: a later receipt (transition, terminal or binding) for a started invocation that fails a check is
  // refused for the first check it fails; a binding that passes them is accepted.
  lemma S2Checks(st: State, r: Receipt, i: int)
    requires !r.kind.Start?
    requires 0 <= i < |st.projs| && st.projs[i].inv == r.inv && forall j | 0 <= j < i :: st.projs[j].inv != r.inv
    ensures Check(st, r, st.projs[i]).Fails? ==> StepOf(st, r) == Refused(Check(st, r, st.projs[i]).why)
    ensures Check(st, r, st.projs[i]).Passes? && r.kind.Binding? ==> StepOf(st, r).Next?

  // S3 no-start: a later receipt for an invocation with no start is refused.
  lemma S3NoStart(st: State, r: Receipt)
    requires !r.kind.Start? && !Seen(st, r.inv)
    ensures StepOf(st, r) == Refused(NoStart)

  // S4 settle: a terminal receipt that passes the checks settles an unsettled invocation when the move is legal
  // (else it is refused); on a settled invocation it is accepted only with the same lifecycle (a duplicate) and
  // refused with another. A transition receipt is refused unless its move is legal, so nothing moves a settled
  // invocation.
  lemma S4Settle(st: State, r: Receipt, i: int)
    requires !r.kind.Start? && !r.kind.Binding?
    requires 0 <= i < |st.projs| && st.projs[i].inv == r.inv && forall j | 0 <= j < i :: st.projs[j].inv != r.inv
    requires Check(st, r, st.projs[i]).Passes?
    ensures var p := st.projs[i];
      StepOf(st, r).Refused? == (if r.kind.Terminal? && p.terminal then r.life != LifeOf(p.life)
        else !Legal(p.life, r.life, r.kind.Terminal?))
    ensures var p := st.projs[i];
      StepOf(st, r).Refused? ==> StepOf(st, r).why == (if r.kind.Transition? then IllegalTransition
        else if p.terminal then ContradictoryTerminal else IllegalTerminal)

  // S5 update: a later receipt that is accepted updates only its own invocation: the lifecycle it carries (kept
  // when the invocation is settled and the receipt is not terminal; an accepted terminal receipt always carries
  // one), its entry and retryable flag when it carries
  // them, the latest time, and settlement for a terminal receipt; a binding also records its entry and invocation
  // as bound.
  lemma S5Update(st: State, r: Receipt, i: int)
    requires !r.kind.Start?
    requires 0 <= i < |st.projs| && st.projs[i].inv == r.inv && forall j | 0 <= j < i :: st.projs[j].inv != r.inv
    requires StepOf(st, r).Next?
    ensures var p := st.projs[i];
      var settled := p.terminal || r.kind.Terminal?;
      StepOf(st, r).st == State(st.projs[i := p.(
          life := if r.life.LifeOf? && (r.kind.Terminal? || !settled) then r.life.l else p.life,
          entry := if r.entry.Some? then r.entry else p.entry,
          retryable := if r.retryable.FlagOf? then r.retryable else p.retryable,
          updated := r.at, terminal := settled)],
        if r.kind.Binding? then st.entries + [r.entry] else st.entries,
        if r.kind.Binding? then st.bound + [r.inv] else st.bound)

  // P1 progress: a start, its acceptance, running, completion and its canonical binding are all accepted, and the
  // invocation ends completed, settled and bound to its entry.
  lemma P1Progress(inv: int, op: int, src: int, origin: int, e: int, s: int)
    ensures var rs := [Receipt(inv, op, src, Start, LifeOf(Staged), None, Some(origin), None, NoFlag, s, 1),
        Receipt(inv, op, src, Transition, LifeOf(Accepted), None, None, None, NoFlag, s, 2),
        Receipt(inv, op, src, Transition, LifeOf(Running), None, None, None, NoFlag, s, 3),
        Receipt(inv, op, src, Terminal, LifeOf(Completed), None, None, None, FlagOf(false), s, 4),
        Receipt(inv, op, src, Binding, NoLife, None, None, Some(e), NoFlag, s, 5)];
      Project(rs) == Projected([Proj(inv, op, src, None, Some(origin), Completed, Some(e), FlagOf(false), s, 5, true)])

  // I1 settled-stays-settled: in any history that is not refused, an invocation that received a terminal receipt
  // ends settled, with that receipt's lifecycle.
  lemma I1SettledStays(rs: seq<Receipt>, k: int)
    requires Project(rs).Projected? && 0 <= k < |rs| && rs[k].kind.Terminal?
    ensures exists i | 0 <= i < |Project(rs).projs| ::
      (Project(rs).projs[i].inv == rs[k].inv && Project(rs).projs[i].terminal && LifeOf(Project(rs).projs[i].life) == rs[k].life)

  // I2 one-binding: in any history that is not refused, no two binding receipts bind the same entry or the same
  // invocation.
  lemma I2OneBinding(rs: seq<Receipt>, j: int, k: int)
    requires Project(rs).Projected? && 0 <= j < k < |rs| && rs[j].kind.Binding? && rs[k].kind.Binding?
    ensures rs[j].entry != rs[k].entry && rs[j].inv != rs[k].inv
}
