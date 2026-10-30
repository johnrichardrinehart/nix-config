#!/usr/bin/env python3
"""Nebula peer registry for lighthouses.

For every local lighthouse instance (one per overlay), poll Nebula's debug SSH
console, keep a permanent history of every certificate ever seen, track
liveness, answer DNS for the overlay's zone, and serve an HTTPS view that shows
each caller the peers inside its own certificate's networks.
"""

from __future__ import annotations

import argparse
import datetime as dt
import html
import ipaddress
import json
import re
import socket
import socketserver
import sqlite3
import ssl
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from typing import Any, TypedDict

from dnslib import AAAA, NS, QTYPE, RCODE, RR, SOA, A, DNSError, DNSRecord

# Linux IP_FREEBIND: bind the overlay address before Nebula creates the tun
# interface (and keep the socket across Nebula restarts).
IP_FREEBIND = getattr(socket, "IP_FREEBIND", 15)
DNS_TTL = 60
SECONDS_PER_DAY = 86400

SCHEMA = """
CREATE TABLE IF NOT EXISTS peers (
    network TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    name TEXT NOT NULL,
    vpn_addrs TEXT NOT NULL,
    groups TEXT NOT NULL,
    issuer TEXT NOT NULL,
    not_before TEXT,
    not_after TEXT,
    first_seen REAL NOT NULL,
    last_seen REAL NOT NULL,
    last_underlay TEXT,
    relayed INTEGER NOT NULL DEFAULT 0,
    archived_at REAL,
    archived_by TEXT,
    PRIMARY KEY (network, fingerprint)
);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY,
    ts REAL NOT NULL,
    network TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    kind TEXT NOT NULL,
    detail TEXT
);
CREATE INDEX IF NOT EXISTS events_ts ON events (ts);
"""
# Columns added after the first release; ALTER them into older databases.
ADDED_PEER_COLUMNS = {"archived_at": "REAL", "archived_by": "TEXT"}


class PeerOnline(Exception):
    """An online peer cannot be archived: its next poll would restore it."""


def log(message: str) -> None:
    print(f"nebula-registry: {message}", file=sys.stderr, flush=True)


@dataclass(frozen=True)
class Observation:
    """One certificate seen in a poll, with how the lighthouse reaches it."""

    fingerprint: str
    name: str
    vpn_addrs: tuple[str, ...]  # certificate networks, e.g. ("10.77.0.2/24",)
    groups: tuple[str, ...]
    issuer: str
    not_before: str | None
    not_after: str | None
    underlay: str | None
    relayed: bool


def _certificate(
    cert: dict[str, Any], underlay: str | None, relayed: bool
) -> Observation:
    details = cert.get("details") or {}
    # v2 certificates call them networks; v1 JSON used ips.
    networks = details.get("networks") or details.get("ips") or []
    return Observation(
        fingerprint=cert["fingerprint"],
        name=details.get("name", ""),
        vpn_addrs=tuple(networks),
        groups=tuple(details.get("groups") or ()),
        issuer=details.get("issuer", ""),
        not_before=details.get("notBefore"),
        not_after=details.get("notAfter"),
        underlay=underlay,
        relayed=relayed,
    )


def parse_hostmap(output: str) -> list[Observation]:
    """Parse `list-hostmap -json`: every peer with a live tunnel."""
    observations = []
    for entry in json.loads(output) or []:
        cert = entry.get("cert")
        if not cert:
            continue
        remote = entry.get("currentRemote") or None
        if remote == "invalid AddrPort":
            remote = None
        relayed = bool(entry.get("currentRelaysToMe"))
        observations.append(_certificate(cert, remote, relayed))
    return observations


def parse_self(output: str) -> Observation:
    """Parse `print-cert -json` without an address: the lighthouse's own cert."""
    cert = json.loads(output)
    if isinstance(cert, list):
        cert = cert[0]
    return _certificate(cert, None, False)


def dns_label(name: str) -> str | None:
    label = re.sub(r"[^a-z0-9-]+", "-", name.lower()).strip("-")[:63].strip("-")
    return label or None


def addresses(vpn_addrs: list[str] | tuple[str, ...]) -> list[str]:
    return [str(ipaddress.ip_interface(network).ip) for network in vpn_addrs]


