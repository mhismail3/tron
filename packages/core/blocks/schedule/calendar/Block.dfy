// Block schedule/calendar: definitions and proofs of laws/schedule/Calendar.dfy.
include "../../../laws/schedule/Calendar.dfy"

module ScheduleCalendar refines ScheduleCalendarLaws {
  // ---------- definitions (compiled to JS) ----------

  // x, raised to lo when lo is given and later.
  function AtLeast(lo: Opt, x: int): int { if lo.Some? && lo.v >= x then lo.v else x }

  // A candidate instant `at` showing local time `loc`; candidates compare by local time, then by instant.
  datatype Cand = NoCand | Cand(loc: int, at: int)

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
  function ResFrom(base: int, cs: seq<Change>, lo: Opt, K: int, E: int): Cand
    decreases |cs|
  {
    var t0 := AtLeast(lo, K - base);
    var first := if (|cs| == 0 || t0 < cs[0].at) && t0 + base < E then Cand(t0 + base, t0) else NoCand;
    if |cs| == 0 then first
    else Better(first, ResFrom(cs[0].offset, cs[1..], Some(AtLeast(lo, cs[0].at)), K, E))
  }

  // Date d's occurrence of local time `minute`, if the date shows that time or a later one.
  function Resolve(z: Zone, d: int, minute: int): Opt {
    var r := ResFrom(z.base, z.changes, None, d * DAY + minute * MINUTE, (d + 1) * DAY);
    if r.Cand? then Some(r.at) else None
  }

  // Date d's occurrence when d is one of the weekdays and it lies strictly between lo and hi.
  function Candidate(z: Zone, c: Calendar, d: int, lo: int, hi: int): Opt {
    if Weekday(d) !in c.weekdays then None
    else
      var r := Resolve(z, d, c.minute);
      if r.Some? && lo < r.v < hi then r else None
  }

  // The lesser of date d's candidate and `rest`.
  function Least(z: Zone, c: Calendar, d: int, lo: int, hi: int, rest: Opt): Opt {
    var here := Candidate(z, c, d, lo, hi);
    if here.None? then rest else if rest.None? || here.v <= rest.v then here else rest
  }

  // The greater of date d's candidate and `rest`.
  function Most(z: Zone, c: Calendar, d: int, lo: int, hi: int, rest: Opt): Opt {
    var here := Candidate(z, c, d, lo, hi);
    if here.None? then rest else if rest.None? || here.v >= rest.v then here else rest
  }

  // The least candidate over the dates d .. last.
  function ScanMin(z: Zone, c: Calendar, d: int, last: int, lo: int, hi: int): Opt
    decreases last - d
  { if d > last then None else Least(z, c, d, lo, hi, ScanMin(z, c, d + 1, last, lo, hi)) }

  // The greatest candidate over the dates d .. last.
  function ScanMax(z: Zone, c: Calendar, d: int, last: int, lo: int, hi: int): Opt
    decreases last - d
  { if d > last then None else Most(z, c, d, lo, hi, ScanMax(z, c, d + 1, last, lo, hi)) }

  // An occurrence after `after` and before the horizon has a local date from two days before after's local
  // date to sixteen days after it (offsets are within 18 hours).
  function Next(z: Zone, c: Calendar, after: int): Opt {
    var d0 := LDate(z, after);
    ScanMin(z, c, d0 - 2, d0 + 16, after, Horizon(z, after))
  }

  // An occurrence at or after the floor and at or before `b` has a local date from sixteen days before b's
  // local date to two days after it.
  function Prior(z: Zone, c: Calendar, b: int): Opt {
    var d0 := LDate(z, b);
    ScanMax(z, c, d0 - 16, d0 + 2, Floor(z, b) - 1, b + 1)
  }

  function First(z: Zone, c: Calendar, now: int): Opt {
    Next(z, c, now - 1)
  }

  function Classify(z: Zone, c: Calendar, nxt: int, now: int, p: Policy): Result {
    if nxt > now then Result(None, Some(nxt), None)
    else if p == Latest then Result(Prior(z, c, now), Next(z, c, now), None)
    else Result(None, Next(z, c, now), Prior(z, c, now))
  }

