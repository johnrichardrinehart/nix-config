#!/usr/bin/env python3

import http.client
import json
import socket
import sqlite3
import ssl
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from typing import Any

from dnslib import QTYPE, RCODE, RR, DNSRecord

from nebula_registry import (
    HttpsServer,
    Observation,
    Registry,
    Snapshot,
    State,
    Zone,
    answer,
    dns_handler,
    dns_label,
    dns_records,
    find_caller,
    forward,
    https_handler,
    is_local,
    parse_hostmap,
    parse_self,
    render_status,
    tls_context,
    visible_peers,
)

FIXTURES = Path(__file__).parent / "fixtures"
NETWORK = "mycelium"


def observation(
    fingerprint: str, name: str, address: str, underlay: str | None = None
) -> Observation:
    return Observation(
        fingerprint=fingerprint,
        name=name,
        vpn_addrs=(address,),
        groups=("peer",),
        issuer="ca",
        not_before=None,
        not_after=None,
        underlay=underlay,
        relayed=False,
    )


def events(db: sqlite3.Connection) -> list[tuple[str, str]]:
    return [
        (fp, kind)
        for fp, kind in db.execute("SELECT fingerprint, kind FROM events ORDER BY id")
    ]


class ConsoleParsingTests(unittest.TestCase):
    def test_hostmap_yields_peer_identity_and_path(self) -> None:
        (peer,) = parse_hostmap((FIXTURES / "list-hostmap.json").read_text())
        self.assertEqual(peer.name, "framework")
        self.assertEqual(peer.vpn_addrs, ("10.77.0.2/24",))
        self.assertEqual(peer.groups, ("peer",))
        self.assertTrue(peer.underlay)
        self.assertFalse(peer.relayed)

    def test_own_certificate_has_no_underlay(self) -> None:
        own = parse_self((FIXTURES / "print-cert.json").read_text())
        self.assertEqual(own.name, "lighthouse")
        self.assertIsNone(own.underlay)

    def test_zero_remote_means_no_underlay(self) -> None:
        output = '[{"cert": {"fingerprint": "f", "details": {"name": "n", "networks": ["10.77.0.9/24"]}},'
        output += ' "currentRemote": "", "currentRelaysToMe": ["10.77.0.1"]}]'
        (peer,) = parse_hostmap(output)
        self.assertIsNone(peer.underlay)
        self.assertTrue(peer.relayed)


class LivenessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.db = sqlite3.connect(":memory:")
        self.registry = Registry(self.db, offline_after=30)
        self.peer = observation("fp1", "framework", "10.77.0.2/24", "1.2.3.4:5")

    def test_first_sighting_records_history_and_online(self) -> None:
        self.registry.record(NETWORK, [self.peer], now=100)
        self.assertEqual(events(self.db), [("fp1", "first_seen"), ("fp1", "online")])
        (peer,) = self.registry.peers(NETWORK)
        self.assertEqual(
            (peer["first_seen"], peer["last_seen"], peer["online"]), (100, 100, True)
        )

    def test_goes_offline_only_after_missed_polls_and_keeps_last_seen(self) -> None:
        self.registry.record(NETWORK, [self.peer], now=100)
        self.registry.sweep(NETWORK, now=130)
        self.assertTrue(self.registry.peers(NETWORK)[0]["online"])
        self.registry.sweep(NETWORK, now=131)
        (peer,) = self.registry.peers(NETWORK)
        self.assertFalse(peer["online"])
        self.assertEqual(peer["last_seen"], 100)
        self.assertEqual(events(self.db)[-1], ("fp1", "offline"))

    def test_return_is_online_again_not_first_seen(self) -> None:
        self.registry.record(NETWORK, [self.peer], now=100)
        self.registry.sweep(NETWORK, now=200)
        self.registry.record(NETWORK, [self.peer], now=210)
        self.assertEqual(
            events(self.db),
            [
                ("fp1", "first_seen"),
                ("fp1", "online"),
                ("fp1", "offline"),
                ("fp1", "online"),
            ],
        )
        self.assertEqual(self.registry.peers(NETWORK)[0]["first_seen"], 100)

    def test_underlay_change_is_an_event(self) -> None:
        self.registry.record(NETWORK, [self.peer], now=100)
        moved = observation("fp1", "framework", "10.77.0.2/24", "5.6.7.8:9")
        self.registry.record(NETWORK, [moved], now=110)
        self.assertEqual(events(self.db)[-1], ("fp1", "address_changed"))
        self.assertEqual(self.registry.peers(NETWORK)[0]["last_underlay"], "5.6.7.8:9")

    def test_new_certificate_for_same_name_keeps_old_row(self) -> None:
        self.registry.record(NETWORK, [self.peer], now=100)
        reissued = observation("fp2", "framework", "10.77.0.2/24", "1.2.3.4:5")
        self.registry.record(NETWORK, [reissued], now=110)
        self.assertIn(("fp2", "cert_changed"), events(self.db))
        self.assertEqual(
            {p["fingerprint"] for p in self.registry.peers(NETWORK)}, {"fp1", "fp2"}
        )

    def test_state_survives_restart(self) -> None:
        self.registry.record(NETWORK, [self.peer], now=100)
        restarted = Registry(self.db, offline_after=30)
        self.assertTrue(restarted.peers(NETWORK)[0]["online"])
        restarted.record(NETWORK, [self.peer], now=110)
        self.assertEqual(events(self.db).count(("fp1", "online")), 1)

    def test_networks_are_separate(self) -> None:
        self.registry.record(NETWORK, [self.peer], now=100)
        self.registry.record("other", [], now=100)
        self.registry.sweep("other", now=1000)
        self.assertEqual(self.registry.peers("other"), [])
        self.assertTrue(self.registry.peers(NETWORK)[0]["online"])

    def test_prune_drops_old_events_only(self) -> None:
        self.registry.record(NETWORK, [self.peer], now=100)
        self.registry.prune(now=100 + 366 * 86400, retention_days=365)
        self.assertEqual(events(self.db), [])
        self.assertEqual(len(self.registry.peers(NETWORK)), 1)


def peer(name: str, networks: list[str], last_seen: float, online: bool = True) -> dict:
    return {
        "name": name,
        "vpn_addrs": networks,
        "last_seen": last_seen,
        "online": online,
    }


class DnsTests(unittest.TestCase):
    zone = Zone(
        "mycelium.nebula.johnrinehart.dev",
        "10.77.0.1",
        "lighthouse.mycelium.nebula.johnrinehart.dev",
        ("mycelium.internal",),
    )

    def resolve(
        self, name: str, qtype: str = "A", records: dict | None = None
    ) -> DNSRecord:
        snapshot = Snapshot(
            [], records if records is not None else {"framework": ["10.77.0.2"]}, 7
        )
        return answer(DNSRecord.question(name, qtype), self.zone, snapshot)

    def test_peer_name_resolves_to_overlay_address(self) -> None:
        reply = self.resolve("framework.mycelium.nebula.johnrinehart.dev")
        self.assertEqual([str(rr.rdata) for rr in reply.rr], ["10.77.0.2"])

    def test_peer_name_resolves_in_alias_zone(self) -> None:
        reply = self.resolve("framework.mycelium.internal")
        self.assertEqual([str(rr.rdata) for rr in reply.rr], ["10.77.0.2"])

    def test_site_resolves_to_this_networks_lighthouse(self) -> None:
        reply = self.resolve("Lighthouse.Mycelium.nebula.johnrinehart.dev", records={})
        self.assertEqual([str(rr.rdata) for rr in reply.rr], ["10.77.0.1"])

    def test_unknown_name_in_zone_is_nxdomain(self) -> None:
        self.assertEqual(
            self.resolve("nope.mycelium.nebula.johnrinehart.dev").header.rcode,
            RCODE.NXDOMAIN,
        )

    def test_other_zones_are_refused(self) -> None:
        self.assertEqual(self.resolve("example.com").header.rcode, RCODE.REFUSED)
        self.assertEqual(
            self.resolve("a.b.mycelium.nebula.johnrinehart.dev").header.rcode,
            RCODE.NXDOMAIN,
        )

    def test_missing_type_is_nodata_with_soa(self) -> None:
        reply = self.resolve("framework.mycelium.nebula.johnrinehart.dev", "AAAA")
        self.assertEqual((reply.header.rcode, reply.rr), (RCODE.NOERROR, []))
        self.assertEqual(reply.auth[0].rtype, QTYPE.SOA)

    def test_labels_come_from_certificate_names_latest_wins(self) -> None:
        peers = [
            peer("Old Laptop", ["10.77.0.5/24"], 1),
            peer("framework", ["10.77.0.3/24"], 1),
            peer("framework", ["10.77.0.2/24"], 2),
        ]
        self.assertEqual(
            dns_records(peers),
            {"old-laptop": ["10.77.0.5"], "framework": ["10.77.0.2"]},
        )
        self.assertIsNone(dns_label("---"))