class Registry:
    """Permanent peer history.

    The poll thread records observations; HTTPS threads archive and restore.
    Every database access and snapshot publication holds `lock`.
    """

    def __init__(self, db: sqlite3.Connection, offline_after: float) -> None:
        self.db = db
        self.offline_after = offline_after
        self.lock = threading.RLock()
        db.executescript(SCHEMA)
        present = {row[1] for row in db.execute("PRAGMA table_info(peers)")}
        with db:
            for column, kind in ADDED_PEER_COLUMNS.items():
                if column not in present:
                    db.execute(f"ALTER TABLE peers ADD COLUMN {column} {kind}")
        # Liveness survives restarts: it is the latest online/offline event.
        self.online: dict[tuple[str, str], bool] = {
            (network, fingerprint): kind == "online"
            for network, fingerprint, kind in db.execute(
                """
                SELECT network, fingerprint, kind FROM events
                WHERE id IN (
                    SELECT max(id) FROM events
                    WHERE kind IN ('online', 'offline')
                    GROUP BY network, fingerprint
                )
                """
            )
        }

    def _event(
        self,
        now: float,
        network: str,
        fingerprint: str,
        kind: str,
        detail: str | None = None,
    ) -> None:
        self.db.execute(
            "INSERT INTO events (ts, network, fingerprint, kind, detail) VALUES (?, ?, ?, ?, ?)",
            (now, network, fingerprint, kind, detail),
        )

    def record(self, network: str, observations: list[Observation], now: float) -> None:
        with self.lock, self.db:
            for obs in {o.fingerprint: o for o in observations}.values():
                row = self.db.execute(
                    "SELECT last_underlay, archived_at FROM peers WHERE network = ? AND fingerprint = ?",
                    (network, obs.fingerprint),
                ).fetchone()
                if row is None:
                    self.db.execute(
                        """
                        INSERT INTO peers (network, fingerprint, name, vpn_addrs, groups, issuer,
                            not_before, not_after, first_seen, last_seen, last_underlay, relayed)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            network,
                            obs.fingerprint,
                            obs.name,
                            json.dumps(list(obs.vpn_addrs)),
                            json.dumps(list(obs.groups)),
                            obs.issuer,
                            obs.not_before,
                            obs.not_after,
                            now,
                            now,
                            obs.underlay,
                            int(obs.relayed),
                        ),
                    )
                    self._event(now, network, obs.fingerprint, "first_seen", obs.name)
                    previous = self.db.execute(
                        """
                        SELECT fingerprint FROM peers
                        WHERE network = ? AND name = ? AND fingerprint != ?
                        ORDER BY last_seen DESC LIMIT 1
                        """,
                        (network, obs.name, obs.fingerprint),
                    ).fetchone()
                    if previous:
                        self._event(
                            now,
                            network,
                            obs.fingerprint,
                            "cert_changed",
                            f"replaces {previous[0]}",
                        )
                else:
                    last_underlay, archived_at = row
                    if archived_at is not None:
                        self._set_archived(network, obs.fingerprint, None, None)
                        self._event(
                            now, network, obs.fingerprint, "restored", "reconnected"
                        )
                    if obs.underlay and last_underlay and obs.underlay != last_underlay:
                        self._event(
                            now,
                            network,
                            obs.fingerprint,
                            "address_changed",
                            f"{last_underlay} -> {obs.underlay}",
                        )
                    self.db.execute(
                        """
                        UPDATE peers SET last_seen = ?, last_underlay = coalesce(?, last_underlay), relayed = ?
                        WHERE network = ? AND fingerprint = ?
                        """,
                        (now, obs.underlay, int(obs.relayed), network, obs.fingerprint),
                    )
                if not self.online.get((network, obs.fingerprint)):
                    self._event(now, network, obs.fingerprint, "online", obs.underlay)
                    self.online[(network, obs.fingerprint)] = True

    def sweep(self, network: str, now: float) -> None:
        """Mark peers offline once they miss the configured number of polls."""
        with self.lock, self.db:
            for fingerprint, last_seen in self.db.execute(
                "SELECT fingerprint, last_seen FROM peers WHERE network = ?", (network,)
            ).fetchall():
                key = (network, fingerprint)
                if self.online.get(key) and now - last_seen > self.offline_after:
                    self._event(now, network, fingerprint, "offline", None)
                    self.online[key] = False

    def prune(self, now: float, retention_days: int) -> None:
        with self.lock, self.db:
            self.db.execute(
                "DELETE FROM events WHERE ts < ?",
                (now - retention_days * SECONDS_PER_DAY,),
            )

    def _set_archived(
        self, network: str, fingerprint: str, at: float | None, by: str | None
    ) -> None:
        self.db.execute(
            "UPDATE peers SET archived_at = ?, archived_by = ? WHERE network = ? AND fingerprint = ?",
            (at, by, network, fingerprint),
        )

    def _archived_at(self, network: str, fingerprint: str) -> float | None:
        row = self.db.execute(
            "SELECT archived_at FROM peers WHERE network = ? AND fingerprint = ?",
            (network, fingerprint),
        ).fetchone()
        if row is None:
            raise LookupError(fingerprint)
        return row[0]

    def archive(self, network: str, fingerprint: str, by: str, now: float) -> None:
        """Hide a certificate from the peer view and DNS; its history stays."""
        with self.lock, self.db:
            archived_at = self._archived_at(network, fingerprint)
            if self.online.get((network, fingerprint)):
                raise PeerOnline(fingerprint)
            if archived_at is None:
                self._set_archived(network, fingerprint, now, by)
                self._event(now, network, fingerprint, "archived", by)

    def restore(self, network: str, fingerprint: str, by: str, now: float) -> None:
        with self.lock, self.db:
            if self._archived_at(network, fingerprint) is not None:
                self._set_archived(network, fingerprint, None, None)
                self._event(now, network, fingerprint, "restored", by)

    def peers(self, network: str) -> list[dict[str, Any]]:
        with self.lock:
            rows = self.db.execute(
                """
                SELECT fingerprint, name, vpn_addrs, groups, issuer, not_before, not_after,
                    first_seen, last_seen, last_underlay, relayed, archived_at, archived_by
                FROM peers WHERE network = ? ORDER BY name, last_seen
                """,
                (network,),
            ).fetchall()
            online = dict(self.online)
        return [
            {
                "fingerprint": fingerprint,
                "name": name,
                "vpn_addrs": json.loads(vpn_addrs),
                "groups": json.loads(groups),
                "issuer": issuer,
                "not_before": not_before,
                "not_after": not_after,
                "first_seen": first_seen,
                "last_seen": last_seen,
                "last_underlay": last_underlay,
                "relayed": bool(relayed),
                "online": online.get((network, fingerprint), False),
                "archived_at": archived_at,
                "archived_by": archived_by,
            }
            for (
                fingerprint,
                name,
                vpn_addrs,
                groups,
                issuer,
                not_before,
                not_after,
                first_seen,
                last_seen,
                last_underlay,
                relayed,
                archived_at,
                archived_by,
            ) in rows
        ]

    def publish(self, network: str, state: State, now: float) -> None:
        """Swap in a fresh snapshot; holding the lock keeps snapshots in write order."""
        with self.lock:
            peers = self.peers(network)
            state.set(network, Snapshot(peers, dns_records(peers), int(now)))


def dns_records(peers: list[dict[str, Any]]) -> dict[str, list[str]]:
    """Map DNS labels to addresses; the most recently seen certificate wins.

    Archived certificates no longer answer.
    """
    records: dict[str, list[str]] = {}
    for peer in sorted(peers, key=lambda p: p["last_seen"]):
        label = dns_label(peer["name"])
        if label and not peer.get("archived_at"):
            records[label] = addresses(peer["vpn_addrs"])
    return records


@dataclass(frozen=True)
class Snapshot:
    peers: list[dict[str, Any]]
    records: dict[str, list[str]]
    serial: int


@dataclass(frozen=True)
class Zone:
    domain: str
    address: str  # the lighthouse's overlay address on this network
    site: str | None  # HTTPS site name, answered with `address` on every network
    aliases: tuple[str, ...] = ()


def _zone_domain(qname: str, zone: Zone) -> str | None:
    domain = zone.domain.lower()
    if qname == domain or qname.endswith("." + domain):
        return domain
    for candidate in zone.aliases:
        domain = candidate.lower()
        if qname == domain or qname.endswith("." + domain):
            return domain
    return None


def is_local(query: DNSRecord, zone: Zone) -> bool:
    """Whether the registry answers this query itself (the zone or the site)."""
    qname = str(query.q.qname).rstrip(".").lower()
    return _zone_domain(qname, zone) is not None or bool(
        zone.site and qname == zone.site.lower()
    )


def _recv_exact(sock: socket.socket, size: int) -> bytes:
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise OSError("upstream closed the connection")
        data += chunk
    return data


def forward(data: bytes, upstreams: list[tuple[str, int]], tcp: bool) -> bytes | None:
    """Relay a raw query to the first upstream that answers, over the client's transport.

    Clients without split DNS (e.g. Mobile Nebula without match domains) send
    every lookup here; forwarding keeps ordinary names working for them.
    """
    for host, port in upstreams:
        family = (
            socket.AF_INET6
            if ipaddress.ip_address(host).version == 6
            else socket.AF_INET
        )
        try:
            if tcp:
                with socket.socket(family, socket.SOCK_STREAM) as sock:
                    sock.settimeout(3)
                    sock.connect((host, port))
                    sock.sendall(len(data).to_bytes(2, "big") + data)
                    return _recv_exact(
                        sock, int.from_bytes(_recv_exact(sock, 2), "big")
                    )
            with socket.socket(family, socket.SOCK_DGRAM) as sock:
                sock.settimeout(2)
                sock.sendto(data, (host, port))
                response, _ = sock.recvfrom(65535)
                return response
        except OSError:
            continue
    return None


def answer(query: DNSRecord, zone: Zone, snapshot: Snapshot) -> DNSRecord:
    reply = query.reply()
    qname = str(query.q.qname).rstrip(".").lower()
    qtype = query.q.qtype
    domain = _zone_domain(qname, zone)
    primary_domain = domain or zone.domain.lower()
    primary = f"{zone.site or 'ns.' + primary_domain}."
    soa = RR(
        f"{primary_domain}.",
        QTYPE.SOA,
        ttl=DNS_TTL,
        rdata=SOA(
            primary,
            f"hostmaster.{primary_domain}.",
            (snapshot.serial, 3600, 600, 86400, DNS_TTL),
        ),
    )

    if zone.site and qname == zone.site.lower():
        found: list[str] | None = [zone.address]
    elif domain is not None and qname == domain:
        if qtype in (QTYPE.SOA, QTYPE.ANY):
            reply.add_answer(soa)
        if qtype in (QTYPE.NS, QTYPE.ANY):
            reply.add_answer(RR(f"{domain}.", QTYPE.NS, ttl=DNS_TTL, rdata=NS(primary)))
        if not reply.rr:
            reply.add_auth(soa)
        return reply
    elif domain is not None and qname.endswith("." + domain):
        label = qname[: -len(domain) - 1]
        found = None if "." in label else snapshot.records.get(label)
        if found is None:
            reply.header.rcode = RCODE.NXDOMAIN
            reply.add_auth(soa)
            return reply
    else:
        reply.header.aa = 0
        reply.header.rcode = RCODE.REFUSED
        return reply

    for address in found:
        ip = ipaddress.ip_address(address)
        if ip.version == 4 and qtype in (QTYPE.A, QTYPE.ANY):
            reply.add_answer(RR(query.q.qname, QTYPE.A, ttl=DNS_TTL, rdata=A(address)))
        elif ip.version == 6 and qtype in (QTYPE.AAAA, QTYPE.ANY):
            reply.add_answer(
                RR(query.q.qname, QTYPE.AAAA, ttl=DNS_TTL, rdata=AAAA(address))
            )
    if not reply.rr:
        reply.add_auth(soa)
    return reply


def find_caller(peers: list[dict[str, Any]], source: str) -> dict[str, Any] | None:
    matches = [p for p in peers if source in addresses(p["vpn_addrs"])]
    matches.sort(key=lambda p: (p["online"], p["last_seen"]))
    return matches[-1] if matches else None


def visible_peers(
    peers: list[dict[str, Any]], caller: dict[str, Any]
) -> list[dict[str, Any]]:
    """Peers with an address inside any network of the caller's certificate."""
    prefixes = [
        ipaddress.ip_network(network, strict=False) for network in caller["vpn_addrs"]
    ]
    return [
        peer
        for peer in peers
        if any(
            ipaddress.ip_address(a) in prefix
            for a in addresses(peer["vpn_addrs"])
            for prefix in prefixes
        )
    ]


def annotate(peers: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Copy each peer with the identity collisions among `peers`.

    - `superseded_by`: the newest certificate (by first sighting) carrying the
      same name, when this one was first seen earlier: a rotation or reissue.
    - `duplicates`: other certificates with the same name online right now:
      one identity in use on several machines, or a rotation whose old
      certificate is still deployed somewhere.
    - `shares_address`: unarchived certificates with a different name that
      hold one of this certificate's overlay addresses.
    """
    by_name: dict[str, list[dict[str, Any]]] = {}
    holders: dict[str, list[dict[str, Any]]] = {}
    for peer in peers:
        by_name.setdefault(peer["name"], []).append(peer)
        if not peer.get("archived_at"):
            for address in addresses(peer["vpn_addrs"]):
                holders.setdefault(address, []).append(peer)
    annotated = []
    for peer in peers:
        same_name = by_name[peer["name"]]
        newest = max(same_name, key=lambda p: p["first_seen"])
        duplicates = (
            [
                p["fingerprint"]
                for p in same_name
                if p["online"] and p["fingerprint"] != peer["fingerprint"]
            ]
            if peer["online"]
            else []
        )
        shares = (
            []
            if peer.get("archived_at")
            else sorted(
                {
                    (address, other["name"])
                    for address in addresses(peer["vpn_addrs"])
                    for other in holders.get(address, ())
                    if other["name"] != peer["name"]
                }
            )
        )
        annotated.append(
            {
                **peer,
                "superseded_by": newest["fingerprint"]
                if newest["first_seen"] > peer["first_seen"]
                else None,
                "duplicates": duplicates,
                "shares_address": [{"address": a, "name": n} for a, n in shares],
            }
        )
    return annotated


def can_manage(caller: dict[str, Any], admin_groups: frozenset[str]) -> bool:
    """Only a connected certificate's groups count, never a stale row's."""
    return bool(caller["online"] and admin_groups.intersection(caller["groups"]))


def same_origin(origin: str | None, host: str | None) -> bool:
    """Reject cross-site form posts: a browser always sends Origin on POST.

    HTTPS makes the Host trustworthy here: a rebinding name would fail the
    certificate check before any request is sent.
    """
    return bool(origin and host and origin.lower() == f"https://{host.lower()}")


def _utc(ts: float) -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(ts))


def _ago(seconds: float) -> str:
    seconds = max(0, int(seconds))
    if seconds < 5:
        return "just now"
    for size, unit in ((86400, "d"), (3600, "h"), (60, "m")):
        if seconds >= size:
            return f"{seconds // size} {unit} ago"
    return f"{seconds} s ago"


def _expiry(not_after: str | None, now: float) -> tuple[float, str, str]:
    """(sort key, label, css class) for a certificate's notAfter."""
    if not not_after:
        return (0, "—", "")
    try:
        expires = dt.datetime.fromisoformat(not_after).timestamp()
    except ValueError:
        return (0, html.escape(not_after), "")
    days = int((expires - now) // 86400)
    level = "bad" if days < 7 else "warn" if days < 30 else ""
    return (
        expires,
        f"{time.strftime('%Y-%m-%d', time.gmtime(expires))} <small>{days} d</small>",
        level,
    )


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>@NETWORK@ · Nebula</title>
<script>
// Apply a saved theme before first paint; without one the page follows the system.
(() => {
  const theme = localStorage.getItem("nebula-theme");
  if (theme === "light" || theme === "dark") document.documentElement.dataset.theme = theme;
})();
</script>
<style>
:root {
  color-scheme: light;
  --bg: #f4f6f8; --card: #ffffff; --text: #17202a; --muted: #6b7785; --line: #e3e8ee;
  --accent: #2f6fed; --ok: #1f9d55; --ok-bg: #e3f6eb; --off: #8a94a0; --off-bg: #eef1f4;
  --relay: #b7791f; --relay-bg: #fdf3e1; --warn: #b7791f; --bad: #c53030; --hover: #f7f9fc;
  --mono: ui-monospace, "SF Mono", "JetBrains Mono", Menlo, monospace;
}
:root[data-theme=dark] {
  color-scheme: dark;
  --bg: #0e1116; --card: #161b22; --text: #e6edf3; --muted: #8b949e; --line: #262d36;
  --accent: #6ea8ff; --ok: #3fb950; --ok-bg: #12301d; --off: #8b949e; --off-bg: #21262d;
  --relay: #e3b341; --relay-bg: #3a2d0c; --warn: #e3b341; --bad: #f85149; --hover: #1c232c;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme=light]) {
    color-scheme: dark;
    --bg: #0e1116; --card: #161b22; --text: #e6edf3; --muted: #8b949e; --line: #262d36;
    --accent: #6ea8ff; --ok: #3fb950; --ok-bg: #12301d; --off: #8b949e; --off-bg: #21262d;
    --relay: #e3b341; --relay-bg: #3a2d0c; --warn: #e3b341; --bad: #f85149; --hover: #1c232c;
  }
}
.toolbar { display: flex; flex-wrap: wrap; justify-content: space-between; gap: .75rem; margin-bottom: 1rem; }
.segmented { display: inline-flex; gap: .15rem; padding: .2rem; background: var(--card); border: 1px solid var(--line);
  border-radius: 999px; }
.segmented button { font: inherit; font-size: .8rem; color: var(--muted); background: transparent; border: 0;
  border-radius: 999px; padding: .3rem .75rem; cursor: pointer; }
.segmented button:hover { color: var(--text); }
.segmented button[aria-pressed=true] { color: var(--text); background: var(--off-bg); font-weight: 600; }
.segmented button:focus-visible, th:focus-visible, .action:focus-visible { outline: 2px solid var(--accent);
  outline-offset: 2px; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text);
  font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }
main { max-width: 1360px; margin: 0 auto; padding: 2.5rem 1.5rem 3rem; }
header { display: flex; flex-wrap: wrap; align-items: flex-end; justify-content: space-between; gap: 1rem;
  margin-bottom: 1.5rem; }
h1 { margin: 0; font-size: 1.9rem; letter-spacing: -0.02em; }
h1 span { color: var(--muted); font-weight: 500; }
.viewer { margin: .35rem 0 0; color: var(--muted); }
.viewer strong { color: var(--text); }
.stats { display: flex; gap: .6rem; }
.stat { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: .55rem .9rem;
  min-width: 6.5rem; }
.stat b { display: block; font-size: 1.35rem; line-height: 1.2; }
.stat small { color: var(--muted); }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 16px; overflow: hidden;
  box-shadow: 0 1px 2px rgba(0,0,0,.04), 0 8px 24px rgba(0,0,0,.04); }
