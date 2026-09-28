#!/usr/bin/env python3
"""Triage one incident's logs into episodes by cause.

`scripts/tron-triage` is the front door. The inputs are one or more phone
exports (the `tron-diagnostics*.jsonl` files an iOS Logs export produces) and
the Gateway log with its rotations (`<tron home>/logs`); both are read only and
never rewritten, and nothing is sent anywhere.

Phone and Gateway records are joined by the O-1 correlation key (a phone
`gatewayConnectionId` is a Gateway `connectionId`, and its `clientId`/
`attemptId` are the Gateway's `peerClientId`/`peerAttemptId`), falling back to a
time window for logs written before protocol 6. Every episode is classified by
the first matching rule in `classify`, in the order the hardening plan fixes:
`path`, `phone-background`, `phone-stall`, `gateway-stall`, `gateway-capacity`,
`unknown`. Each classification carries the records it used, so an operator
checks the attribution instead of trusting it.
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
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Set, Tuple

SCHEMA = "tron.triage-report.v1"
EXIT_OK = 0
EXIT_INVALID = 2

# `SLOW_RPC_WARNING_MS` in packages/gateway/src/transport/server.ts: at or above
# this a completed RPC is a warning, which is what "a slow span" means here.
SLOW_RPC_WARNING_MS = 1_000
# Two logs are the same event when they are this close and no correlation key
# joins them (protocol-5 exports). The measured reconnect cycle is under a
# minute; a wider window starts matching a neighbour's socket.
DEFAULT_JOIN_TOLERANCE_SECONDS = 60
# `gateway.jsonl` plus its seven numbered segments (logger.ts rotation).
GATEWAY_LOG_SEGMENTS = 8
# The Gateway's own records can land just outside an episode's bounds: a loss is
# admitted after the last readable frame, and a slow open answers after the
# phone gives up. Evidence is collected over this pad, and the report states it.
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
# A phone connection state that means the app is not connected.
OUTAGE_STATES = ("reconnecting", "restarting")
# The scene records that say which side of the foreground boundary the app is
# on; the last one before an episode's end is the app's state there.
SCENE_EVENTS = ("scene.background", "scene.foreground", "scene.active")

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
LOG_SHOW_TIMESTAMP = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}[.,]\d+[+-]\d{4})")
TAILSCALE_RELAY_LINE = re.compile(r"relay|derp", re.IGNORECASE)
TAILSCALE_DIRECT_LINE = re.compile(r"\bdirect\b|directpath", re.IGNORECASE)
TAILSCALE_OFFLINE_LINE = re.compile(r"offline|no route|unreachable", re.IGNORECASE)


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

    def span(self) -> Tuple[datetime, datetime]:
        """The interval this attempt occupied, its own deadline included."""
        length = self.duration_ms if self.duration_ms is not None else 20_000.0
        return (self.timestamp - timedelta(milliseconds=length + 2_000),
                self.timestamp + timedelta(seconds=2))


def phone_attempts(records: Iterable[Record]) -> List[Attempt]:
    attempts: List[Attempt] = []
    seen_stages: Set[Tuple[str, str, str]] = set()
    for record in records:
        if record.timestamp is None:
            continue
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
        elif record.event == "gateway.connection" and record.field("stage") in ATTEMPT_STAGES:
            key = (record.field("clientID", "") or "", record.field("attemptID", "") or "",
                   record.field("stage", "") or "")
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
    """One outage, from a `connection.episode` record or derived from evidence."""

    start: datetime
    end: datetime
    attempts: int = 0
    ended_by: Optional[str] = None
    profile: Optional[str] = None
    derived: bool = False
    declared_causes: List[str] = dataclass_field(default_factory=list)
    boundary: Optional[Record] = None
    phone_records: List[Record] = dataclass_field(default_factory=list)
    attempt_records: List[Attempt] = dataclass_field(default_factory=list)
    gateway_ids: Set[str] = dataclass_field(default_factory=set)
    phone_keys: Set[Tuple[str, str]] = dataclass_field(default_factory=set)
    join: str = "none"
    cause: str = CAUSE_UNKNOWN
    evidence: List[Dict[str, Any]] = dataclass_field(default_factory=list)

    @property
    def duration_seconds(self) -> float:
        return max(0.0, (self.end - self.start).total_seconds())


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
            declared_causes=[value for value in causes if value and value != "none"],
            boundary=record,
        ))
    return episodes


def label_windows(records: Sequence[Record]) -> List[Tuple[Record, datetime, datetime]]:
    """Windows the published connection state called an outage.

    This is the evidence a protocol-5 export has for a loss, and it is how an
    episode with no attempt of its own (a silent recovery gap, or a label over a
    socket that never dropped) is found at all. A window opens on a transition
    into an outage state and closes on the first of: a transition out of one, a
    scene entering the background (which retires recovery without publishing a
    new state), or the end of a `connection.episode` record. Without those two
    extra closers, an outage that ended in the background would swallow every
    later one into a single window.
    """
    windows: List[Tuple[Record, datetime, datetime]] = []
    opened: Optional[Tuple[Record, datetime]] = None
    last: Optional[datetime] = None

    def close(at: datetime) -> None:
        nonlocal opened
        if opened is not None and at >= opened[1]:
            windows.append((opened[0], opened[1], at))
        opened = None

    for record in records:
        if record.timestamp is None:
            continue
        last = record.timestamp if last is None else max(last, record.timestamp)
        if record.event == "connection.state-changed":
            state = record.field("new") or record.field("outcome") or ""
            if state in OUTAGE_STATES:
                if opened is None:
                    opened = (record, record.timestamp)
            else:
                close(record.timestamp)
        elif record.event == "scene.background":
            close(record.timestamp)
        elif record.event == "connection.episode":
            close(record.timestamp)
    if opened is not None and last is not None:
        close(last)
    return windows


def derived_episodes(records: Sequence[Record], attempts: Sequence[Attempt],
                     covered: Sequence[Episode]) -> List[Episode]:
    """Episodes no `connection.episode` record describes.

    Two shapes are derived: an outage-label window (which can carry no attempt
    at all, the measured silent recovery gap) and a cluster of consecutive
    failed attempts that ends at the attempt which connected. The label window
    wins when both describe one outage, because it starts at the loss the app
    published rather than at the first attempt's start.
    """
    derived: List[Episode] = []
    merge_pad = timedelta(seconds=EPISODE_MERGE_PAD_SECONDS)

    def is_covered(start: datetime, end: datetime) -> bool:
        return any(overlaps(start, end, episode.start, episode.end, merge_pad)
                   for episode in list(covered) + derived)

    for opener, start, end in label_windows(records):
        if is_covered(start, end):
            continue
        window_attempts = [attempt for attempt in attempts if start <= attempt.timestamp <= end]
        derived.append(Episode(
            start=start, end=end, attempts=len(window_attempts), derived=True,
            ended_by="connected", attempt_records=window_attempts, boundary=opener,
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
                start=cluster_start, end=attempt.timestamp, attempts=len(cluster_attempts),
                ended_by="connected", derived=True, attempt_records=list(cluster_attempts),
                boundary=cluster_attempts[0].record,
            ))
        cluster_start = None
        cluster_attempts = []
    return derived


def annotate_episode(episode: Episode, phone: Sequence[Record], attempts: Sequence[Attempt],
                     gateway: GatewayIndex) -> None:
    """Attach the phone records, attempts and O-1 keys one episode owns."""
    episode.phone_records = [
        record for record in phone
        if record.timestamp is not None
        and episode.start - timedelta(seconds=EPOCH_LOOKBACK_SECONDS) <= record.timestamp
        <= episode.end + timedelta(seconds=EVIDENCE_PAD_SECONDS)
    ]
    if not episode.attempt_records:
        episode.attempt_records = [
            attempt for attempt in attempts
            if episode.start - timedelta(seconds=5) <= attempt.timestamp <= episode.end
        ]
    if episode.attempts == 0 and episode.attempt_records:
        episode.attempts = len(episode.attempt_records)
    for record in episode.phone_records:
        # Every phone record that names the Gateway connection, or the pair the
        # Gateway stamps as peerClientId/peerAttemptId, is a join key.
        gateway_id = record.field("gatewayConnectionId")
        if gateway_id:
            episode.gateway_ids.add(gateway_id)
        if record.event == "reconnect.connected":
            gateway_id = record.field("connectionId")
            if gateway_id:
                episode.gateway_ids.add(gateway_id)
        client_id = record.field("clientId") or record.field("clientID")
        attempt_id = record.field("attemptId") or record.field("attemptID")
        if client_id and attempt_id:
            episode.phone_keys.add((client_id, attempt_id))
    for gateway_id in list(episode.gateway_ids):
        if not gateway.connection(gateway_id):
            episode.gateway_ids.discard(gateway_id)


def build_episodes(phone: Sequence[Record], gateway: GatewayIndex,
                   tolerance: timedelta) -> List[Episode]:
    attempts = phone_attempts(phone)
    episodes = declared_episodes(phone)
    episodes.extend(derived_episodes(phone, attempts, episodes))
    episodes.sort(key=lambda episode: episode.start)
    for episode in episodes:
        annotate_episode(episode, phone, attempts, gateway)
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
    if episode.start - tolerance <= record.timestamp <= episode.end + timedelta(seconds=EVIDENCE_PAD_SECONDS):
        return "window"
    return None


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
    window: Optional[Tuple[datetime, datetime]] = None
    lines: List[Tuple[datetime, str]] = dataclass_field(default_factory=list)

    def relay_windows(self) -> List[Tuple[datetime, datetime, str]]:
        """Relay or offline stretches between path-change lines.

        The extension log is the only Tailscale evidence a pre-O-2 Gateway log
        leaves behind, and its path lines are message text, so this read is
        deliberately conservative: a relay line opens a window and a direct line
        closes it. It is evidence, never proof.
        """
        windows: List[Tuple[datetime, datetime, str]] = []
        opened_at: Optional[datetime] = None
        kind = ""
        for timestamp, text in self.lines:
            if TAILSCALE_OFFLINE_LINE.search(text):
                if opened_at is None:
                    opened_at, kind = timestamp, "offline"
            elif TAILSCALE_DIRECT_LINE.search(text):
                if opened_at is not None:
                    windows.append((opened_at, timestamp, kind))
                    opened_at, kind = None, ""
            elif TAILSCALE_RELAY_LINE.search(text):
                if opened_at is None:
                    opened_at, kind = timestamp, "relay"
        if opened_at is not None and self.lines:
            windows.append((opened_at, self.lines[-1][0], kind))
        return windows


def capture_tailscale_window(
    start: datetime, end: datetime,
    runner: Optional[Callable[..., subprocess.CompletedProcess]] = None,
) -> TailscaleCapture:
    """Read the Tailscale network-extension log for one UTC range."""
    if (end - start).total_seconds() <= 0:
        return TailscaleCapture(captured=False, reason="export range is empty")
    if (end - start).total_seconds() > MAX_TAILSCALE_WINDOW_SECONDS:
        end = start + timedelta(seconds=MAX_TAILSCALE_WINDOW_SECONDS)
    arguments = [TAILSCALE_LOG_TOOL, "show", "--style", "compact",
                 "--start", format_local(start), "--end", format_local(end),
                 "--predicate", f'process == "{TAILSCALE_EXTENSION_PROCESS}"']
    invoke = runner or (lambda args, timeout: subprocess.run(
        args, capture_output=True, text=True, timeout=timeout))
    try:
        completed = invoke(arguments, LOG_SHOW_TIMEOUT_SECONDS)
    except (OSError, subprocess.SubprocessError) as error:
        return TailscaleCapture(captured=False, reason=f"log show failed: {error}")
    if completed.returncode != 0:
        return TailscaleCapture(captured=False, reason=f"log show exited {completed.returncode}")
    lines: List[Tuple[datetime, str]] = []
    for raw in (completed.stdout or "").splitlines():
        match = LOG_SHOW_TIMESTAMP.match(raw.strip())
        if match is None:
            continue
        timestamp = parse_timestamp(match.group(1).replace(",", ".").replace(" ", "T"))
        if timestamp is None:
            continue
        if TAILSCALE_RELAY_LINE.search(raw) or TAILSCALE_DIRECT_LINE.search(raw) \
                or TAILSCALE_OFFLINE_LINE.search(raw):
            lines.append((timestamp, raw.strip()))
    return TailscaleCapture(captured=True, reason="captured", window=(start, end), lines=lines)


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


def label_over_live_socket(episode: Episode, gateway: GatewayIndex) -> Optional[Record]:
    """A `reconnecting` label while the Gateway socket answered requests.

    The 2026-09-27 incident's second cause: the published state stayed
    `reconnecting` from 04:05:25 to 04:11:46 while chats opened on the same
    socket. The Gateway proves the socket was live by completing a request on
    the connection that phone epoch named while that connection was still open,
    so a socket that had already closed is a real loss, not a wrong label.
    """
    for record in episode.phone_records:
        if record.event != "connection.state-changed" or record.timestamp is None:
            continue
        if (record.field("new") or record.field("outcome") or "") not in OUTAGE_STATES:
            continue
        connection_id = epoch_connection_id(episode, record.timestamp)
        if connection_id is None:
            continue
        history = gateway.connection(connection_id)
        if not history:
            continue
        opened = any(candidate.event == "connection.opened" and candidate.timestamp is not None
                     and candidate.timestamp <= record.timestamp for candidate in history)
        closed_at = [candidate.timestamp for candidate in history
                     if candidate.event == "connection.closed" and candidate.timestamp is not None]

        def open_at(moment: datetime) -> bool:
            return not any(closed <= moment for closed in closed_at)

        answered = any(candidate.event == "rpc.completed" and candidate.timestamp is not None
                       and candidate.timestamp >= record.timestamp
                       and candidate.field("outcome", "success") == "success"
                       and open_at(candidate.timestamp) for candidate in history)
        if opened and answered:
            return record
    return None


def attempt_reached_mac(attempt: Attempt, window: Sequence[Record]) -> bool:
    """Did this attempt's own connection reach the Gateway?

    A transport-open failure whose own attempt never appears on a Gateway accept
    or upgrade means the path never reached this Mac. The check runs over the
    attempt's own span and needs the records to agree on the peer key: a
    Gateway record whose peer key contradicts the attempt is skipped, and a
    record with no peer key at all cannot confirm an attempt that has one, so a
    live main connection or the successful retry that followed is never read as
    this attempt's arrival. When neither side carries the key (a protocol-5
    phone and a protocol-5 Gateway), the span's own accept is the best evidence
    there is.
    """
    for record in window:
        if record.event not in UPGRADE_EVENTS:
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
    scenes = [record for record in episode.phone_records
              if record.event in SCENE_EVENTS and record.timestamp is not None
              and episode.start <= record.timestamp <= episode.end]
    if not scenes:
        return None
    last = max(scenes, key=lambda record: record.timestamp)
    return last if last.event == "scene.background" else None


def background_parked(episode: Episode) -> Optional[Tuple[str, Optional[Record]]]:
    """Why this episode was parked in the background, or None.

    A backgrounded phone parks recovery by design, so its attempts time out at
    transport-open without the Mac ever seeing them. That is not a path fault:
    the path clause of the first rule is skipped for a parked episode, which is
    reported as `phone-background` instead.
    """
    scene = background_at_end(episode)
    if scene is not None:
        return ("the app was in the background at the episode's end", scene)
    if episode.ended_by == "background":
        return ("the episode ended at a background transition", episode.boundary)
    if episode.attempt_records and all(attempt.foreground is False
                                       for attempt in episode.attempt_records):
        return ("every attempt was made in the background", episode.attempt_records[0].record)
    return None


def classify(episode: Episode, gateway: GatewayIndex, tolerance: timedelta,
             tailscale: Optional[TailscaleCapture]) -> None:
    """Set one episode's cause and evidence; the first matching rule wins."""
    padded_start = episode.start - timedelta(seconds=EVIDENCE_PAD_SECONDS)
    padded_end = episode.end + timedelta(seconds=EVIDENCE_PAD_SECONDS)
    evidence: List[Dict[str, Any]] = []
    join_modes: Set[str] = set()
    matches: List[Tuple[str, Record]] = []
    for record in gateway.window(padded_start, padded_end):
        mode = gateway_join(episode, record, tolerance)
        if mode is None:
            continue
        join_modes.add(mode)
        matches.append((mode, record))
    episode.join = "key" if "key" in join_modes else ("window" if "window" in join_modes else "none")

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
            start, end = attempt.span()
            if not attempt_reached_mac(attempt, gateway.window(start, end)):
                unanswered.append(attempt)
        relay_window = None
        if tailscale is not None:
            relay_window = next((window for window in tailscale.relay_windows()
                                 if overlaps(episode.start, episode.end, window[0], window[1])), None)
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
                episode.cause = CAUSE_PHONE_STALL
                evidence.append(evidence_entry(
                    "phone", labelled, "cause",
                    f"published state stayed {labelled.field('new') or labelled.outcome} for the "
                    f"episode while the Gateway answered requests on "
                    f"{epoch_connection_id(episode, labelled.timestamp) or 'unknown'}"))

    # Rule 4 — gateway-stall: a delayed event loop, or a slow span on this
    # connection.
    if episode.cause == CAUSE_UNKNOWN:
        stalled = [record for mode, record in matches
                   if record.event == "gateway.event-loop-delay"
                   or (record.event == "gateway.resources" and record.level in ("warning", "error"))
                   or (record.event == "rpc.completed"
                       and (record.number("durationMs") or 0) >= SLOW_RPC_WARNING_MS)]
        if stalled:
            episode.cause = CAUSE_GATEWAY_STALL
            for record in stalled[:MAX_EVIDENCE_LINES]:
                duration = record.number("durationMs")
                detail = record.message if duration is None else f"durationMs={int(duration)} {record.message}"
                evidence.append(evidence_entry("gateway", record, "cause", detail))

    # Rule 5 — gateway-capacity: a named bound refused or dropped the work.
    if episode.cause == CAUSE_UNKNOWN:
        capacity = [record for mode, record in matches
                    if record.event in CAPACITY_EVENTS
                    or (record.event == "http.upgrade"
                        and record.field("reason") in CAPACITY_UPGRADE_REASONS)
                    or (record.event == "rpc.error" and record.field("code") == "busy")]
        if capacity:
            episode.cause = CAUSE_GATEWAY_CAPACITY
            for record in capacity[:MAX_EVIDENCE_LINES]:
                evidence.append(evidence_entry("gateway", record, "cause", record.message))

    # Context, always: what the phone's own attempts did, and the one join fact
    # an `unknown` episode still has to show.
    if not episode.attempt_records and episode.boundary is not None:
        evidence.append(evidence_entry(
            "phone", episode.boundary, "context",
            f"no attempt recorded in this window (gap of "
            f"{int(episode.duration_seconds)}s); published state "
            f"{episode.boundary.field('new') or episode.boundary.field('endedBy') or 'unknown'}"))
    for attempt in episode.attempt_records[:MAX_EVIDENCE_LINES]:
        evidence.append(evidence_entry(
            "phone", attempt.record, "context",
            f"stageReached={attempt.stage or 'unknown'} reason={attempt.reason or 'none'} "
            f"outcome={attempt.outcome or 'unknown'} foreground={attempt.foreground}"))
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
                   runner: Optional[Callable[..., subprocess.CompletedProcess]] = None) -> Dict[str, Any]:
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
        tailscale = (capture_tailscale_window(min(stamps), max(stamps), runner) if stamps
                     else TailscaleCapture(captured=False,
                                           reason="no phone records to bound the window"))

    for episode in episodes:
        classify(episode, gateway, tolerance, tailscale)

    by_cause: Dict[str, int] = {cause: 0 for cause in CAUSES}
    join_modes: Dict[str, int] = {"key": 0, "window": 0, "none": 0}
    for episode in episodes:
        by_cause[episode.cause] = by_cause.get(episode.cause, 0) + 1
        join_modes[episode.join] = join_modes.get(episode.join, 0) + 1

    unjoined = sum(
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
                "lines": len(tailscale.lines),
                "window": None if tailscale.window is None else [
                    format_timestamp(tailscale.window[0]), format_timestamp(tailscale.window[1])],
            },
            "joinToleranceSeconds": tolerance_seconds,
            "evidencePadSeconds": EVIDENCE_PAD_SECONDS,
        },
        "summary": {
            "episodes": len(episodes),
            "byCause": by_cause,
            "joinModes": join_modes,
            "phoneRecords": len(phone_records),
            "gatewayRecords": len(gateway.records),
            "unjoinedConnectionRecords": unjoined,
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
    parser.add_argument("--tolerance-seconds", type=int, default=DEFAULT_JOIN_TOLERANCE_SECONDS,
                        metavar="N",
                        help="time-window join tolerance for logs without the O-1 key "
                             f"(default: {DEFAULT_JOIN_TOLERANCE_SECONDS})")
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
                                arguments.tailscale_window)
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
