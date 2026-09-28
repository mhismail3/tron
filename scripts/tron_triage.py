#!/usr/bin/env python3
"""Triage one incident's logs into episodes by cause.

`scripts/tron-triage` is the front door. The inputs are one or more phone
exports (the `tron-diagnostics*.jsonl` files an iOS Logs export produces) and
the Gateway log with its rotations (`<tron home>/logs`); both are read only and
never rewritten, and nothing is sent anywhere.

Phone and Gateway records are joined by the O-1 correlation key (a phone
`gatewayConnectionId` is a Gateway `connectionId`, and its `clientId`/
`attemptId` are the Gateway's `peerClientId`/`peerAttemptId`), falling back to a
time window for logs written before protocol 6. An episode uses one join: once
the key joins any record, a record naming another connection is not this
episode's evidence, and a connection the Gateway opened during the episode is
the recovery's rather than the one the outage lost — as is a socket the
handshake just before the loss opened, the previous stretch's own recovery
socket a flicker earlier, or one the phone's unchanged connection id says never
dropped. A published outage is reported as one
episode per scene phase, because the app parks recovery in the background and
resumes it on the foreground without publishing a new state. An attempt belongs
to the stretch it began in, and a Tailscale relay window explains an episode
only while it covers it.
Every episode is classified by the first matching rule in `classify`, in the
order the hardening plan fixes: `path`, `phone-background`, `phone-stall`,
`gateway-stall`, `gateway-capacity`, `unknown`. Each classification carries the
records it used, so an operator checks the attribution instead of trusting it.
"""

from __future__ import annotations

import argparse
import bisect
from dataclasses import dataclass, field as dataclass_field
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple

SCHEMA = "tron.triage-report.v1"
EXIT_OK = 0
EXIT_INVALID = 2

# `SLOW_RPC_WARNING_MS` in packages/gateway/src/transport/server.ts: at or above
# this a completed RPC is a warning, which is what "a slow span" means here.
SLOW_RPC_WARNING_MS = 1_000
# A transport attempt that writes no `durationMs` still has a deadline: the
# measured transport-open timeout is 15 s and the client's own bound is 20 s.
ATTEMPT_DEADLINE_MS = 20_000.0
# Two logs are the same event when they are this close and no correlation key
# joins them (protocol-5 exports). The measured reconnect cycle is under a
# minute; a wider window starts matching a neighbour's socket.
DEFAULT_JOIN_TOLERANCE_SECONDS = 60
# A reconnect's handshake takes tens of milliseconds: the measured reconnect
# sockets opened 36-117 ms before the label flicker that followed them, and the
# app's own `handshakeMs` was 45 ms. A socket opened this close to the published
# loss is the handshake that produced it; a socket that had served for seconds
# first is not, and on the incident export the slow spans that rested on such a
# socket were the Gateway-slow shape rule 4 exists for.
RECOVERY_HANDSHAKE_SECONDS = 0.5
# The reconnect publishes a burst of label flicks around one recovery: the phone
# publishes `reconnecting` and `connected` again milliseconds apart (the measured
# gaps are 4-9 ms). A socket the previous stretch's own recovery opened is this
# stretch's socket too when the two are that close.
FLICKER_BOUND_SECONDS = 1
# One connect can be recorded twice: the transport store's stage row and the
# app-level `operation.gatewayConnect` row are written for the same attempt (the
# incident export's 13 pairs end within 2 ms and agree on their duration to
# 2 ms). A real retry's own record lands seconds later.
ATTEMPT_DUPLICATE_END_SECONDS = 0.05
ATTEMPT_DUPLICATE_DURATION_MS = 50
# A relay window is the path being relayed, so it explains an outage only when
# the window is still the path at the episode's end or came back within the
# app's own recovery delay. The measured tail (05:01:37..05:01:42 against a
# window closing at 05:01:42.052) is under a second; a minute-long window that
# closed minutes earlier is not this episode's cause.
RELAY_WINDOW_SLACK_SECONDS = 5
# `gateway.jsonl` plus its seven numbered segments (logger.ts rotation).
GATEWAY_LOG_SEGMENTS = 8
# The Gateway's own records can land just outside an episode's bounds: a loss is
# admitted after the last readable frame, and a slow open answers after the
# phone gives up. Evidence is collected over this pad, and the report states it.
# `--tolerance-seconds` widens it, because the time-window join and the evidence
# read are the same read: a record the join would keep must be in the query.
EVIDENCE_PAD_SECONDS = 30
# An episode's `gatewayConnectionId` comes from the epoch that was connected
# just before it, which can be minutes earlier than the loss.
EPOCH_LOOKBACK_SECONDS = 300
# `log show` over a two-hour window measured about 20 s on a busy Mac
# (diagnose.ts). One capture is bounded by this, and the report says when it
# timed out.
LOG_SHOW_TIMEOUT_SECONDS = 90
# One capture covers a day at most: a longer `log show` reads history a
# multi-hour window does not need, and a tool run should stay interactive.
MAX_TAILSCALE_WINDOW_SECONDS = 24 * 3_600
TAILSCALE_LOG_TOOL = "/usr/bin/log"
TAILSCALE_EXTENSION_PROCESS = "io.tailscale.ipn.macsys.network-extension"
# An operator reads the evidence, so it stays short: a bounded number of lines,
# each truncated, and the counts in the summary say what was left out.
MAX_EVIDENCE_LINES = 12
MAX_EVIDENCE_TEXT = 240
# Phone-side attempt evidence: `gateway.attempt` is the O-4 record, and the
# incident store's `gateway.connection` stage rows are all a protocol-5 export
# has.
ATTEMPT_STAGES = ("transport-open", "hello-send", "hello-receive")
# `operation.gatewayConnect` is what a pre-O-4 app build wrote per connect: one
# finished attempt, with its end timestamp and `durationMs`, and no profile,
# connection or stage. It is context for an episode, not path evidence.
CONNECT_OPERATION_EVENT = "operation.gatewayConnect"
# A Gateway record that proves the path reached this Mac.
UPGRADE_EVENTS = ("http.upgrade", "connection.opened", "connection.admitted",
                  "connection.handshake", "connection.rejected")
# Overload and shedding records: the Gateway refused or dropped work by bound.
CAPACITY_EVENTS = ("connection.capacity", "http.request-capacity",
                   "http.connection-capacity", "connection.outbound-capacity",
                   "gateway.shed")
CAPACITY_UPGRADE_REASONS = ("request_capacity", "connection_capacity")
# Two episodes that describe one outage start at the same loss, so their windows
# overlap; a pair this close is one outage, not two. The join tolerance is
# deliberately not used here: it is wide enough to swallow a neighbour episode.
EPISODE_MERGE_PAD_SECONDS = 5
# Phone connection states that mean the app is not connected. `offline(_:)`
# serialises its reason, so a state is matched by name, not by equality. An
# outage that briefly reports `offline` is still one outage and must not be
# split in two by a window closer.
OUTAGE_STATES = ("reconnecting", "restarting", "offline")
# The app's own scene callbacks, its scene-phase transitions, and the retained
# client log's copy of the same transition. The last record inside an episode
# says which side of the foreground boundary the app was on there.
SCENE_BACKGROUND = "background"
LIFECYCLE_EVENT = "gateway.lifecycle"
LIFECYCLE_KIND_FIELD = "kind"
SCENE_KIND_PREFIX = "scene."
RECONNECT_CONNECTED_KIND = "reconnect.connected"

CAUSE_PATH = "path"
CAUSE_BACKGROUND = "phone-background"
CAUSE_PHONE_STALL = "phone-stall"
CAUSE_GATEWAY_STALL = "gateway-stall"
CAUSE_GATEWAY_CAPACITY = "gateway-capacity"
CAUSE_UNKNOWN = "unknown"
CAUSES = (CAUSE_PATH, CAUSE_BACKGROUND, CAUSE_PHONE_STALL, CAUSE_GATEWAY_STALL,
          CAUSE_GATEWAY_CAPACITY, CAUSE_UNKNOWN)

MESSAGE_FIELD = re.compile(r"([A-Za-z][A-Za-z0-9_]{0,63})=([^\s]+)")
ISO_TIMESTAMP = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?"
    r"(Z|[+-]\d{2}:?\d{2})?$"
)
# `log show --style compact` prints a bare local timestamp with no UTC offset;
# the default style appends one. Both are accepted, and a missing offset means
# the line is local time (see `parse_log_show_timestamp`).
LOG_SHOW_TIMESTAMP = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}[.,]\d+)(Z|[+-]\d{4})?")
# The two real Magicsock path forms: `new contact: peer=[fakeNodeKey] …
# via=derp` (relay) and `disco: node [fakeNodeKey] d:… now using
# 192.0.2.23:41641` (direct).
TAILSCALE_RELAY_LINE = re.compile(r"via=derp\b|\bderp\b|\brelay\b", re.IGNORECASE)
TAILSCALE_DIRECT_LINE = re.compile(r"now using\b|\bdirect\b", re.IGNORECASE)
TAILSCALE_OFFLINE_LINE = re.compile(r"offline|no route|unreachable", re.IGNORECASE)
# Magicsock names the peer as a short node key in brackets (`node
# [fakeNodeKey]`, `peer=[fakeNodeKey]`); the log's own `[pid:tid]` carries a
# colon and never matches.
TAILSCALE_PEER_KEY = re.compile(r"(?:peer|node)[=\s]*\[([A-Za-z0-9+/=]{4,})\]")


class TriageError(Exception):
    """An input the tool cannot read, or an output it refuses to write."""


