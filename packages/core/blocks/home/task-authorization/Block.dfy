// Block home/task-authorization: definitions and proofs of laws/home/TaskAuthorization.dfy.
include "../../../laws/home/TaskAuthorization.dfy"

module HomeTaskAuthorization refines HomeTaskAuthorizationLaws {
  // ---------- definitions (compiled to JS) ----------
  // Every search is tail-recursive, so it compiles to a loop and a store of any size is safe.

  // Pick: the id of the record a search found, or none.
  datatype Pick = NoPick | Picked(id: Token)

  // The id of the first scope that covers the request.
  function ScopeFor(ss: List<Scope>, r: Request): Pick {
    if ss.Nil? then NoPick
    else if ss.head.active && ss.head.epoch == r.epoch then Picked(ss.head.id)
    else ScopeFor(ss.tail, r)
  }

  // The id of the first grant that matches the request at time now.
  function GrantFor(gs: List<Grant>, r: Request, now: Ms): Pick {
    if gs.Nil? then NoPick
    else if gs.head.state.Available? && gs.head.expiresAt > now && gs.head.intent == r.intent
      && gs.head.target == r.target && gs.head.scope == r.scope && gs.head.epoch == r.epoch then Picked(gs.head.id)
    else GrantFor(gs.tail, r, now)
  }

  // Whether an active scope belongs to another restore epoch.
  predicate StaleScopes(ss: List<Scope>, r: Request) {
    if ss.Nil? then false else if ss.head.active && ss.head.epoch != r.epoch then true else StaleScopes(ss.tail, r)
  }

  // Whether an available grant belongs to another restore epoch.
  predicate StaleGrants(gs: List<Grant>, r: Request) {
    if gs.Nil? then false else if gs.head.state.Available? && gs.head.epoch != r.epoch then true else StaleGrants(gs.tail, r)
  }

  function Authorize(scopes: List<Scope>, grants: List<Grant>, r: Request, now: Ms): Decision {
    var s := ScopeFor(scopes, r);
    if s.Picked? then StandingScope(s.id)
    else
      var g := GrantFor(grants, r, now);
      if g.Picked? then OneUseGrant(g.id)
      else if StaleScopes(scopes, r) || StaleGrants(grants, r) then Reconfirm
      else GrantRequired
  }

  // ---------- proofs ----------

  // The items of a non-empty list: its head, then the items of its tail.
  lemma ElemsCons<T>(l: List<T>)
    requires l.Cons?
    ensures |Elems(l)| == 1 + |Elems(l.tail)| && Elems(l)[0] == l.head
    ensures forall k | 0 <= k < |Elems(l.tail)| :: Elems(l)[k + 1] == Elems(l.tail)[k]
  {}

  lemma ScopeForSpec(ss: List<Scope>, r: Request)
    ensures ScopeFor(ss, r).NoPick? <==> forall i | 0 <= i < |Elems(ss)| :: !Covers(Elems(ss)[i], r)
    ensures ScopeFor(ss, r).Picked? ==>
      exists i | 0 <= i < |Elems(ss)| :: Covers(Elems(ss)[i], r) && Elems(ss)[i].id == ScopeFor(ss, r).id
    decreases ss
  {
    if ss.Cons? {
      ElemsCons(ss);
      ScopeForSpec(ss.tail, r);
      if Covers(ss.head, r) {
        assert Covers(Elems(ss)[0], r);
      } else {
        if ScopeFor(ss.tail, r).Picked? {
          var i :| 0 <= i < |Elems(ss.tail)| && Covers(Elems(ss.tail)[i], r) && Elems(ss.tail)[i].id == ScopeFor(ss.tail, r).id;
          assert Elems(ss)[i + 1] == Elems(ss.tail)[i];
        }
        forall i | 0 <= i < |Elems(ss)| && ScopeFor(ss.tail, r).NoPick? ensures !Covers(Elems(ss)[i], r) {
          if i > 0 { assert Elems(ss)[i] == Elems(ss.tail)[i - 1]; }
        }
      }
    }
  }

  lemma ScopeForFirst(ss: List<Scope>, r: Request, i: int)
    requires 0 <= i < |Elems(ss)| && Covers(Elems(ss)[i], r)
    requires forall j | 0 <= j < i :: !Covers(Elems(ss)[j], r)
    ensures ScopeFor(ss, r) == Picked(Elems(ss)[i].id)
    decreases ss
  {
    assert ss.Cons?;
    ElemsCons(ss);
    if i > 0 {
      assert !Covers(Elems(ss)[0], r);
      ScopeForFirst(ss.tail, r, i - 1);
    }
  }

