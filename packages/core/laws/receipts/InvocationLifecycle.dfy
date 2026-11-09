// Laws of block receipts/invocation-lifecycle: how a session's invocation receipts (start, transition, terminal
// and binding facts the Gateway writes for each prompt, skill, command or wake it runs) fold into each
// invocation's lifecycle, and which receipt histories are refused as contradictory. Identities (invocation,
// operation, source, resource name, origin, canonical entry) and timestamps enter as tokens: the shell numbers
// the distinct values of one call.
// Shell: packages/gateway/src/kernel/receipts/invocation-receipts.ts (invocationProjection's fold; ordering the
// result by sequence and the receipt grammar stay in the shell).
// Statements only; the block refines this module. Edit a law only with a new independent review.
abstract module ReceiptsInvocationLifecycleLaws {
  datatype Kind = Start | Transition | Terminal | Binding
  datatype Life = Staged | Accepted | Queued | Running | WaitingForInput | Retrying | Settling
    | Completed | Failed | Interrupted | OutcomeUnknown
  datatype MaybeLife = NoLife | LifeOf(l: Life)
  datatype Opt = None | Some(v: int)
  datatype Flag = NoFlag | FlagOf(b: bool)
  // One receipt: its invocation, operation and source, kind, lifecycle (if it carries one), resource name,
  // origin and canonical entry (if it carries them), retryable flag, sequence and creation time.
  datatype Receipt = Receipt(inv: int, op: int, src: int, kind: Kind, life: MaybeLife, name: Opt, origin: Opt,
    entry: Opt, retryable: Flag, sequence: int, at: int)
  // One invocation's folded state: identity from its start, the current lifecycle, its canonical entry and
  // retryable flag, its start's sequence, the creation time of its latest receipt, and whether it has settled.
  datatype Proj = Proj(inv: int, op: int, src: int, name: Opt, origin: Opt, life: Life, entry: Opt, retryable: Flag,
    sequence: int, updated: int, terminal: bool)
  // The fold's state: the invocations in order of their start, and the entries and invocations already bound.
  datatype State = State(projs: seq<Proj>, entries: seq<Opt>, bound: seq<int>)
  datatype Refusal = DuplicateStart | OwnershipChanged | NoStart | EntryBound | InvocationBound | NameChanged
    | OriginChanged | ContradictoryTerminal | IllegalTerminal | IllegalTransition
  datatype Step = Refused(why: Refusal) | Next(st: State)
  datatype Checked = Passes | Fails(why: Refusal)
  datatype Outcome = Rejected(why: Refusal, at: int) | Projected(projs: seq<Proj>)

  // Assumption A1: the shell gives equal identities of one call equal tokens (an origin by its canonical JSON),
  // and the receipts are those invocationReceipts parsed from the session branch, in branch order: a start
  // carries the staged lifecycle and an origin, a transition a non-terminal lifecycle, a terminal a terminal
  // one, a binding a canonical entry; names and entries are never empty. The block folds any receipt shape the
  // same way the TypeScript does, so its laws do not depend on A1; A1 is what the tokens mean.
  // Assumption A2: the shell orders the result by each invocation's start sequence (a stable sort, ties in
  // start order), as invocationProjection does; the block returns invocations in start order.

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

  // One receipt folded into the state.
  function StepOf(st: State, r: Receipt): Step

  // The receipts of one session folded: the invocations' states in start order, or the first refusal.
  function Project(rs: seq<Receipt>): Outcome

  // L1 legal-moves: a settled lifecycle never moves; a terminal receipt may settle any unsettled lifecycle into a
  // settled one; a transition receipt may make exactly the allowed moves; a receipt without a lifecycle moves
  // nothing.
  lemma L1LegalMoves(from: Life, to: Life, settle: bool)
    ensures !Legal(from, NoLife, settle)
    ensures Legal(from, LifeOf(to), settle) == (!TerminalLife(from) && (if settle then TerminalLife(to) else Allowed(from, to)))

  // H1 history: a session's receipts are folded one after another from no invocations, and the first refused
  // receipt refuses the whole history.
  lemma H1History(rs: seq<Receipt>)
    ensures Project(rs) == Run(State([], [], []), rs, 0)

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