  // ---------- proofs ----------

  lemma F1First(z: Zone, c: Calendar, now: int) {}
  lemma C1ClassifyNotDue(z: Zone, c: Calendar, nxt: int, now: int, p: Policy) {}
  lemma C2ClassifyDue(z: Zone, c: Calendar, nxt: int, now: int, p: Policy) {}

  // In: t is at or after lo (when given) and shows a local time in [K, E) under offsets base-then-cs.
  ghost predicate In(base: int, cs: seq<Change>, lo: Opt, K: int, E: int, t: int) {
    (lo.None? || t >= lo.v) && K <= t + OffFrom(base, cs, t) < E
  }

  // Candidate a is no later than instant t by (local time, instant).
  ghost predicate LexLe(a: Cand, base: int, cs: seq<Change>, t: int) {
    a.Cand? && (a.loc < t + OffFrom(base, cs, t) || (a.loc == t + OffFrom(base, cs, t) && a.at <= t))
  }

  // ResFrom finds the instant in range with the earliest local time, then the earliest instant.
  lemma ResFromSpec(base: int, cs: seq<Change>, lo: Opt, K: int, E: int)
    decreases |cs|
    ensures var r := ResFrom(base, cs, lo, K, E);
      (r.NoCand? ==> forall t :: !In(base, cs, lo, K, E, t))
      && (r.Cand? ==>
            In(base, cs, lo, K, E, r.at) && r.loc == r.at + OffFrom(base, cs, r.at)
            && forall t | In(base, cs, lo, K, E, t) :: LexLe(r, base, cs, t))
  {
    var t0 := AtLeast(lo, K - base);
    var first := if (|cs| == 0 || t0 < cs[0].at) && t0 + base < E then Cand(t0 + base, t0) else NoCand;
    if |cs| == 0 {
      forall t | In(base, cs, lo, K, E, t) ensures first.Cand? && LexLe(first, base, cs, t) {}
    } else {
      var lo2 := AtLeast(lo, cs[0].at);
      var rest := ResFrom(cs[0].offset, cs[1..], Some(lo2), K, E);
      ResFromSpec(cs[0].offset, cs[1..], Some(lo2), K, E);
      var r := Better(first, rest);
      // The first segment's candidate is earlier than every instant of the later segments.
      assert first.Cand? && rest.Cand? ==> first.at < rest.at;
      forall t | In(base, cs, lo, K, E, t) ensures r.Cand? && LexLe(r, base, cs, t) {
        if t < cs[0].at {
          assert first.Cand? && LexLe(first, base, cs, t);
        } else {
          assert In(cs[0].offset, cs[1..], Some(lo2), K, E, t);
        }
      }
      if rest.Cand? {
        assert In(base, cs, lo, K, E, rest.at);
      }
    }
  }
  // Floor division by DAY: a local time within date d's day has local date d.
  lemma DateOf(x: int, d: int)
    requires d * DAY <= x < (d + 1) * DAY
    ensures x / DAY == d
  {
    var q := x / DAY;
    assert DAY * q + x % DAY == x && 0 <= x % DAY < DAY;
    if q < d { assert q * DAY + DAY <= d * DAY; }
    if q > d { assert (d + 1) * DAY <= q * DAY; }
  }

  // The local date of an instant brackets its local time.
  lemma LDateBounds(z: Zone, t: int)
    ensures LDate(z, t) * DAY <= Local(z, t) < (LDate(z, t) + 1) * DAY
  {
    var x := Local(z, t);
    assert DAY * (x / DAY) + x % DAY == x && 0 <= x % DAY < DAY;
  }

