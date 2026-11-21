// Laws of block home/task-authorization: whether a Home task may start, and under which authority: the
// maintainer's standing scope over trusted projects, a one-use grant he approved for exactly this request, or
// neither, so he must reconfirm permissions after a restore or approve a grant first.
// Strings enter as tokens (the shell numbers each distinct string of one call: ids, intent digests, targets,
// authorization scopes, restore epochs) and times as integer milliseconds.
// Shell: packages/gateway/src/modules/home/home-task-authorization.ts (HomeTaskAuthorization.authorize: it
// resolves the target, loads the store under its mutex, asks the block, then consumes the grant or records the
// request).
// The block refines this module. Edit a definition or a law only with a new independent review.
abstract module HomeTaskAuthorizationLaws {
  // Token: the number the shell gives one string of one call. A JavaScript number in the compiled block, which
  // only compares tokens.
  newtype Token = x: int | 0 <= x < 0x1_0000_0000
  // Ms: a time in milliseconds, as a JavaScript safe integer.
  newtype Ms = x: int | -0x20_0000_0000_0000 < x < 0x20_0000_0000_0000
  // List: a linked list, crossing to the shell as an array.
  datatype List<T> = Nil | Cons(head: T, tail: List<T>)
  datatype GrantState = available | consumed | revoked
  // Scope: a standing scope over all trusted projects: its id, whether it is active, and the restore epoch it was
  // enabled or last reconfirmed for.
  datatype Scope = Scope(id: Token, active: bool, epoch: Token)
  // Grant: a one-use grant the maintainer approved: its id, state, expiry, and the request it was approved for
  // (intent digest, target, authorization scope, restore epoch).
  datatype Grant = Grant(id: Token, state: GrantState, expiresAt: Ms, intent: Token, target: Token, scope: Token, epoch: Token)
  // Request: what a task asks to run: its intent digest, its resolved target, its authorization scope and the
  // current restore epoch.
  datatype Request = Request(intent: Token, target: Token, scope: Token, epoch: Token)
  // Decision: run under a standing scope or a one-use grant (by id), or refuse: reconfirm permissions, or a grant
  // is required.
  datatype Decision = StandingScope(scope: Token) | OneUseGrant(grant: Token) | Reconfirm | GrantRequired

  // Assumption A1: the shell gives equal strings equal tokens and distinct strings distinct tokens within one
  // call; the request's target is the trusted target the shell resolved (an untrusted target is refused before
  // the block is asked); a grant's expiry is its stored time, and `now` is the Gateway clock read once per call,
  // so one decision judges every grant at the same instant. The TypeScript this block replaced read the clock
  // again for each grant it tested; the two differ only when the millisecond clock advances during one
  // synchronous scan of the store and a grant tested later expires in that millisecond, and then this single
  // reading is the consistent one (#2632).
  // Assumption A2: the scopes and grants are the authorization store's, in stored order, loaded under the
  // authorization mutex; every stored scope covers all trusted projects (the store's validator admits no other
  // kind) and ids are unique. On OneUseGrant the shell saves that grant as consumed under the same mutex before
  // the task runs, so a grant authorizes at most one task; on GrantRequired it records the request once (by its
  // id).

  // Elems: the items of a linked list, in order.
  ghost function Elems<T>(l: List<T>): seq<T> { if l.Nil? then [] else [l.head] + Elems(l.tail) }

  // Covers: an active standing scope for the request's restore epoch.
  ghost predicate Covers(s: Scope, r: Request) { s.active && s.epoch == r.epoch }

  // Matches: an available grant that expires strictly after now and was approved for exactly this request: the
  // same intent digest, target, authorization scope and restore epoch.
  ghost predicate Matches(g: Grant, r: Request, now: Ms) {
    g.state == available && g.expiresAt > now
    && g.intent == r.intent && g.target == r.target && g.scope == r.scope && g.epoch == r.epoch
  }

  // StaleScope: an active standing scope for another restore epoch.
  ghost predicate StaleScope(s: Scope, r: Request) { s.active && s.epoch != r.epoch }

  // StaleGrant: an available grant (expired or not) for another restore epoch.
  ghost predicate StaleGrant(g: Grant, r: Request) { g.state == available && g.epoch != r.epoch }

  // The decision for a request at time now, given the store's scopes and grants.
  function Authorize(scopes: List<Scope>, grants: List<Grant>, r: Request, now: Ms): Decision

  // S1 authority: a task runs only under an active standing scope for the request's restore epoch, or, when there
  // is none, under an available grant that has not expired and was approved for exactly this request; never under
  // a consumed, revoked or expired grant, a grant for another intent, target, scope or epoch, or an inactive
  // scope or one from another restore epoch.
  lemma S1Authority(scopes: List<Scope>, grants: List<Grant>, r: Request, now: Ms)
    ensures var d := Authorize(scopes, grants, r, now);
      (d.StandingScope? ==> exists i | 0 <= i < |Elems(scopes)| :: Covers(Elems(scopes)[i], r) && Elems(scopes)[i].id == d.scope)
      && (d.OneUseGrant? ==>
            (forall i | 0 <= i < |Elems(scopes)| :: !Covers(Elems(scopes)[i], r))
            && (exists i | 0 <= i < |Elems(grants)| :: Matches(Elems(grants)[i], r, now) && Elems(grants)[i].id == d.grant))

  // A1 standing-scope-first: when an active standing scope covers the request's restore epoch, the task runs
  // under the first such scope in the store, whatever grants exist (no grant is used up).
  lemma A1StandingFirst(scopes: List<Scope>, grants: List<Grant>, r: Request, now: Ms, i: int)
    requires 0 <= i < |Elems(scopes)| && Covers(Elems(scopes)[i], r)
    requires forall j | 0 <= j < i :: !Covers(Elems(scopes)[j], r)
    ensures Authorize(scopes, grants, r, now) == StandingScope(Elems(scopes)[i].id)

  // G1 one-use-grant: with no covering standing scope, the task runs under the first grant in the store that is
  // available, unexpired and approved for exactly this request.
  lemma G1OneUseGrant(scopes: List<Scope>, grants: List<Grant>, r: Request, now: Ms, i: int)
    requires forall j | 0 <= j < |Elems(scopes)| :: !Covers(Elems(scopes)[j], r)
    requires 0 <= i < |Elems(grants)| && Matches(Elems(grants)[i], r, now)
    requires forall j | 0 <= j < i :: !Matches(Elems(grants)[j], r, now)
    ensures Authorize(scopes, grants, r, now) == OneUseGrant(Elems(grants)[i].id)

  // R1 refusal: with no covering scope and no matching grant the task does not run. The maintainer must
  // reconfirm permissions when an active scope or an available grant (expired or not) belongs to another restore
  // epoch; otherwise he must approve a grant for this request.
  lemma R1Refusal(scopes: List<Scope>, grants: List<Grant>, r: Request, now: Ms)
    requires forall j | 0 <= j < |Elems(scopes)| :: !Covers(Elems(scopes)[j], r)
    requires forall j | 0 <= j < |Elems(grants)| :: !Matches(Elems(grants)[j], r, now)
    ensures Authorize(scopes, grants, r, now)
      == if (exists j | 0 <= j < |Elems(scopes)| :: StaleScope(Elems(scopes)[j], r))
        || (exists j | 0 <= j < |Elems(grants)| :: StaleGrant(Elems(grants)[j], r))
      then Reconfirm else GrantRequired
}