table { width: 100%; border-collapse: collapse; }
th, td { padding: .75rem .85rem; text-align: left; white-space: nowrap; }
td.c-name, td.c-underlay { white-space: normal; }
.tags { display: inline; }
th { font-size: .75rem; text-transform: uppercase; letter-spacing: .06em; color: var(--muted);
  font-weight: 600; border-bottom: 1px solid var(--line); cursor: pointer; user-select: none; }
th:hover { color: var(--text); }
th::after { content: "\\2195"; opacity: .25; margin-left: .35em; }
th[aria-sort=ascending]::after { content: "\\2191"; opacity: 1; color: var(--accent); }
th[aria-sort=descending]::after { content: "\\2193"; opacity: 1; color: var(--accent); }
th.c-manage { cursor: default; }
th.c-manage::after { content: none; }
td { border-bottom: 1px solid var(--line); }
tbody tr:last-child td { border-bottom: 0; }
tbody tr:hover { background: var(--hover); }
tr.offline td, tr.archived td { color: var(--muted); }
#peers:not(.show-archived) tbody tr.archived, #peers.show-archived tbody tr:not(.archived) { display: none; }
.mono { font-family: var(--mono); font-size: .88rem; }
.name { font-weight: 600; }
.you { margin-left: .4rem; font-size: .7rem; font-weight: 600; color: var(--accent);
  border: 1px solid currentColor; border-radius: 999px; padding: 0 .45rem; vertical-align: 1px; }
