// Block security/public-host: definitions and proofs of laws/security/PublicHost.dfy.
include "../../../laws/security/PublicHost.dfy"

module SecurityPublicHost refines SecurityPublicHostLaws {
  // ---------- definitions (compiled to JS) ----------
  // Every walk is tail-recursive, so it compiles to a loop and a key with any number of attempts is safe.

  predicate BlockedV4(a: Octet, b: Octet, c: Octet, d: Octet) {
    a == 0 || a == 10 || a == 127 || a >= 224
    || (a == 100 && 64 <= b <= 127)
    || (a == 169 && b == 254)
    || (a == 172 && 16 <= b <= 31)
    || (a == 192 && (b == 0 || b == 168))
    || (a == 198 && (b == 18 || b == 19))
    || (a == 198 && b == 51 && c == 100)
    || (a == 203 && b == 0 && c == 113)
  }

  predicate BlockedV6(h0: Hextet, h1: Hextet) {
    h0 < 0x2000 || h0 > 0x3fff || h0 == 0x2002 || (h0 == 0x2001 && (h1 == 0x0db8 || h1 == 0)) || (h0 == 0x3fff && h1 < 0x1000)
  }

  // Whether an attempt at t still counts at now.
  predicate Live(t: Ms, now: Ms, window: Ms) { t > now || now - t < window }

  // The list a reversed, followed by b.
  function RevOnto(a: List<Ms>, b: List<Ms>): List<Ms> { if a.Nil? then b else RevOnto(a.tail, Cons(a.head, b)) }

  // The attempt times of ts that still count at now, reversed, followed by acc.
  function LiveRev(ts: List<Ms>, now: Ms, window: Ms, acc: List<Ms>): List<Ms> {
    if ts.Nil? then acc
    else LiveRev(ts.tail, now, window, if Live(ts.head, now, window) then Cons(ts.head, acc) else acc)
  }

  // Whether l has fewer than m items.
  predicate Fewer(l: List<Ms>, m: Count) { if m == 0 then false else if l.Nil? then true else Fewer(l.tail, m - 1) }

  function Recent(ts: List<Ms>, now: Ms, window: Ms): List<Ms> { RevOnto(LiveRev(ts, now, window, Nil), Nil) }

  function Admit(ts: List<Ms>, now: Ms, window: Ms, maximum: Count): Admission {
    var live := LiveRev(ts, now, window, Nil);
    var admitted := Fewer(live, maximum);
    Admission(admitted, RevOnto(if admitted then Cons(now, live) else live, Nil))
  }

  // ---------- proofs ----------

  lemma B4Ranges(a: Octet, b: Octet, c: Octet, d: Octet) {}

  lemma B6Ranges(h0: Hextet, h1: Hextet) {}

  lemma M6Mapped(h1: Hextet) {}

  // Back: the items of a linked list, last first.
  ghost function Back(l: List<Ms>): seq<Ms> { if l.Nil? then [] else Back(l.tail) + [l.head] }

  lemma BackLength(l: List<Ms>)
    ensures |Back(l)| == |Elems(l)|
  { if l.Cons? { BackLength(l.tail); } }

  lemma RevOntoSpec(a: List<Ms>, b: List<Ms>)
    ensures Elems(RevOnto(a, b)) == Back(a) + Elems(b)
    decreases a
  {
    if a.Cons? {
      RevOntoSpec(a.tail, Cons(a.head, b));
      assert Back(a.tail) + Elems(Cons(a.head, b)) == Back(a.tail) + [a.head] + Elems(b);
    }
  }

  lemma LiveRevSpec(ts: List<Ms>, now: Ms, window: Ms, acc: List<Ms>)
    ensures Back(LiveRev(ts, now, window, acc)) == Back(acc) + FreshOf(Elems(ts), now, window)
    decreases ts
  {
    if ts.Cons? {
      var next := if Live(ts.head, now, window) then Cons(ts.head, acc) else acc;
      LiveRevSpec(ts.tail, now, window, next);
      assert Elems(ts)[1..] == Elems(ts.tail);
      assert Elems(ts)[0] == ts.head;
    }
  }

  lemma FewerSpec(l: List<Ms>, m: Count)
    ensures Fewer(l, m) <==> |Elems(l)| < m as int
    decreases l
  { if m != 0 && l.Cons? { FewerSpec(l.tail, m - 1); } }

