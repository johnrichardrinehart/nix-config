#!@python@
"""Expose Niri pointer motion through GNOME's private RemoteDesktop API."""

# dbus-next requires D-Bus signatures as string annotations.
# ruff: noqa: F722, F821

from __future__ import annotations

import asyncio
import json
import math
import subprocess
import uuid
from dataclasses import dataclass

from dbus_next import Message, MessageType, PropertyAccess, Variant
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, dbus_property, method, signal

BUS_NAME = "org.gnome.Mutter.RemoteDesktop"
ROOT_PATH = "/org/gnome/Mutter/RemoteDesktop"
SCREENCAST_NAME = "org.gnome.Mutter.ScreenCast"
PROPERTIES = "org.freedesktop.DBus.Properties"
SCREENCAST_STREAM = "org.gnome.Mutter.ScreenCast.Stream"
POINTER = 2


@dataclass(frozen=True)
class Bounds:
    x: int
    y: int
    width: int
    height: int


def active_outputs() -> dict[str, Bounds]:
    completed = subprocess.run(
        ["@niri@", "msg", "--json", "outputs"],
        check=True,
        capture_output=True,
        text=True,
        timeout=5,
    )
    outputs = json.loads(completed.stdout)
    result = {
        name: Bounds(
            int(item["x"]),
            int(item["y"]),
            int(item["width"]),
            int(item["height"]),
        )
        for name, output in outputs.items()
        if (item := output.get("logical")) is not None
    }
    if not result:
        raise RuntimeError("Niri returned no active logical outputs")
    if any(bounds.width <= 0 or bounds.height <= 0 for bounds in result.values()):
        raise RuntimeError("Niri returned invalid logical output geometry")
    return result


def output_for_geometry(outputs: dict[str, Bounds], geometry: Bounds) -> str:
    matches = [name for name, bounds in outputs.items() if bounds == geometry]
    if len(matches) != 1:
        raise RuntimeError(
            f"authorized stream matches {len(matches)} active Niri outputs"
        )
    return matches[0]


class RemoteSession(ServiceInterface):
    def __init__(self, bus: MessageBus, path: str) -> None:
        super().__init__("org.gnome.Mutter.RemoteDesktop.Session")
        self.bus = bus
        self.path = path
        self.identifier = uuid.uuid4().hex
        self.helpers: dict[str, asyncio.subprocess.Process] = {}
        self.streams: dict[str, tuple[str, Bounds]] = {}
        self.started = False
        self.stopped = False

    @dbus_property(access=PropertyAccess.READ, name="SessionId")
    def session_id(self) -> "s":
        return self.identifier

    @method(name="Start")
    async def start(self):
        if self.stopped:
            return
        self.started = True

    @method(name="Stop")
    async def stop(self):
        await self.close()

    @method(name="NotifyPointerMotionAbsolute")
    async def notify_pointer_motion_absolute(self, stream: "s", x: "d", y: "d"):
        if (
            not self.started
            or self.stopped
            or not math.isfinite(x)
            or not math.isfinite(y)
        ):
            return
        target = self.streams.get(stream)
        if target is None:
            target = await self._stream_target(stream)
            self.streams[stream] = target
        output, geometry = target
        if not 0 <= x < geometry.width or not 0 <= y < geometry.height:
            return
        helper = self.helpers.get(stream)
        if helper is not None and helper.returncode is not None:
            self.helpers.pop(stream)
            helper = None
        if helper is None:
            helper = await asyncio.create_subprocess_exec(
                "@helper@",
                output,
                stdin=asyncio.subprocess.PIPE,
            )
            self.helpers[stream] = helper
        if helper.stdin is None:
            return
        try:
            helper.stdin.write(
                f"A {int(x)} {int(y)} {geometry.width} {geometry.height}\n".encode()
            )
            await helper.stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            self.helpers.pop(stream, None)

    async def _stream_target(self, path: str) -> tuple[str, Bounds]:
        reply = await self.bus.call(
            Message(
                destination=SCREENCAST_NAME,
                path=path,
                interface=PROPERTIES,
                member="Get",
                signature="ss",
                body=[SCREENCAST_STREAM, "Parameters"],
            )
        )
        if reply is None or reply.message_type is MessageType.ERROR or not reply.body:
            raise RuntimeError("cannot read authorized screencast stream geometry")
        parameters = reply.body[0]
        if isinstance(parameters, Variant):
            parameters = parameters.value
        position = parameters["position"]
        size = parameters["size"]
        if isinstance(position, Variant):
            position = position.value
        if isinstance(size, Variant):
            size = size.value
        geometry = Bounds(
            int(position[0]), int(position[1]), int(size[0]), int(size[1])
        )
        if geometry.width <= 0 or geometry.height <= 0:
            raise RuntimeError("authorized stream has invalid geometry")
        outputs = await asyncio.to_thread(active_outputs)
        return output_for_geometry(outputs, geometry), geometry

    @signal(name="Closed")
    def closed(self) -> "":
        return None

    async def close(self) -> None:
        if self.stopped:
            return
        self.stopped = True
        helpers = tuple(self.helpers.values())
        self.helpers.clear()
        for helper in helpers:
            if helper.stdin is not None:
                helper.stdin.close()
        for helper in helpers:
            try:
                await asyncio.wait_for(helper.wait(), timeout=2)
            except TimeoutError:
                helper.terminate()
                try:
                    await asyncio.wait_for(helper.wait(), timeout=2)
                except TimeoutError:
                    helper.kill()
                    await helper.wait()
        self.closed()
        self.bus.unexport(self.path)


class RemoteDesktop(ServiceInterface):
    def __init__(self, bus: MessageBus) -> None:
        super().__init__("org.gnome.Mutter.RemoteDesktop")
        self.bus = bus
        self.sequence = 0
        self.sessions: dict[str, RemoteSession] = {}

    @dbus_property(access=PropertyAccess.READ, name="SupportedDeviceTypes")
    def supported_device_types(self) -> "u":
        return POINTER

    @dbus_property(access=PropertyAccess.READ, name="Version")
    def version(self) -> "i":
        return 1

    @method(name="CreateSession")
    async def create_session(self) -> "o":
        self.sequence += 1
        path = f"{ROOT_PATH}/Session/u{self.sequence}"
        session = RemoteSession(self.bus, path)
        self.sessions[path] = session
        self.bus.export(path, session)
        return path


async def run() -> None:
    bus = await MessageBus().connect()
    root = RemoteDesktop(bus)
    bus.export(ROOT_PATH, root)
    await bus.request_name(BUS_NAME)
    await bus.wait_for_disconnect()


if __name__ == "__main__":
    asyncio.run(run())
