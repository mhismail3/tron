// Laws of block security/public-host: which IP addresses a public display URL may name (the SSRF guard), and whether
// a rate limiter admits one attempt of a key and which attempt times it keeps.
// Addresses enter as their parts: an IPv4 address as its four octets, an IPv6 address as its first two hextets. Times
// enter as integer milliseconds.
// Shells: packages/gateway/src/display/display-contract.ts (normalizePublicDisplayURL: it parses the URL, refuses
// non-https, credentials, query, fragment and local names, finds the address family with isIP and splits the
// address) and packages/gateway/src/security/rate-limiter.ts (RateLimiter: it keeps each key's attempt times in an
// LRU map, asks the block on each attempt and prunes stale keys with it).
// The block refines this module. Edit a definition or a law only with a new independent review.
abstract module SecurityPublicHostLaws {
  // Octet: one byte of an IPv4 address.
  newtype Octet = x: int | 0 <= x < 0x100
  // Hextet: one 16-bit group of an IPv6 address.
  newtype Hextet = x: int | 0 <= x < 0x1_0000
  // Ms: a time in milliseconds since 1970, or a window length, below 2^52 (the year 144,683).
  newtype Ms = x: int | 0 <= x < 0x10_0000_0000_0000
  // Count: how many attempts a key may make in one window.
  newtype Count = x: int | 0 <= x < 0x1_0000_0000
  // List: a linked list, crossing to the shell as an array.
  datatype List<T> = Nil | Cons(head: T, tail: List<T>)
  // Admission: whether the attempt is admitted, and the attempt times the limiter keeps for the key.
  datatype Admission = Admission(admitted: bool, recent: List<Ms>)

  // Assumption A1: the shell asks about an IPv4 address only when isIP finds the WHATWG-normalized URL host to be
  // one (four decimal octets), and about an IPv6 address only when isIP finds the host, without brackets, to be one;
  // it passes the first two hextets of that normalized form (a group compressed by `::` is 0). Host names are not
  // resolved: a name that resolves to a private address is outside this guard.
  // Assumption A2: a key's attempt times are the ones this block returned for it, the shell calls with the
  // Gateway clock (non-decreasing within a run), a window of at least 1 ms and the limiter's maximum. The LRU map
  // may evict the least recently used key when it holds its maximum number of keys; an evicted key starts again
  // with no attempts, so the window law holds for each key while it is retained.

  // Elems: the items of a linked list, in order.
  ghost function Elems<T>(l: List<T>): seq<T> { if l.Nil? then [] else [l.head] + Elems(l.tail) }

  // ---------- the SSRF guard ----------

  // V: the 32-bit value of the IPv4 address a.b.c.d.
  ghost function V(a: int, b: int, c: int, d: int): int { a * 0x100_0000 + b * 0x1_0000 + c * 0x100 + d }

  // ListedV4: the IPv4 address value v lies in a refused range: 0.0.0.0/8 (this network), 10.0.0.0/8 (private),
  // 100.64.0.0/10 (shared address space), 127.0.0.0/8 (loopback), 169.254.0.0/16 (link local), 172.16.0.0/12
  // (private), 192.0.0.0/16 (wider than the IETF 192.0.0.0/24 and TEST-NET-1 192.0.2.0/24 it covers), 192.168.0.0/16
  // (private), 198.18.0.0/15 (benchmarking), 198.51.100.0/24 (TEST-NET-2), 203.0.113.0/24 (TEST-NET-3), and
  // 224.0.0.0 to 255.255.255.255 (multicast, reserved and broadcast).
  ghost predicate ListedV4(v: int) {
    V(0, 0, 0, 0) <= v <= V(0, 255, 255, 255)
    || V(10, 0, 0, 0) <= v <= V(10, 255, 255, 255)
    || V(100, 64, 0, 0) <= v <= V(100, 127, 255, 255)
    || V(127, 0, 0, 0) <= v <= V(127, 255, 255, 255)
    || V(169, 254, 0, 0) <= v <= V(169, 254, 255, 255)
    || V(172, 16, 0, 0) <= v <= V(172, 31, 255, 255)
    || V(192, 0, 0, 0) <= v <= V(192, 0, 255, 255)
    || V(192, 168, 0, 0) <= v <= V(192, 168, 255, 255)
    || V(198, 18, 0, 0) <= v <= V(198, 19, 255, 255)
    || V(198, 51, 100, 0) <= v <= V(198, 51, 100, 255)
    || V(203, 0, 113, 0) <= v <= V(203, 0, 113, 255)
    || V(224, 0, 0, 0) <= v <= V(255, 255, 255, 255)
  }

  // Whether the IPv4 address a.b.c.d is refused.
  predicate BlockedV4(a: Octet, b: Octet, c: Octet, d: Octet)

  // Whether the IPv6 address whose first two hextets are h0 and h1 is refused.
  predicate BlockedV6(h0: Hextet, h1: Hextet)

  // B4 ipv4-ranges: an IPv4 address is refused exactly when it lies in a listed range; every other address is
  // admitted.
  lemma B4Ranges(a: Octet, b: Octet, c: Octet, d: Octet)
    ensures BlockedV4(a, b, c, d) <==> ListedV4(V(a as int, b as int, c as int, d as int))