class FakeUpstream:
    """A UDP resolver on localhost that answers every A query with 192.0.2.1."""

    def __init__(self) -> None:
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.address = self.sock.getsockname()
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self) -> None:
        while True:
            data, client = self.sock.recvfrom(65535)
            query = DNSRecord.parse(data)
            reply = query.reply()
            reply.add_answer(*RR.fromZone(f"{query.q.qname} 60 A 192.0.2.1"))
            self.sock.sendto(reply.pack(), client)


class ForwardingTests(unittest.TestCase):
    zone = Zone(
        "mycelium.nebula.johnrinehart.dev",
        "10.77.0.1",
        "lighthouse.mycelium.nebula.johnrinehart.dev",
    )

    def respond(self, name: str, upstreams: list[tuple[str, int]]) -> DNSRecord:
        state = State()
        state.set("mycelium", Snapshot([], {"framework": ["10.77.0.2"]}, 7))
        handler = dns_handler(
            "mycelium", self.zone, state, tcp=False, upstreams=upstreams
        )
        sent = []

        class Socket:
            def sendto(self, data: bytes, _client: object) -> None:
                sent.append(data)

        handler((DNSRecord.question(name).pack(), Socket()), ("10.77.0.3", 5353), None)
        return DNSRecord.parse(sent[0])

    def test_overlay_names_are_answered_locally_even_with_upstreams(self) -> None:
        upstream = FakeUpstream()
        reply = self.respond(
            "framework.mycelium.nebula.johnrinehart.dev", [upstream.address]
        )
        self.assertEqual([str(rr.rdata) for rr in reply.rr], ["10.77.0.2"])
        self.assertTrue(
            is_local(
                DNSRecord.question("lighthouse.mycelium.nebula.johnrinehart.dev"),
                self.zone,
            )
        )

    def test_other_names_are_forwarded_and_keep_the_query_id(self) -> None:
        upstream = FakeUpstream()
        query = DNSRecord.question("relay.magic-wormhole.io")
        reply = DNSRecord.parse(forward(query.pack(), [upstream.address], tcp=False))
        self.assertEqual(reply.header.id, query.header.id)
        self.assertEqual([str(rr.rdata) for rr in reply.rr], ["192.0.2.1"])

    def test_unreachable_upstreams_give_servfail_and_none_configured_refuses(
        self,
    ) -> None:
        dead = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        dead.bind(("127.0.0.1", 0))
        address = dead.getsockname()
        dead.close()
        self.assertEqual(
            self.respond("example.com", [address]).header.rcode, RCODE.SERVFAIL
        )
        self.assertEqual(self.respond("example.com", []).header.rcode, RCODE.REFUSED)


