// Block schedule/calendar: definitions and proofs of laws/schedule/Calendar.dfy.
include "../../../laws/schedule/Calendar.dfy"

module ScheduleCalendar refines ScheduleCalendarLaws {
  // ---------- bounds (ghost) ----------
  // Every value the compiled functions compute stays within twice LIMIT of 1970 (times, a zone's offsets added
  // to them, and the starts of the local dates near them), far inside Ms, so the arithmetic is exact.

  ghost predicate Near(x: int) { -2 * LIMIT as int <= x <= 2 * LIMIT as int }
  ghost predicate NearOpt(o: Opt) { o.Some? ==> Near(o.v as int) }
  // The local dates of times in range lie within LD + 2 days of 1970-01-01; the scans reach 21 days further.
  ghost const LD: int := LIMIT as int / DAY as int
  ghost predicate Dated(d: int) { -LD - 2 <= d <= LD + 2 }
  ghost predicate DateOk(d: int) { -LD - 21 <= d <= LD + 21 }
  ghost predicate Offsets(base: Ms, cs: List<Change>) { -MAXOFF <= base <= MAXOFF && WfChanges(cs) }

  lemma DateStart(d: int)
    requires DateOk(d)
    ensures Near(d * DAY as int) && Near((d + 1) * DAY as int) && Near(d * DAY as int + 1439 * MINUTE as int)
    ensures Near((d + 1) * DAY as int + MAXOFF as int) && Near(d * DAY as int - MAXOFF as int - 1)
  {
    assert DAY as int * LD <= LIMIT as int;
    assert d * DAY as int <= (LD + 21) * DAY as int;
    assert d * DAY as int >= (-LD - 21) * DAY as int;
  }

  // ---------- definitions (compiled to JS) ----------

  // x, raised to lo when lo is given and later.
  function AtLeast(lo: Opt, x: Ms): Ms { if lo.Some? && lo.v >= x then lo.v else x }

  // A candidate instant `at` showing local time `loc`; candidates compare by local time, then by instant.
  datatype Cand = NoCand | Cand(loc: Ms, at: Ms)

  // The candidate with the earlier local time; a tie keeps a (ResFrom passes the earlier segment's candidate as
  // a, and its instant is the earlier one).
  function Better(a: Cand, b: Cand): Cand {
    if a.NoCand? then b
    else if b.NoCand? then a
    else if a.loc <= b.loc then a
    else b
  }

  // The earliest-shown local time in [K, E), and its earliest instant, among instants at or after `lo` (when
  // given) under offsets base-then-cs. Within one offset segment the local time grows with the instant, so the
  // segment's best instant is its first one showing at least K: max(segment start, K - offset).
  function ResFrom(base: Ms, cs: List<Change>, lo: Opt, K: Ms, E: Ms): Cand
    requires Offsets(base, cs) && NearOpt(lo) && Near(K as int) && Near(E as int)
    decreases cs
  {
    var t0 := AtLeast(lo, K - base);
    var first := if (cs.Nil? || t0 < cs.head.at) && t0 + base < E then Cand(t0 + base, t0) else NoCand;
    if cs.Nil? then first
    else Better(first, ResFrom(cs.head.offset, cs.tail, Some(AtLeast(lo, cs.head.at)), K, E))
  }

  // The offset at instant t under offsets base-then-cs.
  function OffAt(base: Ms, cs: List<Change>, t: Ms): (r: Ms)
    requires Offsets(base, cs)
    ensures r as int == OffFrom(base as int, cs, t as int) && -MAXOFF <= r <= MAXOFF
    decreases cs
  { if cs.Nil? || t < cs.head.at then base else OffAt(cs.head.offset, cs.tail, t) }

  // The local date at instant t.
  function DateAt(z: Zone, t: Ms): (d: Ms)
    requires Wf(z) && InRange(t)
    ensures d as int == LDate(z, t as int) && Dated(d as int)
  {
    var x := t + OffAt(z.base, z.changes, t);
    DateBound(x as int);
    x / DAY
  }

  // The ISO weekday of local date d.
  function WeekdayOf(d: Ms): (w: Ms)
    requires DateOk(d as int)
    ensures w as int == Weekday(d as int)
  { (d + 3) % 7 + 1 }