  // B6 ipv6-ranges: an IPv6 address is admitted exactly when it is global unicast (2000::/3: its first hextet from
  // 0x2000 to 0x3fff) and not documentation (2001:db8::/32). So :: (unspecified), ::1 (loopback), ULA fc00::/7,
  // link local fe80::/10, multicast ff00::/8 and every other address outside 2000::/3 are refused.
  lemma B6Ranges(h0: Hextet, h1: Hextet)
    ensures !BlockedV6(h0, h1) <==> 0x2000 <= h0 <= 0x3fff && !(h0 == 0x2001 && h1 == 0x0db8)

  // M6 ipv4-mapped: every IPv4-mapped IPv6 address (::ffff:0:0/96, first two hextets 0) is refused, whichever IPv4
  // address it maps, public or not; so are the IPv4-compatible ::/96 and NAT64 64:ff9b::/96 forms.
  lemma M6Mapped(h1: Hextet)
    ensures BlockedV6(0, h1) && BlockedV6(0x64, h1)

  // ---------- the rate limiter ----------

  // Fresh: an attempt at time t still counts at time now: it is later than now, or less than window ms old.
  ghost predicate Fresh(t: Ms, now: Ms, window: Ms) { t > now || (now as int) - (t as int) < window as int }

  // FreshOf: the attempt times of ts that still count at now, in order.
  ghost function FreshOf(ts: seq<Ms>, now: Ms, window: Ms): seq<Ms>
    decreases |ts|
  { if |ts| == 0 then [] else (if Fresh(ts[0], now, window) then [ts[0]] else []) + FreshOf(ts[1..], now, window) }

  // The attempt times of ts that still count at now.
  function Recent(ts: List<Ms>, now: Ms, window: Ms): List<Ms>

  // One attempt of a key at now, given the times the limiter kept for it.
  function Admit(ts: List<Ms>, now: Ms, window: Ms, maximum: Count): Admission

  // P1 prune: pruning keeps exactly the attempt times that still count, in order.
  lemma P1Prune(ts: List<Ms>, now: Ms, window: Ms)
    ensures Elems(Recent(ts, now, window)) == FreshOf(Elems(ts), now, window)

  // A1 admission: an attempt is admitted exactly when fewer than the maximum kept attempts still count; the limiter
  // then keeps those that still count, followed by this attempt when it was admitted.
  lemma A1Admission(ts: List<Ms>, now: Ms, window: Ms, maximum: Count)
    ensures var r, f := Admit(ts, now, window, maximum), FreshOf(Elems(ts), now, window);
      r.admitted == (|f| < maximum as int) && Elems(r.recent) == (if r.admitted then f + [now] else f)

  // S1 stale: a key whose every kept attempt is at least window ms old never blocks: its attempt is admitted (for a
  // maximum of at least one) and the limiter keeps only it.
  lemma S1Stale(ts: List<Ms>, now: Ms, window: Ms, maximum: Count)
    requires maximum >= 1 && forall i | 0 <= i < |Elems(ts)| :: !Fresh(Elems(ts)[i], now, window)
    ensures Admit(ts, now, window, maximum).admitted && Elems(Admit(ts, now, window, maximum).recent) == [now]

  // FromSeq: the linked list of a sequence.
  ghost function FromSeq<T>(s: seq<T>): List<T> decreases |s| { if |s| == 0 then Nil else Cons(s[0], FromSeq(s[1..])) }

  // Kept: what the limiter keeps for a key after its attempts at the times nows, in order, from nothing kept.
  ghost function Kept(nows: seq<Ms>, window: Ms, maximum: Count): seq<Ms>
    decreases |nows|
  {
    if |nows| == 0 then []
    else Elems(Admit(FromSeq(Kept(nows[..|nows| - 1], window, maximum)), nows[|nows| - 1], window, maximum).recent)
  }

  // Admitted: whether the last of the attempts at the times nows is admitted.
  ghost predicate Admitted(nows: seq<Ms>, window: Ms, maximum: Count)
    requires |nows| > 0
  { Admit(FromSeq(Kept(nows[..|nows| - 1], window, maximum)), nows[|nows| - 1], window, maximum).admitted }

  // AdmittedTimes: the times of the admitted attempts among nows, in order.
  ghost function AdmittedTimes(nows: seq<Ms>, window: Ms, maximum: Count): seq<Ms>
    decreases |nows|
  {
    if |nows| == 0 then []
    else AdmittedTimes(nows[..|nows| - 1], window, maximum) + (if Admitted(nows, window, maximum) then [nows[|nows| - 1]] else [])
  }

  // W1 window: in a key's attempts in time order, an attempt is admitted only when fewer than the maximum earlier
  // admitted attempts are less than window ms older than it; so no window of that length holds more than the maximum
  // admitted attempts of the key.
  lemma W1Window(nows: seq<Ms>, window: Ms, maximum: Count)
    requires |nows| > 0 && forall i, j | 0 <= i < j < |nows| :: nows[i] <= nows[j]
    ensures Admitted(nows, window, maximum)
      ==> |FreshOf(AdmittedTimes(nows[..|nows| - 1], window, maximum), nows[|nows| - 1], window)| < maximum as int
}