  // Resolve finds date d's occurrence of the local time exactly as Earliest describes it.
  lemma ResolveSpec(z: Zone, d: int, minute: int)
    ensures Resolve(z, d, minute).Some? ==> Earliest(z, d, minute, Resolve(z, d, minute).v)
    ensures Resolve(z, d, minute).None? ==> forall t :: !InDay(z, d, minute, t)
  {
    var K := d * DAY + minute * MINUTE;
    var E := (d + 1) * DAY;
    ResFromSpec(z.base, z.changes, None, K, E);
    var r := ResFrom(z.base, z.changes, None, K, E);
    forall t ensures InDay(z, d, minute, t) <==> In(z.base, z.changes, None, K, E, t) {}
    if r.Cand? {
      forall u | InDay(z, d, minute, u)
        ensures Local(z, r.at) < Local(z, u) || (Local(z, r.at) == Local(z, u) && r.at <= u)
      {
        assert LexLe(r, z.base, z.changes, u);
      }
    }
  }

  // An occurrence is its own date's resolution, and that date is a weekday of the calendar.
  lemma OccResolve(z: Zone, c: Calendar, t: int)
    requires Occ(z, c, t)
    ensures Weekday(LDate(z, t)) in c.weekdays && Resolve(z, LDate(z, t), c.minute) == Some(t)
  {
    var d := LDate(z, t);
    ResolveSpec(z, d, c.minute);
    var r := Resolve(z, d, c.minute);
    assert r.Some?;
    assert Earliest(z, d, c.minute, r.v);
  }

  // A candidate is an occurrence on its date, strictly between the bounds.
  lemma CandidateOcc(z: Zone, c: Calendar, d: int, lo: int, hi: int)
    requires WfCal(c) && Candidate(z, c, d, lo, hi).Some?
    ensures var x := Candidate(z, c, d, lo, hi).v; lo < x < hi && LDate(z, x) == d && Occ(z, c, x)
  {
    var x := Candidate(z, c, d, lo, hi).v;
    ResolveSpec(z, d, c.minute);
    assert InDay(z, d, c.minute, x);
    DateOf(Local(z, x), d);
  }

  // An occurrence strictly between the bounds is the candidate of its date.
  lemma OccCandidate(z: Zone, c: Calendar, y: int, lo: int, hi: int)
    requires Occ(z, c, y) && lo < y < hi
    ensures Candidate(z, c, LDate(z, y), lo, hi) == Some(y)
  {
    OccResolve(z, c, y);
  }
  // ScanMin is the least candidate of the dates d .. last.
  lemma ScanMinSpec(z: Zone, c: Calendar, d: int, last: int, lo: int, hi: int)
    decreases last - d
    ensures var r := ScanMin(z, c, d, last, lo, hi);
      (r.Some? ==> exists e :: d <= e <= last && Candidate(z, c, e, lo, hi) == r)
      && forall e | d <= e <= last && Candidate(z, c, e, lo, hi).Some? :: r.Some? && r.v <= Candidate(z, c, e, lo, hi).v
  {
    if d <= last { ScanMinSpec(z, c, d + 1, last, lo, hi); }
  }

  // ScanMax is the greatest candidate of the dates d .. last.
  lemma ScanMaxSpec(z: Zone, c: Calendar, d: int, last: int, lo: int, hi: int)
    decreases last - d
    ensures var r := ScanMax(z, c, d, last, lo, hi);
      (r.Some? ==> exists e :: d <= e <= last && Candidate(z, c, e, lo, hi) == r)
      && forall e | d <= e <= last && Candidate(z, c, e, lo, hi).Some? :: r.Some? && r.v >= Candidate(z, c, e, lo, hi).v
  {
    if d <= last { ScanMaxSpec(z, c, d + 1, last, lo, hi); }
  }

  // The offset is within 18 hours, so the local time is within 18 hours of the instant.
  lemma OffBound(base: int, cs: seq<Change>, t: int)
    requires -MAXOFF <= base <= MAXOFF && forall i | 0 <= i < |cs| :: -MAXOFF <= cs[i].offset <= MAXOFF
    decreases |cs|
    ensures -MAXOFF <= OffFrom(base, cs, t) <= MAXOFF
  {
    if |cs| > 0 && t >= cs[0].at {
      OffBound(cs[0].offset, cs[1..], t);
    }
  }