class StatusRenderingTests(unittest.TestCase):
    def test_status_contains_current_counts_and_escaped_peer_rows(self) -> None:
        peers: list[dict[str, Any]] = [
            {
                "fingerprint": "caller",
                "name": "framework",
                "vpn_addrs": ["10.77.0.2/24"],
                "groups": ["peer"],
                "not_after": "2027-09-25T12:52:29+00:00",
                "online": True,
                "last_seen": 90,
                "first_seen": 50,
                "last_underlay": "192.0.2.1:4242",
                "relayed": True,
            },
            {
                "fingerprint": "other",
                "name": "<offline>",
                "vpn_addrs": ["10.77.0.3/24"],
                "groups": [],
                "not_after": None,
                "online": False,
                "last_seen": 80,
                "first_seen": 40,
                "last_underlay": None,
                "relayed": False,
            },
        ]

        status = render_status(peers[0], peers, now=100)

        self.assertEqual(status["online"], 1)
        self.assertEqual(status["total"], 2)
        self.assertEqual(status["relayed"], 1)
        self.assertIn("&lt;offline&gt;", status["rows"])
        self.assertNotIn("<offline>", status["rows"])


class VisibilityTests(unittest.TestCase):
    def test_caller_sees_peers_in_its_certificate_networks(self) -> None:
        peers = [
            peer("lighthouse", ["10.77.0.1/24"], 1),
            peer("framework", ["10.77.0.2/24"], 1),
            peer("elsewhere", ["10.78.0.4/24"], 1),
        ]
        caller = find_caller(peers, "10.77.0.2")
        self.assertEqual(caller["name"], "framework")
        self.assertEqual(
            [p["name"] for p in visible_peers(peers, caller)],
            ["lighthouse", "framework"],
        )

    def test_unknown_source_is_no_caller(self) -> None:
        self.assertIsNone(
            find_caller([peer("framework", ["10.77.0.2/24"], 1)], "10.77.0.9")
        )


