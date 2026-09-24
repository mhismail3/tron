# Phone reconnect tuning

- **Started:** 2026-09-24
- **Status:** Active
- **Last updated:** 2026-09-24, R-1 drafted
- **Goal:** The phone recovers from a stalled or briefly unreachable Gateway with the fewest spurious reconnects that still detect a dead path promptly, chosen from measured records rather than guesses.

## Goal and constraints

Carried over from the observability foundation plan's L-9b (see
[HISTORY](HISTORY.md)). What a user sees and when the app reconnects are
product behavior: no timing change ships without the user's decision on R-2.

- Do not change reconnect timing, retry policy or the connection contract in R-1.
- R-2 is a user decision between two options; only R-3 implements it.

## Context

Today (2026-09-24) the phone pings every 10 s and closes the socket when a pong
misses its 8 s deadline, so any Gateway stall over about 8 s becomes a
reconnect, and a dead socket is detected within about 18 s. Reconnect delay
starts at 2 s, grows by 1.7× to a 15 s cap, and each attempt can take up to the
15 s handshake deadline. Since the "No path to this Mac" label shipped, the
phone's `gateway.connection` records say whether each failed attempt opened a
transport, and the Mac's `gateway.event-loop-delay` records say when the
Gateway itself stalled. The options were scoped on 2026-09-24 against
`packages/gateway/docs/connection-resilience.md`.

| Option | Change | Trade-off |
| --- | --- | --- |
| B | Tear down only after three consecutive missed pongs, like the Gateway's own rule | Stalls of 6–36 s stop causing reconnects; dead-socket detection moves from about 18 s to about 64 s |
| D | Give up on a transport that has not opened after about 5 s, keeping the full deadline once it opens | A healed path reconnects about 10 s sooner per cycle; roughly doubles attempts during an outage |

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| R-1 | Ready | After at least five days on the current iPhone and Gateway builds, count reconnect episodes by cause from exported phone records and the Mac's logs: `ping_timeout` teardowns whose interval holds a `gateway.event-loop-delay` (stall) versus episodes whose attempts never opened a transport (path). Report counts, episode durations and time from path change to reconnect | none | |
| R-2 | Needs approval | The user chooses B, D or neither from R-1's counts | R-1 | |
| R-3 | Needs scoping | Implement the chosen option in the phone's connection policy and, for B, the shared connection-contract fixture, with before and after episode records | R-2 | |

## Handoff log

### R-0 · Done · 2026-09-24 · observability session

- Result: drafted from observability L-9b when that plan closed.
- Evidence: the L-9 scoping and L-9a implementation recorded in the observability foundation's history entry.
- Changes: this file; approved by the user on 2026-09-24.
- Tasks added: R-1 to R-3.
- For the next agent: R-1 needs real episodes, so it cannot start until the phone has run the current build for several days.