  lemma P1Prune(ts: List<Ms>, now: Ms, window: Ms) {
    LiveRevSpec(ts, now, window, Nil);
    RevOntoSpec(LiveRev(ts, now, window, Nil), Nil);
  }

  lemma A1Admission(ts: List<Ms>, now: Ms, window: Ms, maximum: Count) {
    var live := LiveRev(ts, now, window, Nil);
    LiveRevSpec(ts, now, window, Nil);
    BackLength(live);
    FewerSpec(live, maximum);
    RevOntoSpec(Cons(now, live), Nil);
    RevOntoSpec(live, Nil);
  }

  lemma NoneFresh(ts: seq<Ms>, now: Ms, window: Ms)
    requires forall i | 0 <= i < |ts| :: !Fresh(ts[i], now, window)
    ensures FreshOf(ts, now, window) == []
    decreases |ts|
  { if |ts| > 0 { NoneFresh(ts[1..], now, window); } }

  lemma S1Stale(ts: List<Ms>, now: Ms, window: Ms, maximum: Count) {
    NoneFresh(Elems(ts), now, window);
    A1Admission(ts, now, window, maximum);
  }

  lemma ElemsFromSeq(s: seq<Ms>)
    ensures Elems(FromSeq(s)) == s
    decreases |s|
  { if |s| > 0 { ElemsFromSeq(s[1..]); } }

  lemma FreshCat(a: seq<Ms>, b: seq<Ms>, now: Ms, window: Ms)
    ensures FreshOf(a + b, now, window) == FreshOf(a, now, window) + FreshOf(b, now, window)
    decreases |a|
  {
    if |a| == 0 { assert a + b == b; }
    else {
      assert (a + b)[0] == a[0] && (a + b)[1..] == a[1..] + b;
      FreshCat(a[1..], b, now, window);
      var h: seq<Ms> := if Fresh(a[0], now, window) then [a[0]] else [];
      assert FreshOf(a + b, now, window) == h + FreshOf(a[1..] + b, now, window);
      assert FreshOf(a, now, window) == h + FreshOf(a[1..], now, window);
    }
  }

  // An attempt that counts at a later time t counted at n too, so filtering at n and then at t is filtering at t.
  lemma FreshTwice(s: seq<Ms>, n: Ms, t: Ms, window: Ms)
    requires n <= t
    ensures FreshOf(FreshOf(s, n, window), t, window) == FreshOf(s, t, window)
    decreases |s|
  {
    if |s| > 0 {
      FreshTwice(s[1..], n, t, window);
      FreshCat(if Fresh(s[0], n, window) then [s[0]] else [], FreshOf(s[1..], n, window), t, window);
    }
  }

  // What the limiter keeps counts at any time t from the last attempt on exactly as the admitted attempts do.
  lemma KeptCounts(nows: seq<Ms>, window: Ms, maximum: Count, t: Ms)
    requires forall i, j | 0 <= i < j < |nows| :: nows[i] <= nows[j]
    requires |nows| == 0 || t >= nows[|nows| - 1]
    ensures FreshOf(Kept(nows, window, maximum), t, window) == FreshOf(AdmittedTimes(nows, window, maximum), t, window)
    decreases |nows|
  {
    if |nows| > 0 {
      var p, n := nows[..|nows| - 1], nows[|nows| - 1];
      var kept := Kept(p, window, maximum);
      var own: seq<Ms> := if Admitted(nows, window, maximum) then [n] else [];
      ElemsFromSeq(kept);
      A1Admission(FromSeq(kept), n, window, maximum);
      assert Kept(nows, window, maximum) == FreshOf(kept, n, window) + own;
      KeptCounts(p, window, maximum, t);
      FreshCat(FreshOf(kept, n, window), own, t, window);
      FreshTwice(kept, n, t, window);
      FreshCat(AdmittedTimes(p, window, maximum), own, t, window);
    }
  }

  lemma W1Window(nows: seq<Ms>, window: Ms, maximum: Count) {
    var p, n := nows[..|nows| - 1], nows[|nows| - 1];
    var kept := Kept(p, window, maximum);
    ElemsFromSeq(kept);
    A1Admission(FromSeq(kept), n, window, maximum);
    KeptCounts(p, window, maximum, n);
  }
}