  lemma LocalBound(z: Zone, t: int)
    requires Wf(z)
    ensures t - MAXOFF <= Local(z, t) <= t + MAXOFF && LDate(z, t) * DAY <= Local(z, t) < (LDate(z, t) + 1) * DAY
  {
    OffBound(z.base, z.changes, t);
    LDateBounds(z, t);
  }
  // An instant after `after` and before the horizon has a local date in d0 - 2 .. d0 + 16 (d0: after's date).
  lemma NextRange(z: Zone, after: int, y: int)
    requires Wf(z) && after < y < Horizon(z, after)
    ensures LDate(z, after) - 2 <= LDate(z, y) <= LDate(z, after) + 16
  {
    LocalBound(z, after);
    LocalBound(z, y);
  }

  // An instant from the floor to b has a local date in d0 - 16 .. d0 + 2 (d0: b's date).
  lemma PriorRange(z: Zone, b: int, y: int)
    requires Wf(z) && Floor(z, b) <= y <= b
    ensures LDate(z, b) - 16 <= LDate(z, y) <= LDate(z, b) + 2
  {
    LocalBound(z, b);
    LocalBound(z, y);
  }

  lemma N1NextSound(z: Zone, c: Calendar, after: int)
  {
    var d0 := LDate(z, after);
    ScanMinSpec(z, c, d0 - 2, d0 + 16, after, Horizon(z, after));
    var e :| d0 - 2 <= e <= d0 + 16 && Candidate(z, c, e, after, Horizon(z, after)) == Next(z, c, after);
    CandidateOcc(z, c, e, after, Horizon(z, after));
  }

  lemma N2NextLeast(z: Zone, c: Calendar, after: int, y: int)
  {
    N1NextSound(z, c, after);
    if y < Horizon(z, after) {
      var d0 := LDate(z, after);
      NextRange(z, after, y);
      OccCandidate(z, c, y, after, Horizon(z, after));
      ScanMinSpec(z, c, d0 - 2, d0 + 16, after, Horizon(z, after));
    }
  }

  lemma N3NextComplete(z: Zone, c: Calendar, after: int, y: int)
  {
    var d0 := LDate(z, after);
    NextRange(z, after, y);
    OccCandidate(z, c, y, after, Horizon(z, after));
    ScanMinSpec(z, c, d0 - 2, d0 + 16, after, Horizon(z, after));
  }

  lemma P1PriorSound(z: Zone, c: Calendar, b: int)
  {
    var d0 := LDate(z, b);
    ScanMaxSpec(z, c, d0 - 16, d0 + 2, Floor(z, b) - 1, b + 1);
    var e :| d0 - 16 <= e <= d0 + 2 && Candidate(z, c, e, Floor(z, b) - 1, b + 1) == Prior(z, c, b);
    CandidateOcc(z, c, e, Floor(z, b) - 1, b + 1);
  }

  lemma P2PriorGreatest(z: Zone, c: Calendar, b: int, y: int)
  {
    P1PriorSound(z, c, b);
    if y >= Floor(z, b) {
      var d0 := LDate(z, b);
      PriorRange(z, b, y);
      OccCandidate(z, c, y, Floor(z, b) - 1, b + 1);
      ScanMaxSpec(z, c, d0 - 16, d0 + 2, Floor(z, b) - 1, b + 1);
    }
  }

  lemma P3PriorComplete(z: Zone, c: Calendar, b: int, y: int)
  {
    var d0 := LDate(z, b);
    PriorRange(z, b, y);
    OccCandidate(z, c, y, Floor(z, b) - 1, b + 1);
    ScanMaxSpec(z, c, d0 - 16, d0 + 2, Floor(z, b) - 1, b + 1);
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

  lemma N4NextProgress(z: Zone, c: Calendar, after: int)
  {
    var d0 := LDate(z, after);
    LocalBound(z, after);
    var w := c.weekdays[0];
    var k := WeekdayWithin(d0, w);
    var d := d0 + 1 + k;
    var K := d * DAY + c.minute * MINUTE;
    assert Resolve(z, d, c.minute) == Some(K - z.base);
    assert Candidate(z, c, d, after, Horizon(z, after)) == Some(K - z.base);
    ScanMinSpec(z, c, d0 - 2, d0 + 16, after, Horizon(z, after));
  }
}
