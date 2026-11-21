// Laws of block sessions/restart-drain: on each poll of a restart drain, whether the drain is complete, proceeds over
// unresolved owners, keeps waiting, or has stalled on its oldest blocker, and what the stall timer tracks next.
// Strings enter as tokens (the shell numbers each distinct string of one call: blocker ids and session ids) and
// times as integer milliseconds. What the timer tracks is an explicit input and output, so one call decides from
// one snapshot.
// Shell: packages/gateway/src/sessions/restart-drain.ts (RestartDrainProgress.evaluate: it keeps the tracked
// blocker between polls, checks and parses the snapshot's timestamps, asks the block, and maps its decision back to
// the snapshot's blockers).
// The block refines this module. Edit a definition or a law only with a new independent review.
abstract module SessionsRestartDrainLaws {
  // Token: the number the shell gives one string of one call. A JavaScript number in the compiled block, which
  // only compares tokens.
  newtype Token = x: int | 0 <= x < 0x1_0000_0000
  // Count: how many operations block the drain.
  newtype Count = x: int | 0 <= x < 0x1_0000_0000
  // Ms: a time in milliseconds since 1970, or a duration, within the range of a JavaScript Date.
  newtype Ms = x: int | 0 <= x <= 8_640_000_000_000_000
  // List: a linked list, crossing to the shell as an array.
  datatype List<T> = Nil | Cons(head: T, tail: List<T>)
  // State: a blocker's state, named as the snapshot names it.
  datatype State = active | settling | suspect
  // Time: a time a blocker carries, or none.
  datatype Time = Unset | At(ms: Ms)
  // Session: the session a blocker belongs to, or none.
  datatype Session = NoSession | InSession(session: Token)
  // Blocker: one listed blocker of the snapshot: its id; whether it is a terminal-receipt persistence write; its
  // session, state, admission time and progress time.
  datatype Blocker = Blocker(id: Token, receipt: bool, session: Session, state: State, admitted: Time, progress: Time)
  // Tracked: the blocker the stall timer follows (its id, state, progress and admission times as last seen) and the
  // time the timer runs from, or nothing.
  datatype Tracked = Untracked | Tracking(id: Token, state: State, progress: Time, admitted: Time, since: Ms)
  // Outcome: the drain is complete; it waits; it proceeds over unresolved owners; or it stalled on a blocker (by
  // id) after an age.
  datatype Outcome = Completed | Waiting | UnresolvedOwners | Stalled(blocker: Token, age: Ms)
  // Step: the outcome of one poll and what the timer tracks next.
  datatype Step = Step(outcome: Outcome, tracked: Tracked)

  // Assumption A1: the shell gives equal strings equal tokens and distinct strings distinct tokens within one call;
  // the tracked blocker's id is tokenised in the same call as the snapshot, so it equals a listed blocker's token
  // exactly when the ids are equal. Blocker ids are unique within a snapshot (each is a hash of the drain id and
  // the blocker's distinct key), so the shell finds a stalled blocker by its id.
  // Assumption A2: count is the snapshot's blockerCount and the blockers are its listed blockers in order (at most
  // 64; the rest are omitted). A session id is absent or non-empty, and every admission and progress time is absent
  // or a Date#toISOString instant at or after 1970 (the runtime registry's sources write only those); the shell
  // refuses any other and passes each time as its milliseconds. For the years 1970 to 9999 such strings order as
  // their milliseconds, so there the block orders times as the replaced TypeScript's string comparison did; a later
  // year (a producer artifact's start time) is ordered by its time, where the string comparison put it first. now
  // is the Gateway clock read once per poll and limit the stall limit.
  // Assumption A3: the shell keeps the returned tracked value for the next poll of the same drain and starts each
  // drain with nothing tracked; on Completed or UnresolvedOwners it restarts, on Stalled it restarts naming the
  // blocker, and on Waiting it polls again.

  // Elems: the items of a linked list, in order.
  ghost function Elems<T>(l: List<T>): seq<T> { if l.Nil? then [] else [l.head] + Elems(l.tail) }

  // Owner: a suspect terminal-receipt persistence write of a session.
  ghost predicate Owner(b: Blocker) { b.receipt && b.state == suspect && b.session.InSession? }

  // OnlyOwners: every blocker is listed, at least one is, and each is an owner.
  ghost predicate OnlyOwners(count: Count, bs: seq<Blocker>) {
    count as int == |bs| > 0 && forall i | 0 <= i < |bs| :: Owner(bs[i])
  }

  // Before: time a is strictly earlier than time b; a time that is set is earlier than an unset one.
  ghost predicate Before(a: Time, b: Time) { a.At? && (b.Unset? || a.ms < b.ms) }

  // Oldest: blocker i was admitted strictly earlier than every blocker listed before it, and no blocker listed
  // after it was admitted strictly earlier: the first admitted at the earliest admission time, or the first blocker
  // when none has one.
  ghost predicate Oldest(bs: seq<Blocker>, i: int) {
    0 <= i < |bs|
    && (forall j | 0 <= j < i :: Before(bs[i].admitted, bs[j].admitted))
    && (forall j | i < j < |bs| :: !Before(bs[j].admitted, bs[i].admitted))
  }

  // Later: the later of two times; a time that is set is later than an unset one.
  ghost function Later(a: Time, b: Time): Time { if a.Unset? then b else if b.Unset? || a.ms >= b.ms then a else b }