def parse_timestamp(value: Any) -> Optional[datetime]:
    """One UTC instant from a Tron log timestamp, or None when it is not one."""
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        match = ISO_TIMESTAMP.match(text)
        if match is None:
            return None
        year, month, day, hour, minute, second, fraction, offset = match.groups()
        microsecond = int((fraction or "0").ljust(6, "0")[:6])
        parsed = datetime(int(year), int(month), int(day), int(hour), int(minute),
                          int(second), microsecond)
        if offset and offset != "Z":
            digits = offset[1:].replace(":", "")
            sign = 1 if offset[0] == "+" else -1
            parsed = parsed.replace(tzinfo=timezone(sign * timedelta(
                hours=int(digits[:2]), minutes=int(digits[2:4]))))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def format_timestamp(value: Optional[datetime]) -> Optional[str]:
    if value is None:
        return None
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def format_local(value: datetime) -> str:
    """`log show --start`/`--end` read local time, not UTC."""
    return value.astimezone().strftime("%Y-%m-%d %H:%M:%S")


def parse_log_show_timestamp(text: str, offset: Optional[str] = None) -> Optional[datetime]:
    """One UTC instant from a `log show` line's timestamp.

    `--style compact` prints local time with no offset, so an absent offset is
    read as local; the default style appends one and it is honoured.
    """
    normalized = text.replace(",", ".").replace(" ", "T")
    if offset:
        return parse_timestamp(normalized + offset)
    try:
        naive = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    # `astimezone` on a naive value presumes the system timezone.
    return naive.astimezone(timezone.utc)


def is_outage_state(state: str) -> bool:
    """Whether a published connection state is an outage.

    `offline(_:)` serialises its reason (`String(describing:)`), so the state
    matches on its name rather than on equality.
    """
    if not state:
        return False
    return any(state == name or state.startswith(f"{name}(") for name in OUTAGE_STATES)


def message_fields(message: str) -> Dict[str, str]:
    """`key=value` tokens a Tron record puts in its message.

    Diagnostics carry their detail in the message (`stageReached=hello-receive
    reason=transport`), while connection and RPC correlation rides in typed
    fields; reading one record needs both.
    """
    fields: Dict[str, str] = {}
    for name, raw in MESSAGE_FIELD.findall(message):
        fields.setdefault(name, raw.rstrip("),.;"))
    return fields


@dataclass
class Record:
    """One parsed log record, whatever stream it came from."""

    timestamp: Optional[datetime]
    level: str
    event: str
    source: str
    process: str
    message: str
    fields: Dict[str, str]
    path: str
    line: int

    def field(self, name: str, default: Optional[str] = None) -> Optional[str]:
        value = self.fields.get(name)
        if value is None or value in ("", "none", "unknown"):
            return default
        return value

    def number(self, name: str) -> Optional[float]:
        raw = self.field(name)
        if raw is None:
            return None
        try:
            return float(raw)
        except ValueError:
            return None


def record_from_object(value: Any, source_path: str, line: int) -> Optional[Record]:
    if not isinstance(value, dict):
        return None
    timestamp = parse_timestamp(value.get("timestamp"))
    if timestamp is None:
        return None
    message = value.get("message")
    message = message if isinstance(message, str) else ""
    fields: Dict[str, str] = {}
    for name, raw in value.items():
        if name in ("timestamp", "level", "message", "process", "event", "source"):
            continue
        if isinstance(raw, bool):
            fields[name] = "true" if raw else "false"
        elif isinstance(raw, (str, int, float)):
            fields[name] = str(raw)
    for name, raw in message_fields(message).items():
        fields.setdefault(name, raw)
    return Record(
        timestamp=timestamp,
        level=str(value.get("level") or ""),
        event=str(value.get("event") or "unknown"),
        source=str(value.get("source") or ""),
        process=str(value.get("process") or "gateway"),
        message=message,
        fields=fields,
        path=source_path,
        line=line,
    )


def scene_phase(record: Record) -> Optional[str]:
    """The scene phase a phone record moves to, or None when it is not one.

    The app writes its own callbacks (`app.backgrounded`/`app.foregrounded`)
    and scene transitions (`scene.*`); the retained client log repeats the
    transition as `gateway.lifecycle kind=scene.*`. All three shapes mean the
    same thing to an episode.
    """
    if record.event in ("app.backgrounded", "scene.background"):
        return SCENE_BACKGROUND
    if record.event in ("app.foregrounded", "scene.foreground"):
        return "foreground"
    if record.event == "scene.active":
        return "active"
    if record.event == "scene.resign-active":
        return "resign-active"
    if record.event == LIFECYCLE_EVENT:
        kind = record.field(LIFECYCLE_KIND_FIELD) or ""
        if kind.startswith(SCENE_KIND_PREFIX):
            return kind[len(SCENE_KIND_PREFIX):] or None
    return None


def gateway_id_of(record: Record) -> Optional[str]:
    """The Gateway `connectionId` a phone record names, or None.

    An O-1 record carries `gatewayConnectionId` directly (the O-4 attempt and
    the retained client's connection rows). The retained client log's
    `kind=reconnect.connected` instead names the phone's own `connectionID`;
    it only ever becomes a key join when it happens to equal the Gateway id,
    and a mismatch is dropped by `annotate_episode` because no Gateway record
    carries it.
    """
    value = record.field("gatewayConnectionId")
    if value:
        return value
    if record.event == LIFECYCLE_EVENT \
            and record.field(LIFECYCLE_KIND_FIELD) == RECONNECT_CONNECTED_KIND:
        return record.field("connectionID")
    return None