  // w is one of the weekdays.
  predicate Has(ws: List<Ms>, w: Ms)
    ensures Has(ws, w) == On(ws, w as int)
    decreases ws
  { if ws.Nil? then false else if ws.head == w then true else Has(ws.tail, w) }

  // Date d's occurrence of local time `minute`, if the date shows that time or a later one.
  function Resolve(z: Zone, d: Ms, minute: Ms): Opt
    requires Wf(z) && DateOk(d as int) && 0 <= minute < 1440
  {
    DateStart(d as int);
    var r := ResFrom(z.base, z.changes, None, d * DAY + minute * MINUTE, (d + 1) * DAY);
    if r.Cand? then Some(r.at) else None
  }

  // Date d's occurrence when d is one of the weekdays and it lies strictly between lo and hi.
  function Candidate(z: Zone, c: Calendar, d: Ms, lo: Ms, hi: Ms): Opt
    requires Wf(z) && WfCal(c) && DateOk(d as int)
  {
    if !Has(c.weekdays, WeekdayOf(d)) then None
    else
      var r := Resolve(z, d, c.minute);
      if r.Some? && lo < r.v < hi then r else None
  }

  // The lesser of date d's candidate and `rest`.
  function Least(z: Zone, c: Calendar, d: Ms, lo: Ms, hi: Ms, rest: Opt): Opt
    requires Wf(z) && WfCal(c) && DateOk(d as int)
  {
    var here := Candidate(z, c, d, lo, hi);
    if here.None? then rest else if rest.None? || here.v <= rest.v then here else rest
  }

  // The greater of date d's candidate and `rest`.
  function Most(z: Zone, c: Calendar, d: Ms, lo: Ms, hi: Ms, rest: Opt): Opt
    requires Wf(z) && WfCal(c) && DateOk(d as int)
  {
    var here := Candidate(z, c, d, lo, hi);
    if here.None? then rest else if rest.None? || here.v >= rest.v then here else rest
  }

  // The least candidate over the dates d .. last.
  function ScanMin(z: Zone, c: Calendar, d: Ms, last: Ms, lo: Ms, hi: Ms): Opt
    requires Wf(z) && WfCal(c) && -LD - 21 <= d as int <= last as int + 1 && DateOk(last as int)
    decreases last as int - d as int
  { if d > last then None else Least(z, c, d, lo, hi, ScanMin(z, c, d + 1, last, lo, hi)) }

  // The greatest candidate over the dates d .. last.
  function ScanMax(z: Zone, c: Calendar, d: Ms, last: Ms, lo: Ms, hi: Ms): Opt
    requires Wf(z) && WfCal(c) && -LD - 21 <= d as int <= last as int + 1 && DateOk(last as int)
    decreases last as int - d as int
  { if d > last then None else Most(z, c, d, lo, hi, ScanMax(z, c, d + 1, last, lo, hi)) }

  // An occurrence after `after` and before the horizon has a local date from two days before after's local
  // date to sixteen days after it (offsets are within 18 hours).
  function Next(z: Zone, c: Calendar, after: Ms): Opt {
    var d0 := DateAt(z, after);
    ScanMin(z, c, d0 - 2, d0 + 16, after, (d0 + 17) * DAY - MAXOFF)
  }

  // An occurrence at or after the floor and at or before `b` has a local date from sixteen days before b's
  // local date to two days after it.
  function Prior(z: Zone, c: Calendar, b: Ms): Opt {
    var d0 := DateAt(z, b);
    ScanMax(z, c, d0 - 16, d0 + 2, (d0 - 16) * DAY + MAXOFF - 1, b + 1)
  }

  function First(z: Zone, c: Calendar, now: Ms): Opt {
    if now > -LIMIT then Next(z, c, now - 1) else None
  }

  function Classify(z: Zone, c: Calendar, nxt: Ms, now: Ms, p: Policy): Result {
    if nxt > now then Result(None, Some(nxt), None)
    else if p.Latest? then Result(Prior(z, c, now), Next(z, c, now), None)
    else Result(None, Next(z, c, now), Prior(z, c, now))
  }

