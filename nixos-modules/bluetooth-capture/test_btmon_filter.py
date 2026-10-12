"""Check that btmon_filter removes secrets from real btmon output.

Build a btsnoop trace that carries fake keys, a passkey, a PIN, and a
keystroke-like HID notification. Decode it with `btmon -r`, run the decoded
text through the filter, and fail if any secret survives.
"""

import os
import struct
import subprocess
import sys
import tempfile

BTMON = sys.argv[1]
FILTER = sys.argv[2]

LTK = bytes.fromhex("a1b2c3d4e5f60718293a4b5c6d7e8f90")
LINK_KEY = bytes.fromhex("0f1e2d3c4b5a69788796a5b4c3d2e1f0")
AES_KEY = bytes.fromhex("5ec2e7a15ec2e7a25ec2e7a35ec2e7a4")
RAND = bytes.fromhex("7766554433221100")
PASSKEY = 987654
PIN = b"4321" + bytes(12)
KEYSTROKE = b"HIDKEYSTROKE"
BDADDR = bytes.fromhex("dd f6 ed 0a ea c5")
HANDLE = struct.pack("<H", 0x0800)


def command(opcode, params):
    return b"\x01" + struct.pack("<HB", opcode, len(params)) + params


def event(code, params):
    return b"\x04" + struct.pack("<BB", code, len(params)) + params


def acl(payload):
    l2cap = struct.pack("<HH", len(payload), 0x0004) + payload
    return b"\x02" + struct.pack("<HH", 0x0800 | 0x2000, len(l2cap)) + l2cap


PACKETS = [
    command(0x201A, HANDLE + LTK),  # LE Long Term Key Request Reply
    command(
        0x2019, HANDLE + RAND + struct.pack("<H", 0x1234) + LTK
    ),  # LE Start Encryption
    command(0x2017, AES_KEY + LTK),  # LE Encrypt
    command(0x040B, BDADDR + LINK_KEY),  # Link Key Request Reply
    command(0x042E, BDADDR + struct.pack("<I", PASSKEY)),  # User Passkey Request Reply
    command(0x040D, BDADDR + bytes([4]) + PIN),  # PIN Code Request Reply
    acl(
        b"\x1b" + struct.pack("<H", 0x0012) + KEYSTROKE
    ),  # ATT Handle Value Notification
    event(0x08, b"\x00" + HANDLE + b"\x01"),  # Encryption Change
]


def btsnoop(packets):
    out = b"btsnoop\x00" + struct.pack(">II", 1, 1002)
    for index, packet in enumerate(packets):
        flags = 0 if packet[0] in (1, 2) else 1
        timestamp = 0x00E03AB44A676000 + index * 1000
        out += (
            struct.pack(">IIIIq", len(packet), len(packet), flags, 0, timestamp)
            + packet
        )
    return out


def renderings(secret):
    """Return the text forms in which btmon can print a byte string."""
    forms = set()
    for value in (secret, secret[::-1]):
        for text in (value.hex(), value.hex(" ")):
            forms.update((text, text.upper()))
    return forms


def main():
    with tempfile.TemporaryDirectory() as directory:
        trace = os.path.join(directory, "trace.btsnoop")
        with open(trace, "wb") as handle:
            handle.write(btsnoop(PACKETS))
        raw = subprocess.run(
            [BTMON, "-r", trace, "--columns=250", "--color=never"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        filtered = subprocess.run(
            [sys.executable, FILTER],
            input=raw,
            check=True,
            capture_output=True,
            text=True,
        ).stdout

    secrets = {
        "LTK": renderings(LTK),
        "link key": renderings(LINK_KEY),
        "LE Encrypt key": renderings(AES_KEY),
        "random number": renderings(RAND),
        "passkey": {str(PASSKEY)},
        "PIN": renderings(PIN) | {"4321"},
        "keystroke": renderings(KEYSTROKE) | {KEYSTROKE.decode()},
    }
    failures = []
    for name, forms in secrets.items():
        if not any(form in raw for form in forms):
            failures.append(
                f"btmon output lacks the {name}; the fixture does not test it"
            )
        if any(form in filtered for form in forms):
            failures.append(f"filtered output leaks the {name}")
    for required in ("Encryption Change", "Status: Success", "[redacted]"):
        if required not in filtered:
            failures.append(f"filtered output lacks {required!r}")
    if "ACL Data" in filtered:
        failures.append("filtered output keeps an ACL data block")

    if failures:
        sys.stderr.write(
            "\n".join(failures)
            + "\n\n--- btmon ---\n"
            + raw
            + "\n--- filtered ---\n"
            + filtered
        )
        sys.exit(1)
    print("btmon filter: secrets redacted, events kept")


if __name__ == "__main__":
    main()
