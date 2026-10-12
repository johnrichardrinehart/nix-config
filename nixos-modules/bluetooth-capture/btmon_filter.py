"""Store btmon text output without data packets or key material.

Read `btmon` text on standard input. Write one file per UTC hour to the output
directory and compress each file with gzip after the hour ends.

Data packets carry HID reports, which include keystrokes. Drop every ACL, SCO,
and ISO data block. Redact each field that btmon labels as a key, passkey,
PIN, nonce, or encryption input, and drop the hex dump that follows it.
"""

import argparse
import datetime
import gzip
import os
import re
import shutil
import sys

DATA_BLOCK = re.compile(r"^(?:\S+\[\d+\]: )?[<>] (?:ACL|SCO|ISO) Data\b")
BLOCK_START = re.compile(r"^\S")

# Labels from BlueZ monitor/packet.c print_key() and print_hex_field() calls
# that carry secrets or encryption inputs.
SECRET_FIELD = re.compile(
    r"^(?P<indent>\s*)(?P<label>"
    r"Key|Link key|Long term key|(?:Local |Peer )?[Ii]dentity resolving key|"
    r"IRK|CSRK|Signature key|"
    r"Randomizer(?: R with P-(?:192|256))?|Hash(?: C from P-(?:192|256))?|"
    r"PIN code|Passkey|SMP TK|Diffie-Hellman key|Broadcast Code|"
    r"Random number|Encrypted diversifier|Diversifier|"
    r"Encrypted data|Plaintext data|Authentication Value|Confirm value|Value"
    r")(?:\[\d+\])?\s*:"
)
HEADER_PASSKEY = re.compile(r"(passkey )\d+", re.IGNORECASE)
HEX_DUMP = re.compile(r"^\s+[0-9a-fA-F]{2}(?: [0-9a-fA-F]{2})*(?:\s{2,}.*)?$")


def redact(lines):
    """Yield lines with data blocks dropped and secret fields redacted."""
    in_data_block = False
    in_secret_dump = False
    for line in lines:
        if BLOCK_START.match(line):
            in_data_block = bool(DATA_BLOCK.match(line))
            in_secret_dump = False
            if in_data_block:
                continue
            yield HEADER_PASSKEY.sub(r"\1[redacted]", line)
            continue
        if in_data_block:
            continue
        if in_secret_dump and HEX_DUMP.match(line):
            continue
        in_secret_dump = False
        secret = SECRET_FIELD.match(line)
        if secret:
            in_secret_dump = True
            yield f"{secret['indent']}{secret['label']}: [redacted]\n"
            continue
        yield line


class HourlyWriter:
    """Write lines to one file per UTC hour and compress finished hours."""

    def __init__(self, directory):
        self.directory = directory
        self.hour = None
        self.handle = None

    def path_for(self, hour):
        return os.path.join(self.directory, f"btmon-{hour}.log")

    def write(self, line):
        hour = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%HZ")
        if hour != self.hour:
            self.close()
            self.hour = hour
            self.handle = open(self.path_for(hour), "a", encoding="utf-8")
        self.handle.write(line)
        self.handle.flush()

    def close(self):
        if self.handle is None:
            return
        self.handle.close()
        self.handle = None
        compress(self.path_for(self.hour))

    def compress_leftovers(self):
        """Compress plain files from earlier runs, except the current hour."""
        current = os.path.basename(
            self.path_for(
                datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%HZ")
            )
        )
        for name in sorted(os.listdir(self.directory)):
            if name.startswith("btmon-") and name.endswith(".log") and name != current:
                compress(os.path.join(self.directory, name))


def compress(path):
    """Replace path with path.gz; append if an earlier run left one."""
    if not os.path.exists(path):
        return
    with open(path, "rb") as source, gzip.open(path + ".gz", "ab") as target:
        shutil.copyfileobj(source, target)
    os.remove(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir", help="write hourly files here instead of standard output"
    )
    args = parser.parse_args()

    source = open(
        sys.stdin.fileno(), "r", encoding="utf-8", errors="replace", newline="\n"
    )
    if args.output_dir is None:
        for line in redact(source):
            sys.stdout.write(line)
        return

    os.umask(0o077)
    writer = HourlyWriter(args.output_dir)
    writer.compress_leftovers()
    try:
        for line in redact(source):
            writer.write(line)
    finally:
        writer.close()


if __name__ == "__main__":
    main()