  // ---------- proofs ----------

  lemma F1First(z: Zone, c: Calendar, now: Ms) {}
  lemma C1ClassifyNotDue(z: Zone, c: Calendar, nxt: Ms, now: Ms, p: Policy) {}
  lemma C2ClassifyDue(z: Zone, c: Calendar, nxt: Ms, now: Ms, p: Policy) {}

  // A local time within 18 hours of a time in range has a local date DateOk allows.
  lemma DateBound(x: int)
    requires -(LIMIT as int) - MAXOFF as int <= x <= LIMIT as int + MAXOFF as int
    ensures Dated(x / DAY as int)
  {
    var D := DAY as int;
    var q := x / D;
    assert D * q + x % D == x && 0 <= x % D < D;
    assert D * LD + LIMIT as int % D == LIMIT as int && 0 <= LIMIT as int % D < D;
    assert MAXOFF as int < D;
    if q > LD + 2 { assert D * q >= D * (LD + 3); }
    if q < -LD - 2 { assert D * q <= D * (-LD - 3); }
  }

  // In: t is at or after lo (when given) and shows a local time in [K, E) under offsets base-then-cs.
  ghost predicate In(base: Ms, cs: List<Change>, lo: Opt, K: Ms, E: Ms, t: int) {
    (lo.None? || t >= lo.v as int) && K as int <= t + OffFrom(base as int, cs, t) < E as int
  }

  // Candidate a is no later than instant t by (local time, instant).
  ghost predicate LexLe(a: Cand, base: Ms, cs: List<Change>, t: int) {
    var l := t + OffFrom(base as int, cs, t);
    a.Cand? && (a.loc as int < l || (a.loc as int == l && a.at as int <= t))
  }

  // ResFrom finds the instant in range with the earliest local time, then the earliest instant.
  lemma ResFromSpec(base: Ms, cs: List<Change>, lo: Opt, K: Ms, E: Ms)
    requires Offsets(base, cs) && NearOpt(lo) && Near(K as int) && Near(E as int)
    decreases cs
    ensures var r := ResFrom(base, cs, lo, K, E);
      (r.NoCand? ==> forall t :: !In(base, cs, lo, K, E, t))
      && (r.Cand? ==>
            In(base, cs, lo, K, E, r.at as int) && r.loc as int == r.at as int + OffFrom(base as int, cs, r.at as int)
            && forall t | In(base, cs, lo, K, E, t) :: LexLe(r, base, cs, t))
  {
    var t0 := AtLeast(lo, K - base);
    var first := if (cs.Nil? || t0 < cs.head.at) && t0 + base < E then Cand(t0 + base, t0) else NoCand;
    if cs.Nil? {
      forall t | In(base, cs, lo, K, E, t) ensures first.Cand? && LexLe(first, base, cs, t) {}
    } else {
      var lo2 := AtLeast(lo, cs.head.at);
      var rest := ResFrom(cs.head.offset, cs.tail, Some(lo2), K, E);
      ResFromSpec(cs.head.offset, cs.tail, Some(lo2), K, E);
      var r := Better(first, rest);
      // The first segment's candidate is earlier than every instant of the later segments.
      assert first.Cand? && rest.Cand? ==> first.at < rest.at;
      forall t | In(base, cs, lo, K, E, t) ensures r.Cand? && LexLe(r, base, cs, t) {
        if t < cs.head.at as int {
          assert first.Cand? && LexLe(first, base, cs, t);
        } else {
          assert In(cs.head.offset, cs.tail, Some(lo2), K, E, t);
        }
      }
      if rest.Cand? {
        assert In(base, cs, lo, K, E, rest.at as int);
      }
    }
  }

  // Floor division by DAY: a local time within date d's day has local date d.
  lemma DateOf(x: int, d: int)
    requires d * DAY as int <= x < (d + 1) * DAY as int
    ensures x / DAY as int == d
  {
    var D := DAY as int;
    var q := x / D;
    assert D * q + x % D == x && 0 <= x % D < D;
    if q < d { assert q * D + D <= d * D; }
    if q > d { assert (d + 1) * D <= q * D; }
  }