.tag { display: inline-block; margin-left: .35rem; font-size: .72rem; color: var(--muted);
  background: var(--off-bg); border-radius: 6px; padding: 0 .4rem; }
.fp { display: block; font-family: var(--mono); font-size: .75rem; font-weight: 400; color: var(--muted); }
.flags { display: block; }
.flag { display: inline-block; margin: .25rem .35rem 0 0; font-size: .72rem; font-weight: 600; color: var(--warn);
  background: var(--relay-bg); border-radius: 6px; padding: 0 .4rem; }
.flag.bad { color: var(--bad); background: transparent; border: 1px solid currentColor; }
.since { display: block; font-size: .75rem; }
.action { font: inherit; font-size: .8rem; color: var(--text); background: var(--card); border: 1px solid var(--line);
  border-radius: 8px; padding: .25rem .7rem; cursor: pointer; }
.action:hover:not(:disabled) { color: var(--accent); border-color: var(--accent); }
.action:disabled { opacity: .45; cursor: not-allowed; }
.pill { display: inline-flex; align-items: center; gap: .4rem; font-size: .8rem; font-weight: 600;
  border-radius: 999px; padding: .15rem .6rem; }
.pill.online { color: var(--ok); background: var(--ok-bg); }
.pill.offline { color: var(--off); background: var(--off-bg); }
.pill.direct { color: var(--accent); background: transparent; border: 1px solid var(--line); }
.pill.relayed { color: var(--relay); background: var(--relay-bg); }
.pill.archived { color: var(--off); background: transparent; border: 1px dashed var(--off); }
.dot { width: .5rem; height: .5rem; border-radius: 50%; background: currentColor; }
.online .dot { animation: pulse 2.4s infinite; }
@keyframes pulse { 0% { box-shadow: 0 0 0 0 rgba(31,157,85,.45); } 70% { box-shadow: 0 0 0 7px rgba(31,157,85,0); }
  100% { box-shadow: 0 0 0 0 rgba(31,157,85,0); } }