  // Own: a blocker's progress time when it belongs to session s, else Unset.
  ghost function Own(b: Blocker, s: Token): Time { if b.session == InSession(s) then b.progress else Unset }

  // LatestOf: the latest progress time of the blockers of session s; Unset when none has one.
  ghost function LatestOf(bs: seq<Blocker>, s: Token): Time
    decreases |bs|
  { if |bs| == 0 then Unset else Later(Own(bs[0], s), LatestOf(bs[1..], s)) }

  // Progress: the progress time that judges blocker o: the latest progress time of its session's blockers, or its
  // own when it has no session.
  ghost function Progress(bs: seq<Blocker>, o: Blocker): Time {
    if o.session.NoSession? then o.progress else LatestOf(bs, o.session.session)
  }

  // Signal: the time a blocker was last seen to move: its progress time, else its admission time, else now.
  ghost function Signal(p: Time, a: Time, now: Ms): Ms { if p.At? then p.ms else if a.At? then a.ms else now }

  // Unchanged: the timer already tracks blocker o, with the same state, progress time p and admission time.
  ghost predicate Unchanged(t: Tracked, o: Blocker, p: Time) {
    t.Tracking? && t.id == o.id && t.state == o.state && t.progress == p && t.admitted == o.admitted
  }

  // Age: the time from since to now, never below zero.
  ghost function Age(now: Ms, since: Ms): Ms { if now <= since then 0 else now - since }

  // One poll of the drain: count blockers, the listed blockers, what the timer tracks, the time now and the limit.
  function Evaluate(count: Count, blockers: List<Blocker>, tracked: Tracked, now: Ms, limit: Ms): Step

  // C1 completed: the drain is complete exactly when no operation blocks it, and then the timer tracks nothing.
  lemma C1Completed(count: Count, blockers: List<Blocker>, tracked: Tracked, now: Ms, limit: Ms)
    ensures Evaluate(count, blockers, tracked, now, limit).outcome.Completed? <==> count == 0
    ensures count == 0 ==> Evaluate(count, blockers, tracked, now, limit).tracked.Untracked?

  // U1 unresolved-owners: while operations block the drain, the restart proceeds over unresolved owners exactly
  // when every blocker is listed, at least one is, and each is a suspect terminal-receipt persistence write of a
  // session; then the timer tracks nothing.
  lemma U1UnresolvedOwners(count: Count, blockers: List<Blocker>, tracked: Tracked, now: Ms, limit: Ms)
    requires count != 0
    ensures Evaluate(count, blockers, tracked, now, limit).outcome.UnresolvedOwners?
      <==> OnlyOwners(count, Elems(blockers))
    ensures OnlyOwners(count, Elems(blockers)) ==> Evaluate(count, blockers, tracked, now, limit).tracked.Untracked?

  // W1 unlisted: when operations block the drain but none is listed, the drain waits and the timer is unchanged.
  lemma W1Unlisted(count: Count, blockers: List<Blocker>, tracked: Tracked, now: Ms, limit: Ms)
    requires count != 0 && blockers.Nil?
    ensures Evaluate(count, blockers, tracked, now, limit) == Step(Waiting, tracked)

  // O1 oldest-tracked: otherwise the timer tracks the oldest blocker (the first admitted at the earliest admission
  // time, or the first blocker when none has one) with its id, state and admission time, and the latest progress
  // time of its session's blockers (its own when it has no session).
  lemma O1OldestTracked(count: Count, blockers: List<Blocker>, tracked: Tracked, now: Ms, limit: Ms, i: int)
    requires count != 0 && !OnlyOwners(count, Elems(blockers)) && Oldest(Elems(blockers), i)
    ensures var o, t := Elems(blockers)[i], Evaluate(count, blockers, tracked, now, limit).tracked;
      t.Tracking? && t.id == o.id && t.state == o.state && t.admitted == o.admitted
      && t.progress == Progress(Elems(blockers), o)

  // R1 timer-reset: the stall timer restarts from the oldest blocker's last signal (its progress time, else its
  // admission time, else now) exactly when the tracked blocker, its state, its progress time or its admission time
  // changed since the last poll; otherwise it keeps running from the tracked time.
  lemma R1TimerReset(count: Count, blockers: List<Blocker>, tracked: Tracked, now: Ms, limit: Ms, i: int)
    requires count != 0 && !OnlyOwners(count, Elems(blockers)) && Oldest(Elems(blockers), i)
    ensures var o, t := Elems(blockers)[i], Evaluate(count, blockers, tracked, now, limit).tracked;
      var p := Progress(Elems(blockers), o);
      t.Tracking? && t.since == (if Unchanged(tracked, o, p) then tracked.since else Signal(p, o.admitted, now))

  // T1 stalled: then the drain has stalled, naming the oldest blocker and its age, exactly when the age (now minus
  // the timer's start, never below zero) has reached the stall limit; otherwise it waits.
  lemma T1Stalled(count: Count, blockers: List<Blocker>, tracked: Tracked, now: Ms, limit: Ms, i: int)
    requires count != 0 && !OnlyOwners(count, Elems(blockers)) && Oldest(Elems(blockers), i)
    ensures var s := Evaluate(count, blockers, tracked, now, limit);
      s.tracked.Tracking? && (var age := Age(now, s.tracked.since);
        s.outcome == (if age >= limit then Stalled(Elems(blockers)[i].id, age) else Waiting))
}