  // The local date of an instant brackets its local time.
  lemma LDateBounds(z: Zone, t: int)
    ensures LDate(z, t) * DAY as int <= Local(z, t) < (LDate(z, t) + 1) * DAY as int
  {
    var x := Local(z, t);
    var D := DAY as int;
    assert D * (x / D) + x % D == x && 0 <= x % D < D;
  }

  // Resolve finds date d's occurrence of the local time exactly as Earliest describes it.
  lemma ResolveSpec(z: Zone, d: Ms, minute: Ms)
    requires Wf(z) && DateOk(d as int) && 0 <= minute < 1440
    ensures Resolve(z, d, minute).Some? ==> Earliest(z, d as int, minute as int, Resolve(z, d, minute).v as int)
    ensures Resolve(z, d, minute).None? ==> forall t {:trigger InDay(z, d as int, minute as int, t)} :: !InDay(z, d as int, minute as int, t)
  {
    DateStart(d as int);
    var K := d * DAY + minute * MINUTE;
    var E := (d + 1) * DAY;
    ResFromSpec(z.base, z.changes, None, K, E);
    var r := ResFrom(z.base, z.changes, None, K, E);
    forall t ensures InDay(z, d as int, minute as int, t) <==> In(z.base, z.changes, None, K, E, t) {}
    if r.NoCand? {
      forall t {:trigger InDay(z, d as int, minute as int, t)} ensures !InDay(z, d as int, minute as int, t) { assert !In(z.base, z.changes, None, K, E, t); }
    } else {
      forall u | InDay(z, d as int, minute as int, u)
        ensures Local(z, r.at as int) < Local(z, u) || (Local(z, r.at as int) == Local(z, u) && r.at as int <= u)
      {
        assert LexLe(r, z.base, z.changes, u);
      }
    }
  }

  // An occurrence is its own date's resolution, and that date is a weekday of the calendar.
  lemma OccResolve(z: Zone, c: Calendar, t: int)
    requires Wf(z) && WfCal(c) && Occ(z, c, t) && DateOk(LDate(z, t))
    ensures On(c.weekdays, Weekday(LDate(z, t)))
    ensures var r := Resolve(z, LDate(z, t) as Ms, c.minute); r.Some? && r.v as int == t
  {
    var d := LDate(z, t);
    DateStart(d);
    ResolveSpec(z, d as Ms, c.minute);
    var r := Resolve(z, d as Ms, c.minute);
    assert r.Some?;
    assert Earliest(z, d, c.minute as int, r.v as int);
  }

  // A candidate lies strictly between the bounds.
  lemma CandidateBounds(z: Zone, c: Calendar, d: Ms, lo: Ms, hi: Ms)
    requires Wf(z) && WfCal(c) && DateOk(d as int) && Candidate(z, c, d, lo, hi).Some?
    ensures lo < Candidate(z, c, d, lo, hi).v < hi
  {}

  // A candidate is an occurrence on its date, strictly between the bounds.
  lemma CandidateOcc(z: Zone, c: Calendar, d: Ms, lo: Ms, hi: Ms)
    requires Wf(z) && WfCal(c) && DateOk(d as int) && Candidate(z, c, d, lo, hi).Some?
    ensures var x := Candidate(z, c, d, lo, hi).v as int; lo as int < x < hi as int && LDate(z, x) == d as int && Occ(z, c, x)
  {
    var x := Candidate(z, c, d, lo, hi).v as int;
    CandidateBounds(z, c, d, lo, hi);
    ResolveSpec(z, d, c.minute);
    assert InDay(z, d as int, c.minute as int, x);
    DateOf(Local(z, x), d as int);
  }

  // An occurrence strictly between the bounds is the candidate of its date.
  lemma OccCandidate(z: Zone, c: Calendar, y: int, lo: Ms, hi: Ms)
    requires Wf(z) && WfCal(c) && Occ(z, c, y) && lo as int < y < hi as int && DateOk(LDate(z, y))
    ensures var r := Candidate(z, c, LDate(z, y) as Ms, lo, hi); r.Some? && r.v as int == y
  {
    OccResolve(z, c, y);
  }

