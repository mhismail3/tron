// Laws of block home/obligations: when Home replays or appends one maintainer-obligation event, whether the event is
// a legal transition of its item, a contradiction the ledger refuses, or over the ledger's cap, and which items the
// maintainer still owes.
// Shells: packages/gateway/src/modules/home/home-obligations.ts (replayObligations folds canonical events in order,
// owed reads an item's state) and packages/gateway/src/modules/home/home-owner.ts (obligationTool asks the block
// before appending an event). Both keep the ledger map, check field shapes, sources and quotes, and turn a refusal
// into their error.
// The block refines this module. Edit a definition or a law only with a new independent review.
abstract module HomeObligationsLaws {
  // Count: how many items the ledger holds before the event.
  newtype Count = x: int | 0 <= x < 0x1_0000_0000
  // State: an item's state, named after the event that set it: request opened it, reportedDone closed the human
  // action on the maintainer's word, verified closed it with tool evidence, reopened opened it again.
  datatype State = request | reportedDone | verified | reopened
  // Prior: the item the event names, as the ledger holds it before the event: absent, or present in a state.
  datatype Prior = Absent | Present(state: State)
  // Outcome: the event is a contradiction of the ledger; it would make the ledger exceed its cap; or the item moves
  // to a state.
  datatype Outcome = Contradictory | Full | Next(state: State)

  // Assumption A1: the shell passes the item the event's id names (Absent when the ledger has none) and the
  // ledger's item count before the event; an event's action is its new state. Before asking, the shell has refused
  // an event whose fields, id, text, quote, issue link or evidence fields are malformed, whose source is not a
  // verbatim maintainer message (or, for verified, whose evidence is not a successful tool result) of the same
  // chapter; and, when appending, a reopen quoting the very message that closed the item. On Next it stores the
  // item in the returned state (a request with its text and source); on Contradictory or Full it refuses the whole
  // ledger (replay) or appends nothing (write).

  // The cap: the ledger holds at most this many items.
  const Cap: Count := 1000

  // Legal: the transitions the ledger admits. A request opens an id the ledger does not hold; reported-done closes
  // an owed item; verified closes an owed item or one the maintainer reported done; reopened reopens a closed item.
  ghost predicate Legal(p: Prior, a: State) {
    match a
    case request => p.Absent?
    case reportedDone => p.Present? && (p.state == request || p.state == reopened)
    case verified => p.Present? && p.state != verified
    case reopened => p.Present? && (p.state == reportedDone || p.state == verified)
  }

  // Whether the maintainer still owes an item in this state.
  predicate Owed(s: State)

  // The outcome of an event with action a on prior p, when the ledger holds size items.
  function Step(p: Prior, a: State, size: Count): Outcome

  // O1 owed: an item is owed exactly when it is requested or reopened; reported done or verified, it is not.
  lemma O1Owed(s: State)
    ensures Owed(s) <==> s == request || s == reopened

  // T1 transitions: a legal event moves its item to the event's action, unless it is a request when the ledger
  // already holds the cap; nothing else moves an item.
  lemma T1Transitions(p: Prior, a: State, size: Count)
    ensures Step(p, a, size).Next? <==> Legal(p, a) && !(a == request && size >= Cap)
    ensures Step(p, a, size).Next? ==> Step(p, a, size).state == a

  // C1 contradiction: an illegal event (a request for an id the ledger holds, any other event for an id it does not
  // hold, closing a closed item, reopening an owed one) is refused as a contradiction, whatever the ledger's size.
  lemma C1Contradiction(p: Prior, a: State, size: Count)
    ensures Step(p, a, size).Contradictory? <==> !Legal(p, a)

  // K1 cap: a legal request is refused as over the cap exactly when the ledger already holds the cap, so a ledger
  // never holds more than the cap: only a request adds an item, and only when fewer than the cap are held.
  lemma K1Cap(p: Prior, a: State, size: Count)
    ensures Step(p, a, size).Full? <==> Legal(p, a) && a == request && size >= Cap
    ensures Step(p, a, size).Next? && p.Absent? ==> size < Cap
}