small { color: var(--muted); }
.warn { color: var(--warn); font-weight: 600; }
.bad { color: var(--bad); font-weight: 600; }
footer { margin-top: 1rem; color: var(--muted); font-size: .82rem; text-align: right; }
footer a { color: var(--accent); }
#action-state:not(:empty)::after { content: " · "; color: var(--muted); }
.sort-mobile { display: none; }
.sort-mobile select { font: inherit; color: var(--text); background: var(--card); border: 1px solid var(--line);
  border-radius: 10px; padding: .45rem .7rem; }
/* Medium screens: drop the least important columns instead of scrolling. */
@media (max-width: 1200px) { .c-first { display: none; } }
@media (max-width: 1040px) { .c-underlay { display: none; } }
/* Phones: one card per peer, labeled fields, sorting from a menu. */
@media (max-width: 880px) {
  main { padding: 1.25rem 1rem 2rem; }
  h1 { font-size: 1.5rem; }
  header { align-items: stretch; }
  .stats { width: 100%; }
  .stat { flex: 1; min-width: 0; }
  .sort-mobile { display: flex; align-items: center; justify-content: space-between; gap: .75rem;
    color: var(--muted); margin: 0 0 .75rem; }
  .card { background: transparent; border: 0; box-shadow: none; border-radius: 0; overflow: visible; }
  table, tbody { display: block; }
  thead { display: none; }
  tbody tr { display: grid; grid-template-columns: 1fr 1fr; gap: .6rem 1rem; background: var(--card);
    border: 1px solid var(--line); border-radius: 14px; padding: .9rem 1rem; margin-bottom: .75rem; }
  tbody tr:hover { background: var(--card); }
  td { display: block; padding: 0; border: 0; white-space: normal; min-width: 0; overflow-wrap: anywhere; }
  td::before { content: attr(data-label); display: block; font-size: .68rem; font-weight: 600;
    text-transform: uppercase; letter-spacing: .06em; color: var(--muted); margin-bottom: .1rem; }
  td.c-name { grid-column: 1 / -1; font-size: 1.05rem; }
  td.c-name::before, td.c-manage::before { content: none; }
  td.c-manage { grid-column: 1 / -1; }
  td.c-first, td.c-underlay { display: block; }
  td.c-underlay { grid-column: 1 / -1; }
}
@media (prefers-reduced-motion: reduce) { .online .dot { animation: none; } }
</style></head>
<body><main>
<div class="toolbar">
  <div class="segmented" role="group" aria-label="Peers shown">
    <button type="button" data-view="active">Active</button>
    <button type="button" data-view="archived">Archived <span id="archived-count">@ARCHIVED@</span></button>
  </div>
  <div class="segmented" role="group" aria-label="Color theme">
    <button type="button" data-theme-choice="system">System</button>
    <button type="button" data-theme-choice="light">Light</button>
    <button type="button" data-theme-choice="dark">Dark</button>
  </div>
</div>
<header>
  <div>
    <h1><span>Nebula /</span> @NETWORK@</h1>
    <p class="viewer">Viewing as <strong>@CALLER@</strong> <span class="mono">@CALLER_NETS@</span></p>
  </div>
  <div class="stats">
    <div class="stat"><b id="online-count">@ONLINE@</b><small>online</small></div>
    <div class="stat"><b id="peer-count">@TOTAL@</b><small>known peers</small></div>
    <div class="stat"><b id="relayed-count">@RELAYED@</b><small>relayed</small></div>
  </div>
</header>
<label class="sort-mobile">Sort by
  <select id="sort-select">
    <option value="2:descending">State (online first)</option>
    <option value="0:ascending">Name</option>
    <option value="3:descending">Last seen (newest)</option>
    <option value="4:ascending">First seen (oldest)</option>
    <option value="1:ascending">Overlay IP</option>
    <option value="7:ascending">Cert expires (soonest)</option>
  </select>
</label>
<div class="card"><table id="peers">
<thead><tr>
  <th data-type="text" class="c-name">Name</th><th data-type="num" class="c-ip">Overlay IP</th>
  <th data-type="num" class="c-state">State</th><th data-type="num" class="c-last">Last seen</th>
  <th data-type="num" class="c-first">First seen</th><th data-type="text" class="c-underlay">Underlay</th>
  <th data-type="text" class="c-path">Path</th><th data-type="num" class="c-cert">Cert expires</th>@MANAGE_HEADER@