  // ScanMin is the least candidate of the dates d .. last.
  lemma ScanMinSpec(z: Zone, c: Calendar, d: Ms, last: Ms, lo: Ms, hi: Ms)
    requires Wf(z) && WfCal(c) && -LD - 21 <= d as int <= last as int + 1 && DateOk(last as int)
    decreases last as int - d as int
    ensures var r := ScanMin(z, c, d, last, lo, hi);
      (r.Some? ==> exists e: Ms :: d <= e <= last && Candidate(z, c, e, lo, hi) == r)
      && forall e: Ms | d <= e <= last && Candidate(z, c, e, lo, hi).Some? :: r.Some? && r.v <= Candidate(z, c, e, lo, hi).v
  {
    if d <= last { ScanMinSpec(z, c, d + 1, last, lo, hi); }
  }

  // ScanMax is the greatest candidate of the dates d .. last.
  lemma ScanMaxSpec(z: Zone, c: Calendar, d: Ms, last: Ms, lo: Ms, hi: Ms)
    requires Wf(z) && WfCal(c) && -LD - 21 <= d as int <= last as int + 1 && DateOk(last as int)
    decreases last as int - d as int
    ensures var r := ScanMax(z, c, d, last, lo, hi);
      (r.Some? ==> exists e: Ms :: d <= e <= last && Candidate(z, c, e, lo, hi) == r)
      && forall e: Ms | d <= e <= last && Candidate(z, c, e, lo, hi).Some? :: r.Some? && r.v >= Candidate(z, c, e, lo, hi).v
  {
    if d <= last { ScanMaxSpec(z, c, d + 1, last, lo, hi); }
  }

  // The offset is within 18 hours, so the local time is within 18 hours of the instant.
  lemma OffBound(base: int, cs: List<Change>, t: int)
    requires -MAXOFF as int <= base <= MAXOFF as int && WfChanges(cs)
    decreases cs
    ensures -MAXOFF as int <= OffFrom(base, cs, t) <= MAXOFF as int
  {
    if cs.Cons? && t >= cs.head.at as int {
      OffBound(cs.head.offset as int, cs.tail, t);
    }
  }

  lemma LocalBound(z: Zone, t: int)
    requires Wf(z)
    ensures t - MAXOFF as int <= Local(z, t) <= t + MAXOFF as int
    ensures LDate(z, t) * DAY as int <= Local(z, t) < (LDate(z, t) + 1) * DAY as int
  {
    OffBound(z.base as int, z.changes, t);
    LDateBounds(z, t);
  }

  // An instant after `after` and before the horizon has a local date in d0 - 2 .. d0 + 16 (d0: after's date).
  lemma NextRange(z: Zone, after: Ms, y: int)
    requires Wf(z) && InRange(after) && after as int < y < Horizon(z, after as int)
    ensures LDate(z, after as int) - 2 <= LDate(z, y) <= LDate(z, after as int) + 16
    ensures DateOk(LDate(z, y))
  {
    var d0 := DateAt(z, after);
    LocalBound(z, after as int);
    LocalBound(z, y);
    DateBound(Local(z, after as int));
  }

  // An instant from the floor to b has a local date in d0 - 16 .. d0 + 2 (d0: b's date).
  lemma PriorRange(z: Zone, b: Ms, y: int)
    requires Wf(z) && InRange(b) && Floor(z, b as int) <= y <= b as int
    ensures LDate(z, b as int) - 16 <= LDate(z, y) <= LDate(z, b as int) + 2
    ensures DateOk(LDate(z, y))
  {
    var d0 := DateAt(z, b);
    LocalBound(z, b as int);
    LocalBound(z, y);
    DateBound(Local(z, b as int));
  }

  lemma N1NextSound(z: Zone, c: Calendar, after: Ms)
  {
    var d0 := DateAt(z, after);
    var hi := (d0 + 17) * DAY - MAXOFF;
    ScanMinSpec(z, c, d0 - 2, d0 + 16, after, hi);
    var e: Ms :| d0 - 2 <= e <= d0 + 16 && Candidate(z, c, e, after, hi) == Next(z, c, after);
    CandidateOcc(z, c, e, after, hi);
  }