  lemma GrantForSpec(gs: List<Grant>, r: Request, now: Ms)
    ensures GrantFor(gs, r, now).NoPick? <==> forall i | 0 <= i < |Elems(gs)| :: !Matches(Elems(gs)[i], r, now)
    ensures GrantFor(gs, r, now).Picked? ==>
      exists i | 0 <= i < |Elems(gs)| :: Matches(Elems(gs)[i], r, now) && Elems(gs)[i].id == GrantFor(gs, r, now).id
    decreases gs
  {
    if gs.Cons? {
      ElemsCons(gs);
      GrantForSpec(gs.tail, r, now);
      if Matches(gs.head, r, now) {
        assert Matches(Elems(gs)[0], r, now);
      } else {
        if GrantFor(gs.tail, r, now).Picked? {
          var i :| 0 <= i < |Elems(gs.tail)| && Matches(Elems(gs.tail)[i], r, now) && Elems(gs.tail)[i].id == GrantFor(gs.tail, r, now).id;
          assert Elems(gs)[i + 1] == Elems(gs.tail)[i];
        }
        forall i | 0 <= i < |Elems(gs)| && GrantFor(gs.tail, r, now).NoPick? ensures !Matches(Elems(gs)[i], r, now) {
          if i > 0 { assert Elems(gs)[i] == Elems(gs.tail)[i - 1]; }
        }
      }
    }
  }

  lemma GrantForFirst(gs: List<Grant>, r: Request, now: Ms, i: int)
    requires 0 <= i < |Elems(gs)| && Matches(Elems(gs)[i], r, now)
    requires forall j | 0 <= j < i :: !Matches(Elems(gs)[j], r, now)
    ensures GrantFor(gs, r, now) == Picked(Elems(gs)[i].id)
    decreases gs
  {
    assert gs.Cons?;
    ElemsCons(gs);
    if i > 0 {
      assert !Matches(Elems(gs)[0], r, now);
      GrantForFirst(gs.tail, r, now, i - 1);
    }
  }

  lemma StaleScopesSpec(ss: List<Scope>, r: Request)
    ensures StaleScopes(ss, r) <==> exists i | 0 <= i < |Elems(ss)| :: StaleScope(Elems(ss)[i], r)
    decreases ss
  {
    if ss.Cons? {
      ElemsCons(ss);
      StaleScopesSpec(ss.tail, r);
      if StaleScope(ss.head, r) { assert StaleScope(Elems(ss)[0], r); }
      else {
        if StaleScopes(ss.tail, r) {
          var i :| 0 <= i < |Elems(ss.tail)| && StaleScope(Elems(ss.tail)[i], r);
          assert Elems(ss)[i + 1] == Elems(ss.tail)[i];
        }
        forall i | 0 <= i < |Elems(ss)| && StaleScope(Elems(ss)[i], r) ensures StaleScopes(ss.tail, r) {
          assert i > 0 && Elems(ss)[i] == Elems(ss.tail)[i - 1];
        }
      }
    }
  }

  lemma StaleGrantsSpec(gs: List<Grant>, r: Request)
    ensures StaleGrants(gs, r) <==> exists i | 0 <= i < |Elems(gs)| :: StaleGrant(Elems(gs)[i], r)
    decreases gs
  {
    if gs.Cons? {
      ElemsCons(gs);
      StaleGrantsSpec(gs.tail, r);
      if StaleGrant(gs.head, r) { assert StaleGrant(Elems(gs)[0], r); }
      else {
        if StaleGrants(gs.tail, r) {
          var i :| 0 <= i < |Elems(gs.tail)| && StaleGrant(Elems(gs.tail)[i], r);
          assert Elems(gs)[i + 1] == Elems(gs.tail)[i];
        }
        forall i | 0 <= i < |Elems(gs)| && StaleGrant(Elems(gs)[i], r) ensures StaleGrants(gs.tail, r) {
          assert i > 0 && Elems(gs)[i] == Elems(gs.tail)[i - 1];
        }
      }
    }
  }

  lemma S1Authority(scopes: List<Scope>, grants: List<Grant>, r: Request, now: Ms)
  { ScopeForSpec(scopes, r); GrantForSpec(grants, r, now); }

  lemma A1StandingFirst(scopes: List<Scope>, grants: List<Grant>, r: Request, now: Ms, i: int)
  { ScopeForFirst(scopes, r, i); }

  lemma G1OneUseGrant(scopes: List<Scope>, grants: List<Grant>, r: Request, now: Ms, i: int)
  { ScopeForSpec(scopes, r); GrantForFirst(grants, r, now, i); }

  lemma R1Refusal(scopes: List<Scope>, grants: List<Grant>, r: Request, now: Ms)
  { ScopeForSpec(scopes, r); GrantForSpec(grants, r, now); StaleScopesSpec(scopes, r); StaleGrantsSpec(grants, r); }
}