</tr></thead>
<tbody>
@ROWS@
</tbody></table></div>
<footer><span id="action-state" class="bad" role="status"></span><span id="update-state">Rendered @RENDERED@</span> · updates every second · <a href="/api/peers">JSON</a></footer>
</main>
<script>
(() => {
  const table = document.getElementById("peers");
  const headers = [...table.tHead.rows[0].cells];
  const sortBy = (index, direction) => {
    const type = headers[index].dataset.type;
    const rows = [...table.tBodies[0].rows];
    const key = (row) => row.cells[index].dataset.sort ?? row.cells[index].textContent;
    rows.sort((a, b) => {
      const [x, y] = [key(a), key(b)];
      const order = type === "num" ? Number(x) - Number(y) : x.localeCompare(y, undefined, { numeric: true });
      return direction === "ascending" ? order : -order;
    });
    table.tBodies[0].append(...rows);
    headers.forEach((h, i) => h.setAttribute("aria-sort", i === index ? direction : "none"));
    sessionStorage.setItem("nebula-sort", JSON.stringify([index, direction]));
    const option = select.querySelector(`option[value="${index}:${direction}"]`);
    if (option) select.value = option.value;
  };
  const select = document.getElementById("sort-select");
  select.addEventListener("change", () => {
    const [index, direction] = select.value.split(":");
    sortBy(Number(index), direction);
  });
  headers.forEach((th, index) => {
    if (!th.dataset.type) return;
    th.addEventListener("click", () => {
      const next = th.getAttribute("aria-sort") === "ascending" ? "descending" : "ascending";
      sortBy(index, next);
    });
  });
  const saved = JSON.parse(sessionStorage.getItem("nebula-sort") || "null");
  if (saved) sortBy(...saved);

  const viewButtons = [...document.querySelectorAll("[data-view]")];
  const applyView = (view) => {
    table.classList.toggle("show-archived", view === "archived");
    viewButtons.forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.view === view)));
    sessionStorage.setItem("nebula-view", view);
  };
  viewButtons.forEach((b) => b.addEventListener("click", () => applyView(b.dataset.view)));
  applyView(sessionStorage.getItem("nebula-view") || "active");

  const updateState = document.getElementById("update-state");
  const actionState = document.getElementById("action-state");
  const load = async () => {
    const response = await fetch("/api/status", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const status = await response.json();
    table.tBodies[0].innerHTML = status.rows;
    document.getElementById("online-count").textContent = String(status.online);
    document.getElementById("peer-count").textContent = String(status.total);
    document.getElementById("relayed-count").textContent = String(status.relayed);
    document.getElementById("archived-count").textContent = String(status.archived);
    updateState.textContent = `Rendered ${status.rendered}`;
    const sorted = headers.findIndex((header) => header.getAttribute("aria-sort") !== "none");
    if (sorted >= 0) sortBy(sorted, headers[sorted].getAttribute("aria-sort"));
  };
  const refresh = async () => {
    try {
      await load();
    } catch {
      updateState.textContent = "Live update failed; retrying";
    } finally {
      setTimeout(refresh, 1000);
    }
  };
  setTimeout(refresh, 1000);

  table.tBodies[0].addEventListener("click", async (event) => {
    const button = event.target.closest("button[data-action]");
    if (!button) return;
    const { action, fingerprint } = button.dataset;
    button.disabled = true;
    try {
      const response = await fetch(`/api/${action}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ fingerprint }),
      });
      if (!response.ok) throw new Error((await response.text()).trim() || `HTTP ${response.status}`);
      actionState.textContent = "";
      await load();
    } catch (error) {
      actionState.textContent = `Could not ${action}: ${error.message}`;
      button.disabled = false;
    }
  });

  const themeButtons = [...document.querySelectorAll("[data-theme-choice]")];
  const applyTheme = (choice) => {
    if (choice === "system") {
      delete document.documentElement.dataset.theme;
      localStorage.removeItem("nebula-theme");
    } else {
      document.documentElement.dataset.theme = choice;
      localStorage.setItem("nebula-theme", choice);
    }
    themeButtons.forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.themeChoice === choice)));
  };
  themeButtons.forEach((b) => b.addEventListener("click", () => applyTheme(b.dataset.themeChoice)));
  applyTheme(localStorage.getItem("nebula-theme") || "system");
})();
</script>
</body></html>
"""


class StatusUpdate(TypedDict):
    online: int
    total: int
    relayed: int
    archived: int
    rendered: str
    rows: str


COLUMNS = [
    ("name", "Name"),
    ("ip", "Overlay IP"),
    ("state", "State"),
    ("last", "Last seen"),
    ("first", "First seen"),
    ("underlay", "Underlay"),
    ("path", "Path"),
    ("cert", "Cert expires"),
]
MANAGE_HEADER = '<th class="c-manage">Manage</th>'


def _short(fingerprint: str) -> str:
    return fingerprint[:12]


def _flags(peer: dict[str, Any]) -> str:
    """Badges for the collisions `annotate` found."""
    e = html.escape
    flags = []
    if peer.get("duplicates"):
        others = ", ".join(_short(fp) for fp in peer["duplicates"])
        flags.append(
            f'<span class="flag bad" title="Another certificate named {e(peer["name"])} is online at the same time">'
            f"duplicate · also online: {e(others)}</span>"
        )
    if peer.get("superseded_by"):
        flags.append(
            f'<span class="flag" title="A newer certificate {e(peer["superseded_by"])} carries this name">'
            f"superseded by {e(_short(peer['superseded_by']))}</span>"
        )
    for share in peer.get("shares_address") or []:
        flags.append(
            f'<span class="flag bad" title="Another unarchived certificate holds this overlay address">'
            f"{e(share['address'])} also held by {e(share['name'])}</span>"
        )
    return f'<span class="flags">{"".join(flags)}</span>' if flags else ""


def render_status(
    caller: dict[str, Any],
    peers: list[dict[str, Any]],
    now: float | None = None,
    manage: bool = False,
) -> StatusUpdate:
    """Rows for every visible peer; the page hides archived or active ones."""
    now = time.time() if now is None else now
    e = html.escape
    rows = []
    ordered = sorted(peers, key=lambda p: (not p["online"], p["name"]))
    for peer in ordered:
        fingerprint = peer["fingerprint"]
        archived_at = peer.get("archived_at")
        state = "archived" if archived_at else "online" if peer["online"] else "offline"
        path = "relayed" if peer["relayed"] else "direct"
        overlay = addresses(peer["vpn_addrs"])
        overlay_key = int(ipaddress.ip_address(overlay[0])) if overlay else 0
        you = (
            '<span class="you">you</span>'
            if fingerprint == caller.get("fingerprint")
            else ""
        )
        tags = "".join(
            f'<span class="tag">{e(g)}</span>' for g in peer.get("groups") or []
        )
        if archived_at:
            by = peer.get("archived_by") or "unknown"
            state_cell = (
                f'<span class="pill archived" title="Archived {_utc(archived_at)} by {e(by)}">archived</span>'
                f'<small class="since">{time.strftime("%Y-%m-%d", time.gmtime(archived_at))} · {e(by)}</small>'
            )
        else:
            state_cell = (
                f'<span class="pill {state}"><span class="dot"></span>{state}</span>'
            )
        expiry_key, expiry_label, expiry_class = _expiry(peer.get("not_after"), now)
        cells = [
            (
                e(peer["name"]),
                f'<span class="name">{e(peer["name"])}</span>{you}{tags}'
                f'<span class="fp" title="{e(fingerprint)}">{e(_short(fingerprint))}</span>'
                + _flags(peer),
                "",
            ),
            (str(overlay_key), e(", ".join(overlay)), "mono"),
            ("-1" if archived_at else "1" if peer["online"] else "0", state_cell, ""),
            (
                str(peer["last_seen"]),
                f'<span title="{_utc(peer["last_seen"])}">{_ago(now - peer["last_seen"])}</span>',
                "",
            ),
            (
                str(peer["first_seen"]),
                f'<span title="{_utc(peer["first_seen"])}">{time.strftime("%Y-%m-%d", time.gmtime(peer["first_seen"]))}</span>',
                "",
            ),
            (e(peer["last_underlay"] or ""), e(peer["last_underlay"] or "—"), "mono"),
            (path, f'<span class="pill {path}">{path}</span>', ""),
            (str(expiry_key), expiry_label, expiry_class),
        ]
        row = "".join(
            f'<td data-sort="{key}" data-label="{label}" class="c-{column} {css}">{content}</td>'
            for (column, label), (key, content, css) in zip(COLUMNS, cells, strict=True)
        )
        if manage:
            if archived_at:
                button = f'<button type="button" class="action" data-action="restore" data-fingerprint="{e(fingerprint)}">Restore</button>'
            elif peer["online"]:
                button = '<button type="button" class="action" disabled title="Online certificates cannot be archived">Archive</button>'
            else:
                button = f'<button type="button" class="action" data-action="archive" data-fingerprint="{e(fingerprint)}">Archive</button>'
            row += f'<td class="c-manage">{button}</td>'
        rows.append(f'<tr class="{state}">{row}</tr>')
    active = [p for p in peers if not p.get("archived_at")]
    return {
        "online": sum(p["online"] for p in active),
        "total": len(active),
        "relayed": sum(p["relayed"] and p["online"] for p in active),
        "archived": len(peers) - len(active),
        "rendered": _utc(now),
        "rows": "\n".join(rows),
    }


def render_html(
    network: str,
    caller: dict[str, Any],
    peers: list[dict[str, Any]],
    now: float | None = None,
    manage: bool = False,
) -> str:
    status = render_status(caller, peers, now, manage)
    replacements = {
        "@NETWORK@": html.escape(network),
        "@CALLER@": html.escape(caller["name"]),
        "@CALLER_NETS@": html.escape(", ".join(caller["vpn_addrs"])),
        "@ONLINE@": str(status["online"]),
        "@TOTAL@": str(status["total"]),
        "@RELAYED@": str(status["relayed"]),
        "@ARCHIVED@": str(status["archived"]),
        "@MANAGE_HEADER@": MANAGE_HEADER if manage else "",
        "@RENDERED@": str(status["rendered"]),
        "@ROWS@": str(status["rows"]),
    }
    page = PAGE
    for marker, value in replacements.items():
        page = page.replace(marker, value)
    return page


class State:
    """Latest snapshot per network, swapped atomically by the poll thread."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._snapshots: dict[str, Snapshot] = {}

    def set(self, network: str, snapshot: Snapshot) -> None:
        with self._lock:
            self._snapshots[network] = snapshot

    def get(self, network: str) -> Snapshot:
        with self._lock:
            return self._snapshots.get(network, Snapshot([], {}, 1))


def _freebind(sock: socket.socket) -> None:
    sock.setsockopt(socket.IPPROTO_IP, IP_FREEBIND, 1)


class DnsUdpServer(socketserver.ThreadingUDPServer):
    daemon_threads = True

    def server_bind(self) -> None:
        _freebind(self.socket)
        super().server_bind()


class DnsTcpServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self) -> None:
        _freebind(self.socket)
        super().server_bind()


def dns_handler(
    network: str, zone: Zone, state: State, tcp: bool, upstreams: list[tuple[str, int]]
) -> type[socketserver.BaseRequestHandler]:
    def respond(data: bytes) -> bytes | None:
        try:
            query = DNSRecord.parse(data)
        except DNSError:
            return None
        if upstreams and not is_local(query, zone):
            forwarded = forward(data, upstreams, tcp)
            if forwarded is not None:
                return forwarded
            failed = query.reply()
            failed.header.aa = 0
            failed.header.rcode = RCODE.SERVFAIL
            return failed.pack()
        return answer(query, zone, state.get(network)).pack()

    class UdpHandler(socketserver.BaseRequestHandler):
        def handle(self) -> None:
            data, sock = self.request
            response = respond(data)
            if response:
                sock.sendto(response, self.client_address)

    class TcpHandler(socketserver.StreamRequestHandler):
        timeout = 10

        def handle(self) -> None:
            while True:
                length = self.rfile.read(2)
                if len(length) < 2:
                    return
                response = respond(self.rfile.read(int.from_bytes(length, "big")))
                if not response:
                    return
                self.wfile.write(len(response).to_bytes(2, "big") + response)

    return TcpHandler if tcp else UdpHandler


class HttpsServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self) -> None:
        _freebind(self.socket)
        super().server_bind()

    def handle_error(self, request: Any, client_address: Any) -> None:
        # Failed TLS handshakes and dropped clients are routine; stay quiet.
        pass


def tls_context(tls_config: dict[str, Any]) -> ssl.SSLContext:
    """Preload the default certificate and hostname-specific SNI contexts."""
    default = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    default.load_cert_chain(tls_config["certFile"], tls_config["keyFile"])
    contexts: dict[str, ssl.SSLContext] = {}
    for hostname, certificate in tls_config.get("extraCertificates", {}).items():
        context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        context.load_cert_chain(certificate["certFile"], certificate["keyFile"])
        contexts[hostname.lower()] = context

    def select_context(
        connection: ssl.SSLSocket,
        server_name: str | None,
        initial_context: ssl.SSLContext,
    ) -> None:
        if server_name is not None:
            connection.context = contexts.get(server_name.lower(), initial_context)

    default.sni_callback = select_context
    return default


MAX_ACTION_BODY = 4096


def https_handler(
    network: str, state: State, registry: Registry, admin_groups: frozenset[str]
) -> type[BaseHTTPRequestHandler]:
    """Read-only peer view for every caller; archive/restore for `admin_groups`."""

    class Handler(BaseHTTPRequestHandler):
        server_version = "nebula-registry"
        timeout = 10

        def setup(self) -> None:
            # The listening socket defers handshakes so a slow client cannot
            # stall accept(); finish it here, in this request's thread.
            self.request.settimeout(self.timeout)
            self.request.do_handshake()
            super().setup()

        def _send(self, status: int, content_type: str, body: str) -> None:
            payload = body.encode()
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)

        def _caller(self) -> tuple[Snapshot, dict[str, Any]] | None:
            snapshot = state.get(network)
            caller = find_caller(snapshot.peers, self.client_address[0])
            if caller is None:
                self._send(403, "text/plain; charset=utf-8", "unknown overlay peer\n")
                return None
            return snapshot, caller

        def do_GET(self) -> None:  # noqa: N802
            found = self._caller()
            if found is None:
                return
            snapshot, caller = found
            peers = annotate(visible_peers(snapshot.peers, caller))
            manage = can_manage(caller, admin_groups)
            path = self.path.split("?", 1)[0]
            if path == "/api/peers":
                body = json.dumps(
                    {"network": network, "caller": caller["name"], "peers": peers},
                    indent=2,
                )
                self._send(200, "application/json", body + "\n")
            elif path == "/api/status":
                self._send(
                    200,
                    "application/json",
                    json.dumps(
                        render_status(caller, peers, manage=manage),
                        separators=(",", ":"),
                    )
                    + "\n",
                )
            elif path == "/":
                self._send(
                    200,
                    "text/html; charset=utf-8",
                    render_html(network, caller, peers, manage=manage),
                )
            else:
                self._send(404, "text/plain; charset=utf-8", "not found\n")

        def do_POST(self) -> None:  # noqa: N802
            text = "text/plain; charset=utf-8"
            path = self.path.split("?", 1)[0]
            if path not in ("/api/archive", "/api/restore"):
                self._send(404, text, "not found\n")
                return
            found = self._caller()
            if found is None:
                return
            snapshot, caller = found
            if not can_manage(caller, admin_groups):
                self._send(403, text, "certificate is not a registry administrator\n")
                return
            if not same_origin(self.headers.get("Origin"), self.headers.get("Host")):
                self._send(403, text, "cross-origin request refused\n")
                return
            if self.headers.get_content_type() != "application/json":
                self._send(415, text, "expected application/json\n")
                return
            try:
                length = int(self.headers.get("Content-Length", ""))
            except ValueError:
                self._send(411, text, "Content-Length required\n")
                return
            if not 0 < length <= MAX_ACTION_BODY:
                self._send(413, text, "request body too large or empty\n")
                return
            try:
                fingerprint = json.loads(self.rfile.read(length))["fingerprint"]
            except (ValueError, TypeError, KeyError):
                self._send(400, text, 'expected {"fingerprint": "..."}\n')
                return
            visible = {p["fingerprint"] for p in visible_peers(snapshot.peers, caller)}
            if not isinstance(fingerprint, str) or fingerprint not in visible:
                self._send(404, text, "unknown certificate\n")
                return
            by = f"{caller['name']} ({_short(caller['fingerprint'])})"
            now = time.time()
            try:
                if path == "/api/archive":
                    registry.archive(network, fingerprint, by, now)
                else:
                    registry.restore(network, fingerprint, by, now)
            except PeerOnline:
                self._send(
                    409,
                    text,
                    "certificate is online; archive it after it disconnects\n",
                )
                return
            except LookupError:
                self._send(404, text, "unknown certificate\n")
                return
            registry.publish(network, state, now)
            log(f"{network}: {by} {path.rsplit('/', 1)[1]}d {fingerprint}")
            self._send(
                200,
                "application/json",
                json.dumps(
                    {"fingerprint": fingerprint, "archived": path == "/api/archive"}
                )
                + "\n",
            )

        def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
            pass

    return Handler


class Console:
    """Nebula's debug SSH console for one network, bound to localhost.

    Commands share one multiplexed SSH connection (ControlMaster), so polling
    opens a channel per command, not a connection. Nebula < 1.11 leaks every
    console connection it serves; a persistent one bounds that to one.
    """

    def __init__(
        self,
        ssh: str,
        key: Path,
        known_hosts: Path,
        control_path: Path,
        user: str,
        port: int,
    ) -> None:
        self.command = [
            ssh,
            "-F",
            "/dev/null",
            "-i",
            str(key),
            "-p",
            str(port),
            "-o",
            "BatchMode=yes",
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            f"UserKnownHostsFile={known_hosts}",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "ConnectTimeout=5",
            "-o",
            "ControlMaster=auto",
            "-o",
            f"ControlPath={control_path}",
            "-o",
            "ControlPersist=yes",
            "-o",
            "ServerAliveInterval=15",
            f"{user}@127.0.0.1",
        ]

    def run(self, *args: str) -> str:
        return subprocess.run(
            [*self.command, " ".join(args)],
            check=True,
            capture_output=True,
            text=True,
            timeout=20,
        ).stdout


def serve(server: socketserver.BaseServer) -> None:
    threading.Thread(target=server.serve_forever, daemon=True).start()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())

    state_dir = Path(config["stateDir"])
    interval = config["pollInterval"]
    # HTTPS threads write archive state too; Registry.lock serializes access.
    db = sqlite3.connect(state_dir / "registry.db", check_same_thread=False)
    db.execute("PRAGMA journal_mode=WAL")
    registry = Registry(db, offline_after=interval * config["offlineAfterPolls"])
    state = State()
    tls_config = config.get("tls")
    upstreams = [(host, 53) for host in config.get("upstreamResolvers", [])]

    tls = None
    if tls_config and (
        tls_config.get("extraCertificates") or Path(tls_config["certFile"]).exists()
    ):
        tls = tls_context(tls_config)
    elif tls_config:
        log(
            f"no certificate at {tls_config['certFile']}; HTTPS disabled until it exists"
        )

    consoles = {}
    for network, net in config["networks"].items():
        zone = Zone(
            net["domain"],
            net["address"],
            net.get("site"),
            tuple(net.get("aliases", ())),
        )
        dns_address = (net["address"], net.get("dnsPort", 53))
        serve(
            DnsUdpServer(
                dns_address,
                dns_handler(network, zone, state, tcp=False, upstreams=upstreams),
            )
        )
        serve(
            DnsTcpServer(
                dns_address,
                dns_handler(network, zone, state, tcp=True, upstreams=upstreams),
            )
        )
        if tls:
            https = HttpsServer(
                (net["address"], tls_config["port"]),
                https_handler(
                    network, state, registry, frozenset(net.get("adminGroups", ()))
                ),
            )
            https.socket = tls.wrap_socket(
                https.socket, server_side=True, do_handshake_on_connect=False
            )
            serve(https)
        consoles[network] = Console(
            config["ssh"],
            state_dir / "client_key",
            state_dir / "known_hosts",
            state_dir / f"console-{network}.sock",
            config["consoleUser"],
            net["consolePort"],
        )

    failing: set[str] = set()
    next_prune = 0.0
    while True:
        now = time.time()
        for network, console in consoles.items():
            try:
                observations = [parse_self(console.run("print-cert", "-json"))]
                observations += parse_hostmap(console.run("list-hostmap", "-json"))
            except (subprocess.SubprocessError, OSError, ValueError, KeyError) as error:
                if network not in failing:
                    detail = getattr(error, "stderr", None) or error
                    log(f"{network}: console poll failed: {str(detail).strip()}")
                    failing.add(network)
            else:
                if network in failing:
                    log(f"{network}: console poll recovered")
                    failing.discard(network)
                registry.record(network, observations, now)
            registry.sweep(network, now)
            registry.publish(network, state, now)
        if now >= next_prune:
            registry.prune(now, config["eventRetentionDays"])
            next_prune = now + 3600
        time.sleep(max(0.0, interval - (time.time() - now)))


if __name__ == "__main__":
    main()
