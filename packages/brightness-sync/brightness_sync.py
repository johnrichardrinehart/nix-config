#!/usr/bin/env python3
"""Keep external monitors in step with the laptop backlight.

External monitors receive the backlight's fraction of its maximum as DDC/CI
brightness (VCP 0x10). brightness-notify maps its level to that fraction. On
start and after display hotplug, the software dimming factor is reapplied
through `brightness-notify sync` so new outputs are dimmed as well.
"""

from __future__ import annotations

import argparse
import os
import re
import select
import signal
import socket
import subprocess
import sys
import time

# Monitors behind DisplayPort MST can take several seconds after the DRM event
# before their DDC/CI channel answers, so rescan once early and once late.
SETTLE_DELAYS = (3.0, 15.0)


def log(message: str) -> None:
    print(f"brightness-sync: {message}", file=sys.stderr, flush=True)


def failure(error: subprocess.CalledProcessError) -> str:
    # ddcutil reports most failures on stdout.
    return (error.stderr or error.stdout or str(error)).strip()


def parse_backlight(info: str) -> tuple[int, int]:
    """Return (current, maximum) from `brightnessctl --machine-readable info`."""
    _device, _class, raw, _percent, maximum = info.strip().split(",")
    return int(raw), int(maximum)


def parse_detect(output: str) -> list[int]:
    """Return I2C buses of usable displays from `ddcutil detect --terse`.

    Invalid (laptop) and phantom (duplicate MST) entries are skipped.
    """
    buses: list[int] = []
    usable = False
    for line in output.splitlines():
        if line and not line[0].isspace():
            usable = line.startswith("Display ")
        elif usable:
            match = re.match(r"\s*I2C bus:\s*/dev/i2c-(\d+)", line)
            if match:
                buses.append(int(match.group(1)))
    return buses


def parse_vcp(output: str) -> tuple[int, int]:
    """Return (current, maximum) from `ddcutil getvcp 10 --brief`."""
    fields = output.split()
    if len(fields) < 5 or fields[0] != "VCP" or fields[2] != "C":
        raise ValueError(f"unexpected getvcp output: {output.strip()!r}")
    return int(fields[3]), int(fields[4])


def ddc_target(backlight: tuple[int, int], maximum: int) -> int:
    current, top = backlight
    return round(current * maximum / top)


class Sync:
    def __init__(self, args: argparse.Namespace) -> None:
        self.ddcutil = args.ddcutil
        self.brightnessctl = args.brightnessctl
        self.brightness_notify = args.brightness_notify
        self.buses: list[int] = []

    def run(self, *command: str) -> str:
        return subprocess.run(
            command, check=True, capture_output=True, text=True
        ).stdout

    def backlight(self) -> tuple[int, int]:
        return parse_backlight(
            self.run(
                self.brightnessctl, "--class=backlight", "--machine-readable", "info"
            )
        )

    def discover(self) -> None:
        try:
            self.buses = parse_detect(self.run(self.ddcutil, "detect", "--terse"))
        except subprocess.CalledProcessError as error:
            log(f"ddcutil detect failed: {failure(error)}")
            self.buses = []
        log(f"DDC/CI displays on buses {self.buses or 'none'}")

    def apply_ddc(self) -> None:
        if not self.buses:
            return
        backlight = self.backlight()
        for bus in self.buses:
            try:
                current, maximum = parse_vcp(
                    self.run(self.ddcutil, "--bus", str(bus), "getvcp", "10", "--brief")
                )
                target = ddc_target(backlight, maximum)
                if current != target:
                    self.run(
                        self.ddcutil,
                        "--bus",
                        str(bus),
                        "--noverify",
                        "setvcp",
                        "10",
                        str(target),
                    )
            except subprocess.CalledProcessError as error:
                log(f"bus {bus}: could not set brightness: {failure(error)}")
            except ValueError as error:
                log(f"bus {bus}: could not set brightness: {error}")

    def sync_software(self) -> None:
        try:
            self.run(self.brightness_notify, "sync")
        except subprocess.CalledProcessError as error:
            log(f"brightness-notify sync failed: {failure(error)}")


def drain(sock: socket.socket) -> None:
    while True:
        try:
            if not sock.recv(64):
                return
        except BlockingIOError:
            return


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ddcutil", default="ddcutil")
    parser.add_argument("--brightnessctl", default="brightnessctl")
    parser.add_argument("--brightness-notify", default="brightness-notify")
    parser.add_argument("--udevadm", default="udevadm")
    args = parser.parse_args()
    sync = Sync(args)

    # brightness-notify sends SIGUSR1 after changing the level. Signals that
    # arrive while ddcutil runs still wake the next select through this pair.
    wake_read, wake_write = socket.socketpair()
    wake_read.setblocking(False)
    wake_write.setblocking(False)
    signal.set_wakeup_fd(wake_write.fileno())
    signal.signal(signal.SIGUSR1, lambda *_: None)

    udev = subprocess.Popen(
        [args.udevadm, "monitor", "--udev", "--subsystem-match=drm"],
        stdout=subprocess.PIPE,
    )
    assert udev.stdout is not None
    udev_fd = udev.stdout.fileno()

    sync.discover()
    sync.sync_software()
    sync.apply_ddc()

    rescans: list[float] = []
    while True:
        timeout = max(0.0, rescans[0] - time.monotonic()) if rescans else None
        readable, _, _ = select.select([wake_read, udev_fd], [], [], timeout)
        level_changed = wake_read in readable
        if level_changed:
            drain(wake_read)
        if udev_fd in readable:
            chunk = os.read(udev_fd, 4096)
            if not chunk:
                raise SystemExit("udevadm monitor exited")
            if b"(drm)" in chunk:
                now = time.monotonic()
                rescans = [now + delay for delay in SETTLE_DELAYS]
        if rescans and time.monotonic() >= rescans[0]:
            rescans.pop(0)
            sync.discover()
            sync.sync_software()
            level_changed = True
        if level_changed:
            sync.apply_ddc()


if __name__ == "__main__":
    main()