  lemma N2NextLeast(z: Zone, c: Calendar, after: Ms, y: int)
  {
    N1NextSound(z, c, after);
    if y < Horizon(z, after as int) {
      var d0 := DateAt(z, after);
      var hi := (d0 + 17) * DAY - MAXOFF;
      NextRange(z, after, y);
      OccCandidate(z, c, y, after, hi);
      ScanMinSpec(z, c, d0 - 2, d0 + 16, after, hi);
    }
  }

  lemma N3NextComplete(z: Zone, c: Calendar, after: Ms, y: int)
  {
    var d0 := DateAt(z, after);
    var hi := (d0 + 17) * DAY - MAXOFF;
    NextRange(z, after, y);
    OccCandidate(z, c, y, after, hi);
    ScanMinSpec(z, c, d0 - 2, d0 + 16, after, hi);
  }

  lemma P1PriorSound(z: Zone, c: Calendar, b: Ms)
  {
    var d0 := DateAt(z, b);
    var lo := (d0 - 16) * DAY + MAXOFF - 1;
    ScanMaxSpec(z, c, d0 - 16, d0 + 2, lo, b + 1);
    var e: Ms :| d0 - 16 <= e <= d0 + 2 && Candidate(z, c, e, lo, b + 1) == Prior(z, c, b);
    CandidateOcc(z, c, e, lo, b + 1);
  }

  lemma P2PriorGreatest(z: Zone, c: Calendar, b: Ms, y: int)
  {
    P1PriorSound(z, c, b);
    if y >= Floor(z, b as int) {
      var d0 := DateAt(z, b);
      var lo := (d0 - 16) * DAY + MAXOFF - 1;
      PriorRange(z, b, y);
      OccCandidate(z, c, y, lo, b + 1);
      ScanMaxSpec(z, c, d0 - 16, d0 + 2, lo, b + 1);
    }
  }

  lemma P3PriorComplete(z: Zone, c: Calendar, b: Ms, y: int)
  {
    var d0 := DateAt(z, b);
    var lo := (d0 - 16) * DAY + MAXOFF - 1;
    PriorRange(z, b, y);
    OccCandidate(z, c, y, lo, b + 1);
    ScanMaxSpec(z, c, d0 - 16, d0 + 2, lo, b + 1);
  }

  // Seven consecutive dates cover every weekday: date d0 + 1 + k has weekday w.
  lemma WeekdayWithin(d0: int, w: int) returns (k: int)
    requires 1 <= w <= 7
    ensures 0 <= k < 7 && Weekday(d0 + 1 + k) == w
  {
    k := (w - 1 - (d0 + 4)) % 7;
    var q := (w - 1 - (d0 + 4)) / 7;
    assert w - 1 - (d0 + 4) == 7 * q + k;
    assert d0 + 1 + k + 3 == (w - 1) + 7 * (-q);
    ModMultiple(w - 1, -q);
  }

  lemma ModMultiple(r: int, q: int)
    requires 0 <= r < 7
    ensures (r + 7 * q) % 7 == r
  {
    var x := r + 7 * q;
    assert 7 * (x / 7) + x % 7 == x && 0 <= x % 7 < 7;
    var D := x / 7 - q;
    assert 7 * D == r - x % 7;
    if D >= 1 { assert 7 * D >= 7; }
    if D <= -1 { assert 7 * D <= -7; }
  }

  lemma N4NextProgress(z: Zone, c: Calendar, after: Ms)
  {
    var d0 := DateAt(z, after);
    LocalBound(z, after as int);
    var w := c.weekdays.head;
    var k := WeekdayWithin(d0 as int, w as int);
    var d := d0 + 1 + k as Ms;
    DateStart(d as int);
    var K := d * DAY + c.minute * MINUTE;
    var hi := (d0 + 17) * DAY - MAXOFF;
    assert Resolve(z, d, c.minute) == Some(K - z.base);
    assert Candidate(z, c, d, after, hi) == Some(K - z.base);
    ScanMinSpec(z, c, d0 - 2, d0 + 16, after, hi);
  }
}