class TlsTests(unittest.TestCase):
    public_name = "lighthouse.mycelium.nebula.johnrinehart.dev"
    private_name = "lighthouse.mycelium.internal"

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.certificates: dict[str, dict[str, str]] = {}
        self.identities: dict[str, bytes] = {}
        for serial, hostname in enumerate((self.public_name, self.private_name), 1):
            certificate = self.directory / f"{serial}.crt"
            key = self.directory / f"{serial}.key"
            subprocess.run(
                [
                    "openssl",
                    "req",
                    "-x509",
                    "-newkey",
                    "ec",
                    "-pkeyopt",
                    "ec_paramgen_curve:prime256v1",
                    "-nodes",
                    "-days",
                    "1",
                    "-set_serial",
                    str(serial),
                    "-subj",
                    f"/CN={hostname}",
                    "-addext",
                    f"subjectAltName=DNS:{hostname}",
                    "-addext",
                    "extendedKeyUsage=serverAuth",
                    "-keyout",
                    str(key),
                    "-out",
                    str(certificate),
                ],
                check=True,
                capture_output=True,
                timeout=10,
            )
            self.certificates[hostname] = {
                "certFile": str(certificate),
                "keyFile": str(key),
            }
            self.identities[hostname] = ssl.PEM_cert_to_DER_cert(
                certificate.read_text()
            )
        self.config = {
            **self.certificates[self.public_name],
            "port": 0,
            "extraCertificates": {
                self.private_name.upper(): self.certificates[self.private_name]
            },
        }

    def client(self, hostname: str, *, check_hostname: bool = True) -> ssl.SSLContext:
        context = ssl.create_default_context(
            cafile=self.certificates[hostname]["certFile"]
        )
        context.check_hostname = check_hostname
        return context

    def start_server(self, state: State | None = None) -> tuple[str, int]:
        if state is None:
            state = State()
            state.set(
                NETWORK,
                Snapshot(
                    [
                        peer("local", ["127.0.0.1/32"], 1),
                        peer("other-network", ["10.78.0.4/24"], 1),
                    ],
                    {},
                    1,
                ),
            )
        context = tls_context(self.config)
        server = HttpsServer(("127.0.0.1", 0), https_handler(NETWORK, state))
        self.addCleanup(server.server_close)
        server.socket = context.wrap_socket(
            server.socket, server_side=True, do_handshake_on_connect=False
        )
        thread = threading.Thread(
            target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True
        )
        thread.start()
        self.addCleanup(thread.join, 3)
        self.addCleanup(server.shutdown)
        return server.server_address

    def request(
        self,
        address: tuple[str, int],
        context: ssl.SSLContext,
        server_name: str | None,
    ) -> tuple[bytes, int, bytes]:
        with socket.create_connection(address, timeout=3) as raw:
            with context.wrap_socket(raw, server_hostname=server_name) as connection:
                identity = connection.getpeercert(binary_form=True)
                connection.sendall(
                    b"GET /api/peers HTTP/1.1\r\n"
                    b"Host: unrelated.example\r\nConnection: close\r\n\r\n"
                )
                response = http.client.HTTPResponse(connection)
                response.begin()
                with response:
                    return identity, response.status, response.read()

    def test_public_and_private_names_validate_and_preserve_peer_authorization(
        self,
    ) -> None:
        address = self.start_server()
        for hostname in (
            self.public_name,
            self.private_name,
            self.private_name.upper(),
        ):
            with self.subTest(hostname=hostname):
                identity, status, body = self.request(
                    address, self.client(hostname.lower()), hostname
                )
                self.assertEqual(identity, self.identities[hostname.lower()])
                self.assertEqual(status, 200)
                payload = json.loads(body)
                self.assertEqual(payload["caller"], "local")
                self.assertEqual([p["name"] for p in payload["peers"]], ["local"])

    def test_unknown_and_absent_sni_use_preloaded_public_certificate(self) -> None:
        public = self.client(self.public_name, check_hostname=False)
        private = self.client(self.private_name)
        address = self.start_server()
        for certificate in self.certificates.values():
            for filename in certificate.values():
                Path(filename).unlink()
        for hostname in (None, "unknown.mycelium.internal", self.public_name):
            with self.subTest(hostname=hostname):
                identity, status, _ = self.request(address, public, hostname)
                self.assertEqual(identity, self.identities[self.public_name])
                self.assertEqual(status, 200)
        identity, status, _ = self.request(address, private, self.private_name)
        self.assertEqual(identity, self.identities[self.private_name])
        self.assertEqual(status, 200)

    def test_trusted_certificate_does_not_validate_for_wrong_hostname(self) -> None:
        address = self.start_server()
        with self.assertRaises(ssl.SSLCertVerificationError) as failure:
            self.request(
                address, self.client(self.public_name), "wrong.mycelium.internal"
            )
        self.assertEqual(failure.exception.verify_code, 62)

    def test_private_identity_requires_its_own_trusted_certificate(self) -> None:
        address = self.start_server()
        with self.assertRaises(ssl.SSLCertVerificationError):
            self.request(address, self.client(self.public_name), self.private_name)

    def test_unknown_peer_is_forbidden_even_with_trusted_private_tls(self) -> None:
        address = self.start_server(State())
        identity, status, body = self.request(
            address, self.client(self.private_name), self.private_name
        )
        self.assertEqual(identity, self.identities[self.private_name])
        self.assertEqual(status, 403)
        self.assertEqual(body, b"unknown overlay peer\n")

    def test_missing_configured_extra_certificate_or_key_fails_startup(self) -> None:
        for field in ("certFile", "keyFile"):
            with self.subTest(field=field):
                config = {
                    **self.config,
                    "extraCertificates": {
                        self.private_name: {
                            **self.certificates[self.private_name],
                            field: str(self.directory / "missing"),
                        }
                    },
                }
                with self.assertRaises(FileNotFoundError):
                    tls_context(config)


if __name__ == "__main__":
    unittest.main()