def read_jsonl(path: Path) -> Tuple[List[Record], int]:
    """Every parseable record in one JSONL file, with its unreadable line count."""
    records: List[Record] = []
    skipped = 0
    try:
        handle = path.open("r", encoding="utf-8", errors="replace")
    except OSError as error:
        raise TriageError(f"cannot read {path}: {error.strerror or error}") from error
    with handle:
        for number, raw in enumerate(handle, 1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                value = json.loads(raw)
            except ValueError:
                skipped += 1
                continue
            record = record_from_object(value, str(path), number)
            if record is None:
                skipped += 1
                continue
            records.append(record)
    return records, skipped


@dataclass
class PhoneExport:
    path: str
    records: List[Record]
    gateway_records: List[Record]
    unreadable_lines: int
    capture: Dict[str, Optional[str]]


def load_phone_export(path: Path) -> PhoneExport:
    """One export's phone rows, the Gateway rows it embeds, and its header."""
    parsed, skipped = read_jsonl(path)
    phone = [record for record in parsed if record.process != "gateway"]
    gateway = [record for record in parsed if record.process == "gateway"]
    capture: Dict[str, Optional[str]] = {}
    for record in parsed:
        if record.event != "diagnostics.exported":
            continue
        for name in ("copiedAt", "loadedAt", "representedFrom", "representedThrough", "appBuild"):
            if capture.get(name) is None:
                capture[name] = record.field(name)
    return PhoneExport(path=str(path), records=phone, gateway_records=gateway,
                       unreadable_lines=skipped, capture=capture)


def gateway_log_paths(directory: Path) -> List[Path]:
    """Oldest first: the logger shifts `gateway.jsonl` into `.1` … `.7`."""
    base = directory / "gateway.jsonl"
    paths = [base.with_name(f"{base.name}.{index}") for index in range(GATEWAY_LOG_SEGMENTS - 1, 0, -1)]
    paths.append(base)
    return [path for path in paths if path.is_file()]


@dataclass
class GatewayLogs:
    directory: str
    source: str
    records: List[Record]
    files: List[Dict[str, Any]]


def load_gateway_logs(directory: Path) -> GatewayLogs:
    records: List[Record] = []
    files: List[Dict[str, Any]] = []
    for path in gateway_log_paths(directory):
        segment, skipped = read_jsonl(path)
        files.append({"path": str(path), "records": len(segment), "unreadableLines": skipped})
        records.extend(segment)
    return GatewayLogs(directory=str(directory), source="gateway-logs", records=records, files=files)


@dataclass
class GatewayIndex:
    """The Gateway timeline, sliced by time and indexed by the O-1 key."""

    records: List[Record] = dataclass_field(default_factory=list)
    stamps: List[datetime] = dataclass_field(default_factory=list)
    by_connection: Dict[str, List[Record]] = dataclass_field(default_factory=dict)

    def __post_init__(self) -> None:
        self.records = sorted(
            (record for record in self.records if record.timestamp is not None),
            key=lambda record: record.timestamp,
        )
        self.stamps = [record.timestamp for record in self.records]
        for record in self.records:
            connection_id = record.field("connectionId")
            if connection_id:
                self.by_connection.setdefault(connection_id, []).append(record)

    def window(self, start: datetime, end: datetime) -> List[Record]:
        return self.records[bisect.bisect_left(self.stamps, start):
                            bisect.bisect_right(self.stamps, end)]

    def connection(self, connection_id: str) -> List[Record]:
        return self.by_connection.get(connection_id, [])


@dataclass
class Attempt:
    """One finished connection attempt, from either phone record shape.

    The record's timestamp is the attempt's *end* (the recorder writes it as the
    attempt finishes) and `duration_ms` is how long it ran, so the two bound the
    interval the attempt really occupied.
    """

    timestamp: datetime
    record: Record
    stage: str
    outcome: str
    reason: str
    gateway_connection_id: Optional[str]
    client_id: Optional[str]
    attempt_id: Optional[str]
    foreground: Optional[bool]
    profile: Optional[str]
    duration_ms: Optional[float] = None

    @property
    def failed(self) -> bool:
        return self.outcome == "failure"

    def start(self) -> datetime:
        """When this attempt began: its end timestamp less its own duration.

        An attempt belongs to the stretch it started in, not the one it ended
        in: a connect that began before a background blip and ended after the
        app returned to the foreground is the blip's attempt, and counting it
        against the silent stretch that followed contradicted the export.
        """
        length = self.duration_ms if self.duration_ms is not None else ATTEMPT_DEADLINE_MS
        return self.timestamp - timedelta(milliseconds=length)

    def span(self) -> Tuple[datetime, datetime]:
        """The interval this attempt occupied, its own deadline included."""
        return (self.start() - timedelta(seconds=2), self.timestamp + timedelta(seconds=2))

    def context_detail(self) -> str:
        """The fields this attempt's own record carries, for the context line.

        The two record shapes carry different fields: a pre-O-4
        `operation.gatewayConnect` names an outcome and a duration and nothing
        else, so printing `stageReached=unknown reason=none foreground=None`
        for it invented a stage, a reason and a scene the export never wrote.
        """
        fields = []
        if self.stage:
            fields.append(f"stageReached={self.stage}")
        if self.reason:
            fields.append(f"reason={self.reason}")
        if self.outcome:
            fields.append(f"outcome={self.outcome}")
        if self.duration_ms is not None:
            fields.append(f"durationMs={int(self.duration_ms)}")
        if self.foreground is not None:
            fields.append(f"foreground={self.foreground}")
        return " ".join(fields) or "attempt finished with no field recorded"


def attempt_belongs(episode: "Episode", attempt: Attempt) -> bool:
    """Whether this attempt is the episode's own, not another profile's.

    The settings dashboard runs a second profile beside the main one, and its
    transport-open timeouts land in the same window. An episode that names its
    profile (the O-4 `connection.episode` record) or its client only counts
    attempts that agree with it, so the pool's dead path never becomes the main
    episode's path fault. An older record carries neither, so the attempt is
    kept rather than silently dropped.
    """
    profile = episode.profile
    client = episode.client_id
    if profile is not None and attempt.profile is not None:
        return attempt.profile == profile
    if client is not None and attempt.client_id is not None:
        return attempt.client_id == client
    return True


def phone_attempts(records: Iterable[Record]) -> List[Attempt]:
    """One entry per finished attempt, preferring the O-4 record.

    `gateway.attempt` is written once per attempt, so when an export carries it
    it is the attempt list and the transport store's `gateway.connection` stage
    rows are not counted again. Older exports carry only the stage rows; those
    deduplicate by `(clientID, sequence)`. Neither client shape identifies an
    attempt by its `attemptId`: that is the reconnect loop's id (`loopID`),
    shared by every retry in the loop, so a key containing it merges real
    retries.
    """
    attempt_records = [record for record in records
                       if record.event == "gateway.attempt" and record.timestamp is not None]
    if not attempt_records:
        attempt_records = [record for record in records
                           if record.event == "gateway.connection"
                           and record.timestamp is not None
                           and record.field("stage") in ATTEMPT_STAGES]
    attempts: List[Attempt] = []
    seen_stages: Set[Tuple[str, str]] = set()
    for record in attempt_records:
        if record.event == "gateway.attempt":
            attempts.append(Attempt(
                timestamp=record.timestamp, record=record,
                stage=record.field("stageReached", "") or "",
                outcome=record.field("outcome", "") or "",
                reason=record.field("reason", "") or "",
                gateway_connection_id=record.field("gatewayConnectionId"),
                client_id=record.field("clientId"),
                attempt_id=record.field("attemptId"),
                foreground=(record.field("foreground") or "").lower() == "true",
                profile=record.field("profile") or record.field("profileID"),
                duration_ms=record.number("durationMs"),
            ))
            continue
        key = (record.field("clientID", "") or "", record.field("sequence", "") or "")
        if key in seen_stages:
            continue
        seen_stages.add(key)
        attempts.append(Attempt(
            timestamp=record.timestamp, record=record,
            stage=record.field("stage", "") or "",
            outcome=record.field("outcome", "") or "",
            reason=record.field("reason", "") or "",
            gateway_connection_id=record.field("gatewayConnectionId"),
            client_id=record.field("clientID"),
            attempt_id=record.field("attemptID"),
            foreground=None,
            profile=record.field("profileID") or record.field("profile"),
            duration_ms=record.number("durationMs"),
        ))
    attempts.sort(key=lambda attempt: attempt.timestamp)
    return attempts


@dataclass
class Episode:
    """One outage, from a `connection.episode` record or derived from evidence.

    A published outage is reported as one episode per scene phase: the stretches
    the app spent in the foreground are what the path, label and gap rules
    judge, and the stretches it spent in the background are parked by design.
    `outage_boundary` names the state change that published the outage a stretch
    belongs to, so a stretch that starts after a background blip is still known
    to be part of that same published outage.
    """

    start: datetime
    end: datetime
    attempts: int = 0
    ended_by: Optional[str] = None
    profile: Optional[str] = None
    client_id: Optional[str] = None
    derived: bool = False
    declared_causes: List[str] = dataclass_field(default_factory=list)
    boundary: Optional[Record] = None
    phase: Optional[str] = None
    outage_boundary: Optional[Record] = None
    scene_record: Optional[Record] = None
    phone_records: List[Record] = dataclass_field(default_factory=list)
    attempt_records: List[Attempt] = dataclass_field(default_factory=list)
    gateway_ids: Set[str] = dataclass_field(default_factory=set)
    phone_keys: Set[Tuple[str, str]] = dataclass_field(default_factory=set)
    join: str = "none"
    cause: str = CAUSE_UNKNOWN
    evidence: List[Dict[str, Any]] = dataclass_field(default_factory=list)
    previous_stretch: Optional[Tuple[datetime, datetime]] = None

    @property
    def duration_seconds(self) -> float:
        return max(0.0, (self.end - self.start).total_seconds())


@dataclass
class OutageSegment:
    """One stretch of a published outage, in one scene phase.

    A scene transition splits the outage rather than closing it: the app parks
    recovery in the background and resumes it on the foreground, and in between
    it publishes no new state. Closing the window there dropped the foreground
    stretch after a short blip from the report entirely, and left the stretch
    before it reading as a background episode even though the app was in the
    foreground for all but its last instant.
    """

    opener: Record
    start: datetime
    end: datetime
    phase: str
    closer: Optional[Record] = None
    scene: Optional[Record] = None

    @property
    def ended_by(self) -> str:
        closer_phase = scene_phase(self.closer) if self.closer is not None else None
        return closer_phase or "connected"


def overlaps(start: datetime, end: datetime, other_start: datetime, other_end: datetime,
             tolerance: timedelta = timedelta(0)) -> bool:
    return start <= other_end + tolerance and other_start <= end + tolerance


def declared_episodes(records: Iterable[Record]) -> List[Episode]:
    episodes: List[Episode] = []
    for record in records:
        if record.event != "connection.episode" or record.timestamp is None:
            continue
        start = parse_timestamp(record.field("startedAt")) or record.timestamp
        end = parse_timestamp(record.field("endedAt")) or record.timestamp
        if end < start:
            end = start
        causes = [value.strip() for value in (record.field("causes") or "none").split(",")]
        episodes.append(Episode(
            start=start, end=end,
            attempts=int(record.number("attempts") or 0),
            ended_by=record.field("endedBy") or record.field("outcome"),
            profile=record.field("profile") or record.field("profileID"),
            client_id=record.field("clientID") or record.field("clientId"),
            declared_causes=[value for value in causes if value and value != "none"],
            boundary=record,
        ))
    return episodes


def outage_segments(records: Sequence[Record]) -> List[OutageSegment]:
    """The published outage split into foreground and background stretches.

    This is the evidence a protocol-5 export has for a loss, and it is how an
    episode with no attempt of its own (a silent recovery gap, or a label over a
    socket that never dropped) is found at all. A window opens on a transition
    into an outage state and the outage runs until the first of: a transition
    out of one, or the end of a `connection.episode` record. A scene transition
    does not end it: it splits it, because the iPhone parks recovery in the
    background and does not publish a new state when it returns to the
    foreground, so the outage continues across the transition and only its
    phase changes.
    """
    segments: List[OutageSegment] = []
    opener: Optional[Record] = None
    start: Optional[datetime] = None
    phase = "foreground"
    opened_scene: Optional[Record] = None
    background = False
    last: Optional[datetime] = None

    def close(at: datetime, closer: Optional[Record], keep_opener: bool = False) -> None:
        nonlocal start, opener, opened_scene
        # A stretch that contains no time is not an outage: the export can end on
        # the scene record that left the app in the background, and a state
        # change can publish a loss and a recovery in the same millisecond.
        if start is not None and at > start:
            segments.append(OutageSegment(opener=opener, start=start, end=at, phase=phase,
                                          closer=closer, scene=opened_scene))
        start = None
        opened_scene = None
        if not keep_opener:
            opener = None

    def split(at: datetime, next_phase: str, scene_record: Record) -> None:
        """End the current stretch at `at` and start the next one in its phase."""
        nonlocal start, phase, opened_scene
        if start is None or at <= start:
            return
        close(at, scene_record, keep_opener=True)
        start = at
        phase = next_phase
        opened_scene = scene_record

    for record in records:
        if record.timestamp is None:
            continue
        last = record.timestamp if last is None else max(last, record.timestamp)
        record_phase = scene_phase(record)
        if record.event == "connection.state-changed":
            state = record.field("new") or record.field("outcome") or ""
            if is_outage_state(state):
                if start is None:
                    opener = record
                    start = record.timestamp
                    phase = SCENE_BACKGROUND if background else "foreground"
            else:
                close(record.timestamp, record)
        elif record_phase == SCENE_BACKGROUND:
            background = True
            if phase == "foreground":
                split(record.timestamp, SCENE_BACKGROUND, record)
        elif record_phase == "foreground":
            background = False
            if phase == SCENE_BACKGROUND:
                split(record.timestamp, "foreground", record)
        elif record.event == "connection.episode":
            close(record.timestamp, record)
    if start is not None and last is not None:
        close(last, None)
    return segments


def derived_episodes(records: Sequence[Record], attempts: Sequence[Attempt],
                     covered: Sequence[Episode]) -> List[Episode]:
    """Episodes no `connection.episode` record describes.

    Two shapes are derived: an outage-label stretch (which can carry no attempt
    at all, the measured silent recovery gap) and a cluster of consecutive
    failed attempts that ends at the attempt which connected. The label stretch
    wins when both describe one outage, because it starts at the loss the app
    published rather than at the first attempt's start.
    """
    derived: List[Episode] = []
    merge_pad = timedelta(seconds=EPISODE_MERGE_PAD_SECONDS)

    def is_covered(start: datetime, end: datetime) -> bool:
        # A declared episode's own boundary can trail the loss by a few seconds,
        # so the pad absorbs it. A second label stretch is a second outage by
        # construction — the first was closed by a state change or a scene
        # transition — and only a real overlap merges one: the two stretches a
        # scene transition splits apart touch at the boundary, and counting that
        # as an overlap dropped every background stretch.
        if any(overlaps(start, end, episode.start, episode.end, merge_pad)
               for episode in covered):
            return True
        return any(start < episode.end and episode.start < end for episode in derived)

    for segment in outage_segments(records):
        if is_covered(segment.start, segment.end):
            continue
        # Attempts are attached by `attempt_owner` once every episode exists, so
        # an attempt that began in a stretch's own blip is not counted against
        # the silent stretch after it.
        derived.append(Episode(
            start=segment.start, end=segment.end,
            derived=True, ended_by=segment.ended_by, phase=segment.phase,
            boundary=segment.opener, outage_boundary=segment.opener,
            scene_record=segment.scene,
        ))

    cluster_start: Optional[datetime] = None
    cluster_attempts: List[Attempt] = []
    for attempt in attempts:
        if attempt.failed:
            cluster_start = attempt.timestamp if cluster_start is None else cluster_start
            cluster_attempts.append(attempt)
            continue
        if cluster_start is None:
            continue
        if not is_covered(cluster_start, attempt.timestamp):
            derived.append(Episode(
                start=cluster_start, end=attempt.timestamp,
                ended_by="connected", derived=True, attempt_records=list(cluster_attempts),
                boundary=cluster_attempts[0].record,
            ))
        cluster_start = None
        cluster_attempts = []
    return derived


def app_connect_attempts(records: Iterable[Record]) -> List[Attempt]:
    """`operation.gatewayConnect` rows: the attempt a pre-O-4 export recorded.

    Each row is one finished connect with its end timestamp and `durationMs`,
    so it bounds the interval the attempt occupied like the other shapes. It
    names no profile, connection, stage or foreground flag: the settings
    dashboard runs a second profile whose timeouts land in the same window while
    the main connection is up, so this shape is context for an episode and not
    this episode's own path evidence, and it never opens a derived outage.
    """
    attempts: List[Attempt] = []
    for record in records:
        if record.event != CONNECT_OPERATION_EVENT or record.timestamp is None:
            continue
        attempts.append(Attempt(
            timestamp=record.timestamp, record=record,
            stage="", outcome=record.field("outcome", "") or "", reason="",
            gateway_connection_id=None, client_id=None, attempt_id=None,
            foreground=None, profile=None, duration_ms=record.number("durationMs"),
        ))
    attempts.sort(key=lambda attempt: attempt.timestamp)
    return attempts


def all_attempts(records: Iterable[Record]) -> List[Attempt]:
    """Every finished attempt an export recorded, once, for an episode's count.

    A build that wrote both the transport store's stage row and the app-level
    `operation.gatewayConnect` row recorded one connect twice: the incident
    export's 13 pairs end within 2 ms of each other with durations agreeing to
    2 ms. An operation row that close to a stage row with a matching duration is
    that attempt's other name, not a second attempt; the next retry's own record
    lands seconds later, so nothing real is merged.
    """
    stages = phone_attempts(records)
    operations = [operation for operation in app_connect_attempts(records)
                  if not duplicate_attempt(operation, stages)]
    attempts = stages + operations
    attempts.sort(key=lambda attempt: attempt.timestamp)
    return attempts


def duplicate_attempt(operation: Attempt, stages: Sequence[Attempt]) -> bool:
    """Whether a stage row already records this `operation.gatewayConnect`.

    The two shapes share no key, so they are matched by their end and their
    duration together: an export that writes both puts them milliseconds apart,
    and a placeholder duration (`none`) is not evidence of a different attempt.
    """
    for stage in stages:
        if abs((operation.timestamp - stage.timestamp).total_seconds()) \
                > ATTEMPT_DUPLICATE_END_SECONDS:
            continue
        if operation.duration_ms is None or stage.duration_ms is None:
            return True
        if abs(operation.duration_ms - stage.duration_ms) <= ATTEMPT_DUPLICATE_DURATION_MS:
            return True
    return False


def attempt_owner(attempt: Attempt, episodes: Sequence[Episode]) -> Optional[Episode]:
    """The stretch this attempt belongs to, or None.

    The stretch it began in owns it: the export's 03:24:45.020 record began
    6.2 s earlier, inside the blip before the silent stretch, so counting it
    against the silent stretch hid that stretch's gap statement and contradicted
    the measured no-attempt gap. Only an attempt that began before the report's
    first stretch — the failing attempt a declared `connection.episode`'s own
    loss was published for — falls back to the stretch it ended in, because no
    stretch contains its start at all.
    """
    issued = attempt.start()
    for episode in episodes:
        if episode.start <= issued <= episode.end:
            return episode
    # A start that falls in no stretch at all falls back to the stretch the
    # attempt ended in. On the incident export eight attempts use this: the first
    # episode's own failing connect, and seven connects that began in connected
    # time just before a published loss.
    for episode in episodes:
        if episode.start <= attempt.timestamp <= episode.end:
            return episode
    return None


def annotate_episode(episode: Episode, phone: Sequence[Record], attempts: Sequence[Attempt],
                     all_attempts_list: Sequence[Attempt], gateway: GatewayIndex,
                     episodes: Sequence[Episode]) -> None:
    """Attach the phone records, attempts and O-1 keys one episode owns."""
    episode.phone_records = [
        record for record in phone
        if record.timestamp is not None
        and episode.start - timedelta(seconds=EPOCH_LOOKBACK_SECONDS) <= record.timestamp
        <= episode.end + timedelta(seconds=EVIDENCE_PAD_SECONDS)
    ]
    if not episode.attempt_records:
        # The stage-recorded attempts and the app-level `operation.gatewayConnect`
        # rows are attached by the stretch each began in, so an episode with no
        # attempt of its own really had none (the measured silent gap) and an
        # episode whose attempt record sits in an older-export shape still has
        # it. `all_attempts_list` carries both shapes.
        episode.attempt_records = [
            attempt for attempt in all_attempts_list
            if attempt_owner(attempt, episodes) is episode
        ]
    if episode.attempts == 0 and episode.attempt_records:
        episode.attempts = len(episode.attempt_records)
    for record in episode.phone_records:
        # Every phone record that names the Gateway connection, or the pair the
        # Gateway stamps as peerClientId/peerAttemptId, is a join key — but only
        # up to the episode's end: the record at the end is the reconnect that
        # ended it. A connection the Gateway opened inside the episode is the
        # recovery's too, so it is not this outage's key (see
        # `opened_within`).
        if record.timestamp > episode.end:
            continue
        gateway_id = gateway_id_of(record)
        if gateway_id:
            episode.gateway_ids.add(gateway_id)
        client_id = record.field("clientId") or record.field("clientID")
        attempt_id = record.field("attemptId") or record.field("attemptID")
        if client_id and attempt_id:
            episode.phone_keys.add((client_id, attempt_id))
    for gateway_id in list(episode.gateway_ids):
        if not gateway.connection(gateway_id) or opened_within(episode, gateway, gateway_id):
            episode.gateway_ids.discard(gateway_id)


def link_flicker_stretches(episodes: Sequence[Episode]) -> None:
    """Point each episode at the stretch that ended immediately before it.

    The reconnect publishes a burst of sub-second label flicks around one
    recovery, and the socket it opened for the first flicker carries the later
    ones' refresh work. The stretch before this one is what tells whether the
    two are flicks of one recovery, together with `FLICKER_BOUND_SECONDS`; no
    wider window is kept, so an episode never inherits a socket from an earlier
    outage.
    """
    for index, episode in enumerate(episodes):
        previous = episodes[index - 1] if index else None
        episode.previous_stretch = None if previous is None else (previous.start, previous.end)


def build_episodes(phone: Sequence[Record], gateway: GatewayIndex,
                   tolerance: timedelta) -> List[Episode]:
    attempts = phone_attempts(phone)
    every_attempt = all_attempts(phone)
    episodes = declared_episodes(phone)
    episodes.extend(derived_episodes(phone, attempts, episodes))
    episodes.sort(key=lambda episode: episode.start)
    link_flicker_stretches(episodes)
    for episode in episodes:
        annotate_episode(episode, phone, attempts, every_attempt, gateway, episodes)
    return episodes


def gateway_join(episode: Episode, record: Record, tolerance: timedelta) -> Optional[str]:
    """`key` when the O-1 key joins the two records, `window` when only time does."""
    connection_id = record.field("connectionId")
    if connection_id and connection_id in episode.gateway_ids:
        return "key"
    client_id = record.field("peerClientId")
    attempt_id = record.field("peerAttemptId")
    if client_id and (client_id, attempt_id) in episode.phone_keys:
        return "key"
    if record.timestamp is None:
        return None
    margin = evidence_margin(tolerance)
    if episode.start - margin <= record.timestamp <= episode.end + margin:
        return "window"
    return None


def evidence_margin(tolerance: timedelta) -> timedelta:
    """How far outside an episode its evidence and its time-window join reach.

    The pad is the model's own bound (a loss is admitted after the last readable
    frame, a slow open answers after the phone gave up); `--tolerance-seconds`
    is the operator's, and a tolerance narrower than the pad cannot shrink the
    pad below what the records need.
    """
    return max(tolerance, timedelta(seconds=EVIDENCE_PAD_SECONDS))


def evidence_entry(source: str, record: Record, role: str, detail: str = "") -> Dict[str, Any]:
    return {
        "source": source,
        "role": role,
        "timestamp": format_timestamp(record.timestamp),
        "event": record.event,
        "detail": (detail or record.message or "")[:MAX_EVIDENCE_TEXT],
    }


@dataclass
class TailscaleCapture:
    captured: bool
    reason: str
    peer: Optional[str] = None
    window: Optional[Tuple[datetime, datetime]] = None
    lines: List[Tuple[datetime, str]] = dataclass_field(default_factory=list)

    def relay_windows(self) -> List[Tuple[datetime, datetime, str]]:
        """Relay or offline stretches between path-change lines.

        The extension log is the only Tailscale evidence a pre-O-2 Gateway log
        leaves behind, and its path lines are message text, so this read is
        deliberately conservative: a relay line opens a window and a direct
        line closes it. The relay test runs first because a relay endpoint can
        also print `now using DERP(sea)`. It is evidence, never proof.
        """
        windows: List[Tuple[datetime, datetime, str]] = []
        opened_at: Optional[datetime] = None
        kind = ""
        for timestamp, text in self.lines:
            if TAILSCALE_OFFLINE_LINE.search(text):
                if opened_at is None:
                    opened_at, kind = timestamp, "offline"
            elif TAILSCALE_RELAY_LINE.search(text):
                if opened_at is None:
                    opened_at, kind = timestamp, "relay"
            elif TAILSCALE_DIRECT_LINE.search(text):
                if opened_at is not None:
                    windows.append((opened_at, timestamp, kind))
                    opened_at, kind = None, ""
        if opened_at is not None and self.lines:
            windows.append((opened_at, self.lines[-1][0], kind))
        return windows


def tailscale_peer_key(line: str) -> Optional[str]:
    """The peer node key a Magicsock line names, without its brackets."""
    match = TAILSCALE_PEER_KEY.search(line)
    return match.group(1) if match is not None else None


def capture_tailscale_window(start: datetime, end: datetime,
                             peer: Optional[str] = None) -> TailscaleCapture:
    """Read the Tailscale network-extension log for one UTC range.

    `peer` filters to one node key: the extension serves every tailnet peer, so
    without it another peer's relay stretch could be read as the phone's.
    """
    if (end - start).total_seconds() <= 0:
        return TailscaleCapture(captured=False, reason="export range is empty")
    if (end - start).total_seconds() > MAX_TAILSCALE_WINDOW_SECONDS:
        end = start + timedelta(seconds=MAX_TAILSCALE_WINDOW_SECONDS)
    arguments = [TAILSCALE_LOG_TOOL, "show", "--style", "compact",
                 "--start", format_local(start), "--end", format_local(end),
                 "--predicate", f'process == "{TAILSCALE_EXTENSION_PROCESS}"']
    try:
        completed = subprocess.run(arguments, capture_output=True, text=True,
                                   timeout=LOG_SHOW_TIMEOUT_SECONDS)
    except (OSError, subprocess.SubprocessError) as error:
        return TailscaleCapture(captured=False, reason=f"log show failed: {error}", peer=peer)
    if completed.returncode != 0:
        return TailscaleCapture(captured=False, reason=f"log show exited {completed.returncode}",
                                peer=peer)
    lines: List[Tuple[datetime, str]] = []
    for raw in (completed.stdout or "").splitlines():
        match = LOG_SHOW_TIMESTAMP.match(raw.strip())
        if match is None:
            continue
        timestamp = parse_log_show_timestamp(match.group(1), match.group(2))
        if timestamp is None:
            continue
        if peer is not None and tailscale_peer_key(raw) != peer:
            continue
        if TAILSCALE_RELAY_LINE.search(raw) or TAILSCALE_DIRECT_LINE.search(raw) \
                or TAILSCALE_OFFLINE_LINE.search(raw):
            lines.append((timestamp, raw.strip()))
    return TailscaleCapture(captured=True, reason="captured", peer=peer,
                            window=(start, end), lines=lines)


def epoch_connection_id(episode: Episode, before: datetime) -> Optional[str]:
    """The Gateway connection the phone's epoch was using just before `before`."""
    latest: Optional[str] = None
    for record in episode.phone_records:
        if record.timestamp is None or record.timestamp > before:
            continue
        value = record.field("gatewayConnectionId")
        if value:
            latest = value
    return latest


def socket_answered(history: Sequence[Record], transition: datetime,
                    episode_end: datetime) -> Optional[Record]:
    """A successful RPC this socket issued at/after `transition` and finished inside the episode.

    The issue instant is `completion - durationMs`, so a request that was
    already in flight when the label was published proves nothing about whether
    the socket was live then: the whole span must sit inside
    `[transition, episode_end]`, and the socket must still be open at
    completion.
    """
    closed_at = [record.timestamp for record in history
                 if record.event == "connection.closed" and record.timestamp is not None]

    def open_at(moment: datetime) -> bool:
        return not any(closed <= moment for closed in closed_at)

    for record in history:
        if record.event != "rpc.completed" or record.timestamp is None:
            continue
        if record.field("outcome", "success") != "success":
            continue
        duration = record.number("durationMs")
        if duration is None:
            continue
        if record.timestamp - timedelta(milliseconds=duration) < transition:
            continue
        if record.timestamp > episode_end:
            continue
        if open_at(record.timestamp):
            return record
    return None


def window_connection_ids(gateway: GatewayIndex, start: datetime, end: datetime) -> List[str]:
    """The Gateway connections any record in this window names, once each."""
    ids: List[str] = []
    seen: Set[str] = set()
    for record in gateway.window(start, end):
        value = record.field("connectionId")
        if value and value not in seen:
            seen.add(value)
            ids.append(value)
    return ids


def label_over_live_socket(episode: Episode,
                           gateway: GatewayIndex) -> Optional[Tuple[Record, str, Record]]:
    """A `reconnecting` label while the Gateway socket answered requests.

    The 2026-09-27 incident's second cause: the published state stayed
    `reconnecting` from 04:05:25 to 04:11:46 while chats opened on the same
    socket. The Gateway proves the socket was live by completing a request on
    the connection that phone epoch named while that connection was still open,
    so a socket that had already closed is a real loss, not a wrong label.
    Returns the transition, the connection that answered and the request, so
    the evidence names the socket instead of leaving it `unknown`.

    An export written before O-1 carries no `gatewayConnectionId`, so there the
    fallback is any connection that was already open when the label was
    published and still answered inside the episode; a mismatched connection id
    (the retained client's own numeric `connectionID`) is discarded before this
    runs. The label that counts for a stretch of an outage is the transition
    that published the outage (`outage_boundary`): a stretch that starts after a
    background blip has no transition of its own, and the socket it must be
    judged against was opened before the blip.
    """
    transition = outage_transition(episode)
    if transition is None or transition.timestamp is None:
        return None
    search_start = transition.timestamp - timedelta(seconds=EPOCH_LOOKBACK_SECONDS)
    connection_id = epoch_connection_id(episode, transition.timestamp)
    candidates = ([connection_id] if connection_id is not None
                  else window_connection_ids(gateway, search_start, episode.end))
    for candidate in candidates:
        history = gateway.connection(candidate)
        if not history:
            continue
        opened = any(item.event == "connection.opened" and item.timestamp is not None
                     and item.timestamp <= transition.timestamp for item in history)
        if not opened:
            continue
        answered = socket_answered(history, transition.timestamp, episode.end)
        if answered is not None:
            return (transition, candidate, answered)
    return None


def outage_transition(episode: Episode) -> Optional[Record]:
    """The transition whose published outage this episode is a stretch of.

    A stretch of a label-derived outage carries it as `outage_boundary`. A
    declared or attempt-cluster episode has no published outage of its own, so
    the only transition that can be its wrong label is one it contains: an
    earlier window's transition is not this episode's.
    """
    if episode.outage_boundary is not None:
        return episode.outage_boundary
    for record in episode.phone_records:
        if record.event != "connection.state-changed" or record.timestamp is None:
            continue
        if record.timestamp < episode.start:
            continue
        if is_outage_state(record.field("new") or record.field("outcome") or ""):
            return record
    return None


def attempt_reached_mac(attempt: Attempt, window: Sequence[Record]) -> bool:
    """Did this attempt's own connection reach the Gateway?

    A transport-open failure whose own attempt never appears on a Gateway accept
    or upgrade means the path never reached this Mac. The check runs over the
    attempt's own span and needs the records to agree on the peer key: a
    Gateway record whose peer key contradicts the attempt is skipped, and a
    record with no peer key at all cannot confirm an attempt that has one, so a
    live main connection is never read as this attempt's arrival. Arrival must
    also precede the attempt's own end, because the next retry's accept lands
    1.6–2.4 s after a timeout and falls inside any pad past it. When neither
    side carries the key (a protocol-5 phone and a protocol-5 Gateway), the
    span's own accept is the best evidence there is.
    """
    for record in window:
        if record.event not in UPGRADE_EVENTS or record.timestamp is None:
            continue
        if record.timestamp > attempt.timestamp:
            continue
        peer_client = record.field("peerClientId")
        peer_attempt = record.field("peerAttemptId")
        if peer_client is None and peer_attempt is None:
            if attempt.client_id is None and attempt.attempt_id is None:
                return True
            continue
        if attempt.client_id is not None and peer_client is not None \
                and peer_client != attempt.client_id:
            continue
        if attempt.attempt_id is not None and peer_attempt is not None \
                and peer_attempt != attempt.attempt_id:
            continue
        return True
    return False


def background_at_end(episode: Episode) -> Optional[Record]:
    """The scene record that leaves the app in the background at the episode's end."""
    scenes = [(record, scene_phase(record)) for record in episode.phone_records
              if record.timestamp is not None
              and episode.start <= record.timestamp <= episode.end]
    scenes = [(record, phase) for record, phase in scenes if phase is not None]
    if not scenes:
        return None
    record, phase = max(scenes, key=lambda item: item[0].timestamp)
    return record if phase == SCENE_BACKGROUND else None


def background_parked(episode: Episode) -> Optional[Tuple[str, Optional[Record]]]:
    """Why this episode was parked in the background, or None.

    A backgrounded phone parks recovery by design, so its attempts time out at
    transport-open without the Mac ever seeing them. That is not a path fault:
    the path clause of the first rule is skipped for a parked episode, which is
    reported as `phone-background` instead. A stretch of a published outage
    knows its own phase, so a foreground stretch is never parked by the scene
    record that closes it: that record is where the app left the foreground, not
    where the outage was spent.
    """
    if episode.phase == "foreground":
        return None
    if episode.phase == SCENE_BACKGROUND:
        return ("the app was in the background for this stretch of the outage",
                episode.scene_record or episode.boundary)
    scene = background_at_end(episode)
    if scene is not None:
        return ("the app was in the background at the episode's end", scene)
    if episode.ended_by == "background":
        return ("the episode ended at a background transition", episode.boundary)
    if episode.attempt_records and all(attempt.foreground is False
                                       for attempt in episode.attempt_records):
        return ("every attempt was made in the background", episode.attempt_records[0].record)
    return None


def opened_within(episode: Episode, gateway: GatewayIndex,
                  connection_id: Optional[str]) -> bool:
    """Whether the Gateway opened this connection inside the episode.

    Such a socket belongs to the recovery: the work it carries is the
    reconnect's own refresh, and it is not the connection the outage lost, so it
    is neither this episode's join key nor its cause. A connection with no
    readable `connection.opened` record (a rotated log) is not excluded on a
    guess.
    """
    if not connection_id:
        return False
    return any(record.event == "connection.opened" and record.timestamp is not None
               and episode.start <= record.timestamp <= episode.end
               for record in gateway.connection(connection_id))


def recovery_connection(episode: Episode, gateway: GatewayIndex,
                        connection_id: Optional[str]) -> bool:
    """Whether this Gateway connection is the recovery's, not the outage's.

    Rule 4 asks whether the connection that stalled is the one whose loss the
    episode published, and four shapes name the reconnect's own socket instead:

    - the Gateway opened it inside the episode, so the loss predates it;
    - it opened within `RECOVERY_HANDSHAKE_SECONDS` of the published loss: the
      handshake that just completed produced it, and the label flicker the
      reconnect publishes re-uses that socket for its own refresh;
    - the previous stretch's recovery opened it — the socket opened after that
      stretch began — and that stretch ended within `FLICKER_BOUND_SECONDS` of
      this one, so both are flicks of one recovery;
    - the phone's retained connection id is the same on both sides of the loss
      (`retained_connection_unchanged`): no connection changed, so there is no
      lost connection for the slow span to be the cause of.

    A connection that had already closed when the episode began is the same
    case from the other side: its late completion is abandoned work, which the
    Gateway logs as `connectionClosed`. A connection with no readable
    `connection.opened` record (a rotated log) is not excluded on a guess.
    """
    if opened_within(episode, gateway, connection_id):
        return True
    history = gateway.connection(connection_id or "")
    loss_at = published_loss_at(episode)
    opens = [record.timestamp for record in history
             if record.event == "connection.opened" and record.timestamp is not None]
    handshake = timedelta(seconds=RECOVERY_HANDSHAKE_SECONDS)
    if any(loss_at - handshake <= opened <= loss_at for opened in opens):
        return True
    previous = episode.previous_stretch
    if previous is not None \
            and episode.start - previous[1] <= timedelta(seconds=FLICKER_BOUND_SECONDS) \
            and any(previous[0] <= opened <= episode.start for opened in opens):
        return True
    if retained_connection_unchanged(episode, loss_at):
        return True
    return any(record.event == "connection.closed" and record.timestamp is not None
               and record.timestamp <= episode.start for record in history)


def published_loss_at(episode: Episode) -> datetime:
    """The instant the episode's loss was published.

    A label-derived stretch is the stretch of the transition itself, so the
    instant is its start (`outage_transition`); a declared or attempt-cluster
    episode has no transition of its own and its start is the bound there is.
    The handshake rule and the retained connection id both measure from it.
    """
    transition = outage_transition(episode)
    if transition is not None and transition.timestamp is not None:
        return transition.timestamp
    return episode.start


def phone_connection_id(record: Record) -> Optional[str]:
    """The connection id the app published on this record, or None.

    A flicker is a published `connection.state-changed` (or the retained
    client's own `reconnect.connected` row): the id on it is the connection the
    app says it holds while it publishes the label. An attempt's
    `gatewayConnectionId` is the O-1 join key and not a statement about which
    connection the label is on, and an RPC row's numeric `connectionID` is one
    request's socket, so neither is read here.
    """
    if record.event not in ("connection.state-changed", LIFECYCLE_EVENT):
        return None
    return record.field("connectionID") or record.field("gatewayConnectionId")


def retained_connection_unchanged(episode: Episode, loss_at: datetime) -> bool:
    """Whether the app named one connection across this episode's loss.

    A flicker that publishes `reconnecting` while the app's own id on that
    record, and on the record that publishes the recovery, is the same one is a
    re-published label rather than a connection change: the socket the
    reconnect's refresh runs on is the one the app still has. Both sides must
    name one; an export that publishes no connection id is not read as
    unchanged on a guess.
    """
    before: Optional[str] = None
    after: Optional[str] = None
    for record in episode.phone_records:
        if record.timestamp is None:
            continue
        value = phone_connection_id(record)
        if value is None:
            continue
        if record.timestamp <= loss_at:
            before = value
        elif after is None:
            after = value
    return before is not None and before == after


def relay_window_explains(episode: Episode, window: Tuple[datetime, datetime, str]) -> bool:
    """Whether one relay window covers the outage, not just part of it.

    The window is the path being relayed, so it explains the outage only when
    the loss happened inside it and the episode ends inside it or within the
    app's own recovery delay after it closes (the close is the path returning).
    A window that closed minutes before the episode ended does not explain it:
    the measured silent gaps end long after their relay window closed and
    recorded no attempt, which is why the plan keeps them as the gap they are
    rather than as path faults.
    """
    slack = timedelta(seconds=RELAY_WINDOW_SLACK_SECONDS)
    return window[0] - slack <= episode.start and episode.end <= window[1] + slack


def relay_window_miss(episode: Episode, window: Tuple[datetime, datetime, str]) -> str:
    """Why this relay window is not the episode's cause, in one clause."""
    if window[1] < episode.start:
        return f"the path was direct from {format_timestamp(window[1])}"
    return (f"it closed {int((episode.end - window[1]).total_seconds())}s before the episode "
            f"ended")


def classify(episode: Episode, gateway: GatewayIndex, tolerance: timedelta,
             tailscale: Optional[TailscaleCapture]) -> None:
    """Set one episode's cause and evidence; the first matching rule wins."""
    margin = evidence_margin(tolerance)
    padded_start = episode.start - margin
    padded_end = episode.end + margin
    evidence: List[Dict[str, Any]] = []
    join_modes: Set[str] = set()
    matches: List[Tuple[str, Record]] = []
    relay_windows = tailscale.relay_windows() if tailscale is not None else []
    relay_window = next((window for window in relay_windows
                         if relay_window_explains(episode, window)), None)
    for record in gateway.window(padded_start, padded_end):
        mode = gateway_join(episode, record, tolerance)
        if mode is None:
            continue
        join_modes.add(mode)
        matches.append((mode, record))
    episode.join = "key" if "key" in join_modes else ("window" if "window" in join_modes else "none")
    # One join decides the evidence: when the O-1 key joins any record, a record
    # that names another connection is that connection's and not this episode's,
    # because mixing the two modes reads a neighbour's slow span as this
    # episode's cause. Gateway-wide records (a delayed event loop, host
    # resources) name no connection and still count when they fall inside the
    # episode. The 60 s window join is the fallback for logs written before the
    # key existed.
    if episode.join == "key":
        matches = [(mode, record) for mode, record in matches
                   if mode == "key"
                   or (record.field("connectionId") is None
                       and record.field("peerClientId") is None)]
    elif episode.join == "window":
        matches = [(mode, record) for mode, record in matches if mode == "window"]

    # Rule 1 — path: inbound silence the Gateway attributed to a relay or an
    # offline peer, or a transport-open failure that never reached this Mac
    # while the app was in the foreground.
    parked = background_parked(episode)
    silent = [(mode, record) for mode, record in matches
              if record.event == "connection.inbound-silent"
              and record.field("peerPath") in ("relay", "offline")]
    if silent:
        episode.cause = CAUSE_PATH
        for mode, record in silent[:MAX_EVIDENCE_LINES]:
            evidence.append(evidence_entry(
                "gateway", record, "cause",
                f"peerPath={record.field('peerPath')} peerRelay={record.field('peerRelay', '-')} "
                f"joinedBy={mode} {record.message}"))
            # `connection.inbound-resumed` closes the same episode and carries
            # its measured length, so the pair reads as one outage.
            connection_id = record.field("connectionId")
            if connection_id is None:
                continue
            resumed = next((candidate for candidate in gateway.connection(connection_id)
                            if candidate.event == "connection.inbound-resumed"
                            and candidate.timestamp is not None
                            and candidate.timestamp > record.timestamp), None)
            if resumed is not None:
                evidence.append(evidence_entry(
                    "gateway", resumed, "context",
                    f"silentMs={resumed.field('silentMs', '-')} {resumed.message}"))
    if episode.cause != CAUSE_PATH and parked is None:
        unanswered: List[Attempt] = []
        for attempt in episode.attempt_records:
            if not attempt.failed or attempt.stage != "transport-open":
                continue
            if not attempt_belongs(episode, attempt):
                continue
            start, end = attempt.span()
            if not attempt_reached_mac(attempt, gateway.window(start, end)):
                unanswered.append(attempt)
        if unanswered:
            episode.cause = CAUSE_PATH
            for attempt in unanswered[:MAX_EVIDENCE_LINES]:
                evidence.append(evidence_entry(
                    "phone", attempt.record, "cause",
                    f"transport-open timeout of {int(attempt.duration_ms or 0)}ms with no Gateway "
                    f"accept for {attempt.client_id or 'unknown'}/{attempt.attempt_id or 'unknown'} "
                    f"profile={attempt.profile or 'unknown'} (reason={attempt.reason or 'unknown'})"))
        elif relay_window is not None:
            episode.cause = CAUSE_PATH
            evidence.append({
                "source": "tailscale", "role": "cause",
                "timestamp": format_timestamp(relay_window[0]), "event": "path.change",
                "detail": f"{relay_window[2]} path window {format_timestamp(relay_window[0])}.."
                          f"{format_timestamp(relay_window[1])}",
            })

    # Rule 2 — phone-background: recovery is parked by design in the background.
    if episode.cause == CAUSE_UNKNOWN and parked is not None:
        reason, record = parked
        episode.cause = CAUSE_BACKGROUND
        if record is not None:
            evidence.append(evidence_entry("phone", record, "cause", record.message))
        else:
            evidence.append({
                "source": "phone", "role": "cause", "timestamp": format_timestamp(episode.start),
                "event": "connection.episode",
                "detail": f"{reason}; endedBy={episode.ended_by or 'unknown'} "
                          f"attempts={episode.attempts}",
            })

    # Rule 3 — phone-stall: a watchdog fired, or the label was wrong while the
    # Gateway kept answering on the socket that phone epoch named.
    if episode.cause == CAUSE_UNKNOWN:
        watchdogs = [record for record in episode.phone_records
                     if record.event in ("reconnect.stalled", "app.main-stall")]
        if watchdogs:
            episode.cause = CAUSE_PHONE_STALL
            for record in watchdogs[:MAX_EVIDENCE_LINES]:
                evidence.append(evidence_entry("phone", record, "cause", record.message))
        else:
            labelled = label_over_live_socket(episode, gateway)
            if labelled is not None:
                transition, answered_by, answered = labelled
                episode.cause = CAUSE_PHONE_STALL
                evidence.append(evidence_entry(
                    "phone", transition, "cause",
                    f"published state stayed "
                    f"{transition.field('new') or transition.outcome} for the episode while "
                    f"the Gateway answered {answered.field('method') or 'a request'} on "
                    f"{answered_by} in "
                    f"{int(answered.number('durationMs') or 0)}ms"))

    # Rule 4 — gateway-stall: a delayed event loop, or a slow span that was
    # already running when the loss happened. The work must have started before
    # the loss and still been running then: `completion - durationMs < loss <=
    # completion`. A refresh the reconnect issued after the episode ended changes
    # nothing about it, and neither does one issued on the connection the
    # reconnect opened (see `recovery_connection` — the socket it opened in the
    # handshake before the loss, the previous stretch's own recovery socket, or
    # one the phone's unchanged connection id says never dropped): on the
    # incident export most `gateway-stall` episodes rested on the recovering
    # socket's own `session.list`, which the reconnect had just requested. A
    # delayed heartbeat or a resource warning counts only inside the episode,
    # never in the pad.
    if episode.cause == CAUSE_UNKNOWN:
        loss_at = published_loss_at(episode)
        stalled: List[Record] = []
        for _mode, record in matches:
            if record.timestamp is None:
                continue
            if record.event == "gateway.event-loop-delay":
                if episode.start <= record.timestamp <= episode.end:
                    stalled.append(record)
            elif record.event == "gateway.resources" and record.level in ("warning", "error"):
                if episode.start <= record.timestamp <= episode.end:
                    stalled.append(record)
            elif record.event == "rpc.completed":
                duration = record.number("durationMs")
                if duration is None or duration < SLOW_RPC_WARNING_MS:
                    continue
                if recovery_connection(episode, gateway, record.field("connectionId")):
                    continue
                if record.timestamp - timedelta(milliseconds=duration) < loss_at <= record.timestamp:
                    stalled.append(record)
        if stalled:
            episode.cause = CAUSE_GATEWAY_STALL
            for record in stalled[:MAX_EVIDENCE_LINES]:
                duration = record.number("durationMs")
                detail = record.message if duration is None else f"durationMs={int(duration)} {record.message}"
                evidence.append(evidence_entry("gateway", record, "cause", detail))

    # Rule 5 — gateway-capacity: a named bound refused or dropped the work. It
    # counts inside the episode only: a refusal in the pad belongs to whatever
    # the Gateway was doing then, not to this outage.
    if episode.cause == CAUSE_UNKNOWN:
        capacity = [record for mode, record in matches
                    if episode.start <= (record.timestamp or episode.start) <= episode.end
                    and (record.event in CAPACITY_EVENTS
                         or (record.event == "http.upgrade"
                             and record.field("reason") in CAPACITY_UPGRADE_REASONS)
                         or (record.event == "rpc.error" and record.field("code") == "busy"))]
        if capacity:
            episode.cause = CAUSE_GATEWAY_CAPACITY
            for record in capacity[:MAX_EVIDENCE_LINES]:
                evidence.append(evidence_entry("gateway", record, "cause", record.message))

    # Context, always: what the phone's own attempts did, and the one join fact
    # an `unknown` episode still has to show. The gap statement is only true when
    # neither attempt shape recorded one, which is why an export's own
    # `operation.gatewayConnect` rows are counted here too.
    if not episode.attempt_records and episode.boundary is not None:
        evidence.append(evidence_entry(
            "phone", episode.boundary, "context",
            f"no attempt recorded in this window (gap of "
            f"{int(episode.duration_seconds)}s); published state "
            f"{episode.boundary.field('new') or episode.boundary.field('endedBy') or 'unknown'}"))
    for attempt in episode.attempt_records[:MAX_EVIDENCE_LINES]:
        evidence.append(evidence_entry(
            "phone", attempt.record, "context", attempt.context_detail()))
    for window in relay_windows:
        # A window that only overlaps the episode is context, not a cause: the
        # report names it so an operator can see the path was relayed nearby
        # without the outage being attributed to it.
        if window is relay_window or not overlaps(episode.start, episode.end,
                                                  window[0], window[1]):
            continue
        evidence.append({
            "source": "tailscale", "role": "context",
            "timestamp": format_timestamp(window[0]), "event": "path.change",
            "detail": f"{window[2]} path window {format_timestamp(window[0])}.."
                      f"{format_timestamp(window[1])} does not cover this episode "
                      f"({relay_window_miss(episode, window)})",
        })
    if episode.join == "none":
        evidence.append({
            "source": "join", "role": "context", "timestamp": format_timestamp(episode.start),
            "event": "join", "detail": "no Gateway record in this window to join",
        })
    if tailscale is not None:
        evidence.append({
            "source": "tailscale", "role": "context",
            "timestamp": format_timestamp(tailscale.window[0] if tailscale.window else episode.start),
            "event": "tailscale.window",
            "detail": f"{tailscale.reason}; {len(tailscale.lines)} path-change line(s)"
                      + ("" if tailscale.window is None
                         else f" in {format_timestamp(tailscale.window[0])}.."
                              f"{format_timestamp(tailscale.window[1])}"),
        })
    episode.evidence = (
        [entry for entry in evidence if entry["role"] == "cause"]
        + [entry for entry in evidence if entry["role"] != "cause"]
    )[:MAX_EVIDENCE_LINES]


def default_gateway_directory() -> Path:
    return Path.home() / ".tron/logs"


def triage_reports(export_paths: Sequence[Path], gateway_directory: Optional[Path],
                   tolerance_seconds: int, tailscale_requested: bool,
                   tailscale_peer: Optional[str] = None) -> Dict[str, Any]:
    if not export_paths:
        raise TriageError("at least one phone export is required")
    exports = [load_phone_export(path) for path in export_paths]
    phone_records: List[Record] = []
    for export in exports:
        phone_records.extend(export.records)
    phone_records.sort(key=lambda record: record.timestamp or datetime.min.replace(tzinfo=timezone.utc))

    gateway_files: List[Dict[str, Any]] = []
    gateway_source = "gateway-logs"
    gateway_directory_text: Optional[str] = None
    gateway_input: List[Record] = []
    if gateway_directory is not None and gateway_directory.is_dir():
        logs = load_gateway_logs(gateway_directory)
        gateway_input = logs.records
        gateway_files = logs.files
        gateway_directory_text = logs.directory
    if not gateway_input:
        # A Logs export embeds the Mac's own rows, so a phone-only artifact
        # still has a Gateway timeline. It is a bounded projection, not the
        # canonical file, and the report names which source it read.
        gateway_input = [record for export in exports for record in export.gateway_records]
        gateway_source = "export-projection" if gateway_input else "none"
    gateway = GatewayIndex(records=list(gateway_input))

    tolerance = timedelta(seconds=tolerance_seconds)
    episodes = build_episodes(phone_records, gateway, tolerance)

    tailscale: Optional[TailscaleCapture] = None
    if tailscale_requested:
        stamps = [record.timestamp for record in phone_records if record.timestamp is not None]
        tailscale = (capture_tailscale_window(min(stamps), max(stamps), tailscale_peer) if stamps
                     else TailscaleCapture(captured=False, peer=tailscale_peer,
                                           reason="no phone records to bound the window"))

    for episode in episodes:
        classify(episode, gateway, tolerance, tailscale)

    by_cause: Dict[str, int] = {cause: 0 for cause in CAUSES}
    join_modes: Dict[str, int] = {"key": 0, "window": 0, "none": 0}
    for episode in episodes:
        by_cause[episode.cause] = by_cause.get(episode.cause, 0) + 1
        join_modes[episode.join] = join_modes.get(episode.join, 0) + 1

    outside_episodes = sum(
        1 for record in phone_records
        if record.timestamp is not None
        and record.event in ("gateway.attempt", "connection.episode", "gateway.connection")
        and not any(episode.start - tolerance <= record.timestamp <= episode.end
                    for episode in episodes)
    )
    return {
        "schema": SCHEMA,
        "generatedAt": format_timestamp(datetime.now(timezone.utc)),
        "inputs": {
            "phoneExports": [
                {"path": export.path, "records": len(export.records),
                 "unreadableLines": export.unreadable_lines, "capture": export.capture}
                for export in exports
            ],
            "gatewayLogs": {
                "directory": gateway_directory_text,
                "source": gateway_source,
                "records": len(gateway.records),
                "files": gateway_files,
            },
            "tailscaleWindow": None if tailscale is None else {
                "captured": tailscale.captured,
                "reason": tailscale.reason,
                "peer": tailscale.peer,
                "lines": len(tailscale.lines),
                "window": None if tailscale.window is None else [
                    format_timestamp(tailscale.window[0]), format_timestamp(tailscale.window[1])],
                # The relay windows themselves, not just their count: the
                # unified log rotates, so the rows a cause-1 run read are gone
                # within days and the report is the only place they survive.
                "relayWindows": [
                    {"kind": kind, "start": format_timestamp(start),
                     "end": format_timestamp(end)}
                    for start, end, kind in tailscale.relay_windows()
                ],
            },
            "joinToleranceSeconds": tolerance_seconds,
            "evidencePadSeconds": EVIDENCE_PAD_SECONDS,
            "evidenceMarginSeconds": int(evidence_margin(tolerance).total_seconds()),
        },
        "summary": {
            "episodes": len(episodes),
            "byCause": by_cause,
            "joinModes": join_modes,
            "phoneRecords": len(phone_records),
            "gatewayRecords": len(gateway.records),
            "connectionRecordsOutsideEpisodes": outside_episodes,
        },
        "episodes": [
            {
                "index": index,
                "start": format_timestamp(episode.start),
                "end": format_timestamp(episode.end),
                "durationMs": int(round(episode.duration_seconds * 1_000)),
                "cause": episode.cause,
                "attempts": episode.attempts,
                "endedBy": episode.ended_by,
                "profile": episode.profile,
                "clientId": episode.client_id,
                "derived": episode.derived,
                "declaredCauses": episode.declared_causes,
                "joinedBy": episode.join,
                "evidence": episode.evidence,
            }
            for index, episode in enumerate(episodes, 1)
        ],
    }


def render_text(report: Dict[str, Any]) -> str:
    inputs = report["inputs"]
    summary = report["summary"]
    lines: List[str] = []
    gateway = inputs["gatewayLogs"]
    lines.append(
        f"tron-triage {report['schema']}  phone: {len(inputs['phoneExports'])} export(s), "
        f"{summary['phoneRecords']} record(s)  gateway: {gateway['source']}, "
        f"{gateway['records']} record(s)"
        + ("" if gateway["directory"] is None else f" ({gateway['directory']})"))
    for export in inputs["phoneExports"]:
        capture = export["capture"] or {}
        represented = f"{capture.get('representedFrom') or 'unknown'}.." \
                      f"{capture.get('representedThrough') or 'unknown'}"
        lines.append(f"  {export['path']}: {export['records']} record(s), represented {represented}"
                     + ("" if not export["unreadableLines"]
                        else f", {export['unreadableLines']} unreadable line(s)"))
    tailscale = inputs["tailscaleWindow"]
    if tailscale is not None:
        lines.append(f"  tailscale window: {tailscale['reason']}, {tailscale['lines']} path line(s)"
                     + ("" if tailscale["peer"] is None else f" for peer {tailscale['peer']}")
                     + ("" if tailscale["window"] is None
                        else f" over {tailscale['window'][0]}..{tailscale['window'][1]}"))
    lines.append(
        f"episodes: {summary['episodes']}  by cause: "
        + ", ".join(f"{cause}={count}" for cause, count in summary["byCause"].items())
        + f"  joined: key={summary['joinModes']['key']} window={summary['joinModes']['window']} "
          f"none={summary['joinModes']['none']}")
    if not report["episodes"]:
        lines.append("no episode found: the export carries no connection.episode, gateway.attempt "
                     "or connection.state-changed record")
        return "\n".join(lines)
    lines.append("")
    header = f"{'#':>3}  {'start (UTC)':<24} {'duration':>9}  {'cause':<17} {'att':>3}  " \
             f"{'endedBy':<10} {'join':<6}"
    lines.append(header)
    lines.append("-" * len(header))
    for episode in report["episodes"]:
        lines.append(
            f"{episode['index']:>3}  {episode['start']:<24} "
            f"{episode['durationMs'] / 1000:>8.1f}s  {episode['cause']:<17} "
            f"{episode['attempts']:>3}  {episode['endedBy'] or '-':<10} {episode['joinedBy']:<6}")
    lines.append("")
    for episode in report["episodes"]:
        lines.append(f"#{episode['index']} {episode['start']}..{episode['end']} "
                     f"{episode['durationMs']}ms cause={episode['cause']} "
                     f"attempts={episode['attempts']} endedBy={episode['endedBy'] or '-'} "
                     f"joinedBy={episode['joinedBy']}"
                     + (" derived" if episode["derived"] else "")
                     + ("" if not episode["declaredCauses"]
                        else f" declaredCauses={','.join(episode['declaredCauses'])}"))
        for entry in episode["evidence"]:
            lines.append(f"    [{entry['role']}] {entry['source']} {entry['timestamp']} "
                         f"{entry['event']}: {entry['detail']}")
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="tron-triage",
        description="Turn an incident's phone exports and Gateway log into episodes by cause.",
    )
    parser.add_argument("phone_exports", nargs="*", type=Path,
                        help="phone export JSONL files (tron-diagnostics*.jsonl)")
    parser.add_argument("--phone", action="append", type=Path, default=[], metavar="PATH",
                        help="a phone export; repeatable")
    parser.add_argument("--gateway-logs", type=Path, default=default_gateway_directory(),
                        metavar="DIR",
                        help="directory holding gateway.jsonl and its rotations "
                             "(default: ~/.tron/logs)")
    parser.add_argument("--no-gateway-logs", action="store_true",
                        help="ignore the Gateway log directory and use the rows a phone export carries")
    parser.add_argument("--tailscale-window", action="store_true",
                        help="capture the Tailscale network-extension log with log show for the "
                             "export's time range and use it as path evidence")
    parser.add_argument("--tailscale-peer", metavar="NODE",
                        help="only read path lines naming this Magicsock peer node key "
                             "(e.g. fakeNodeKey), so another peer's relay stretch is "
                             "not read as "
                             "the phone's")
    parser.add_argument("--tolerance-seconds", type=int, default=DEFAULT_JOIN_TOLERANCE_SECONDS,
                        metavar="N",
                        help="time-window join and evidence margin for logs without the O-1 "
                             f"key; below {EVIDENCE_PAD_SECONDS} the model's own bound still "
                             f"applies (default: {DEFAULT_JOIN_TOLERANCE_SECONDS})")
    parser.add_argument("--json", action="store_true",
                        help="print the JSON report instead of the table")
    parser.add_argument("--out", type=Path, metavar="PATH", help="also write the JSON report to PATH")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    arguments = parser.parse_args(argv)
    exports = list(arguments.phone) + list(arguments.phone_exports)
    if not exports:
        parser.print_usage(sys.stderr)
        print("error: at least one phone export is required", file=sys.stderr)
        return EXIT_INVALID
    for path in exports:
        if not path.is_file():
            print(f"error: no such phone export: {path}", file=sys.stderr)
            return EXIT_INVALID
    if arguments.tolerance_seconds < 0:
        print("error: --tolerance-seconds cannot be negative", file=sys.stderr)
        return EXIT_INVALID
    gateway_directory = None if arguments.no_gateway_logs else arguments.gateway_logs
    if gateway_directory is not None and not gateway_directory.is_dir():
        print(f"warning: no Gateway log directory at {gateway_directory}; "
              f"using the rows the exports carry", file=sys.stderr)
        gateway_directory = None
    if arguments.out is not None:
        resolved = arguments.out.resolve()
        for path in exports:
            if path.resolve() == resolved:
                print(f"error: refusing to overwrite the input {path}", file=sys.stderr)
                return EXIT_INVALID
    try:
        report = triage_reports(exports, gateway_directory, arguments.tolerance_seconds,
                                arguments.tailscale_window, arguments.tailscale_peer)
    except TriageError as error:
        print(f"error: {error}", file=sys.stderr)
        return EXIT_INVALID
    text = json.dumps(report, indent=2) + "\n"
    if arguments.out is not None:
        try:
            arguments.out.write_text(text, encoding="utf-8")
        except OSError as error:
            print(f"error: cannot write {arguments.out}: {error}", file=sys.stderr)
            return EXIT_INVALID
    print(text if arguments.json else render_text(report))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
