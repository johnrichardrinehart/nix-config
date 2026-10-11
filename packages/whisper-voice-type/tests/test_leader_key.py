import ast
import errno
import os
import types
import unittest
from pathlib import Path

import evdev


DAEMON_PATH = Path(
    os.environ.get(
        "MOONSHINE_DAEMON_SOURCE", Path(__file__).parent.parent / "daemon.py"
    )
)


class Device:
    def __init__(self, path, *, held=False):
        self.path = path
        self.name = path
        self.held = held
        self.connected = True
        self.closed = False

    def capabilities(self):
        return {evdev.ecodes.EV_KEY: [evdev.ecodes.KEY_RIGHTCTRL]}

    def active_keys(self):
        if not self.connected:
            raise OSError(errno.ENODEV, "keyboard disconnected")
        return [evdev.ecodes.KEY_RIGHTCTRL] if self.held else []

    def read(self):
        return iter(())

    def close(self):
        self.closed = True


class Watcher:
    def __init__(self, devices, on_tick=lambda watcher: None, duration=2.0):
        self.devices = devices
        self.elapsed = 0.0
        self.on_tick = on_tick
        self.duration = duration
        self.allowed = {}
        self.namespace = {
            "evdev": types.SimpleNamespace(
                ecodes=evdev.ecodes,
                list_devices=lambda: list(self.devices),
                InputDevice=lambda path: self.devices[path],
            ),
            "time": types.SimpleNamespace(
                time=lambda: 100.0 + self.elapsed,
                monotonic=lambda: self.elapsed,
                sleep=lambda delay: self.advance(delay),
            ),
            "select": types.SimpleNamespace(select=self.select),
            "LEADER_KEY": "KEY_RIGHTCTRL",
            "LEADER_GRACE_SECONDS": 0.5,
            "_leader_recent_until": 0.0,
            "_leader_last_seen": 0.0,
            "_leader_available": False,
            "_shutting_down": False,
            "log_msg": lambda message: None,
            "notify_msg": lambda *args, **kwargs: None,
        }
        tree = ast.parse(DAEMON_PATH.read_text(), filename=str(DAEMON_PATH))
        names = {
            "_leader_code",
            "_supports_key",
            "_watch_leader_key",
            "_leader_allows_start",
        }
        functions = [
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name in names
        ]
        exec(
            compile(
                ast.Module(body=functions, type_ignores=[]), str(DAEMON_PATH), "exec"
            ),
            self.namespace,
        )

    def advance(self, delay):
        self.elapsed += delay
        self.allowed[self.elapsed] = self.namespace["_leader_allows_start"]()
        self.on_tick(self)
        if self.elapsed >= self.duration:
            self.namespace["_shutting_down"] = True

    def select(self, devices, writable, exceptional, timeout):
        self.advance(timeout)
        return [], [], []

    def run(self):
        self.namespace["_watch_leader_key"]()


class NativeKeyStateTests(unittest.TestCase):
    def test_key_state_ioctl_reports_os_error(self):
        with self.assertRaises(OSError) as raised:
            evdev._input.ioctl_EVIOCG_bits(-1, evdev.ecodes.EV_KEY)
        self.assertEqual(raised.exception.errno, errno.EBADF)


class LeaderKeyTests(unittest.TestCase):
    def test_disconnected_external_keyboard_does_not_disable_internal_leader(self):
        external = Device("external")
        internal = Device("internal", held=True)

        def disconnect(watcher):
            if watcher.elapsed == 0.25:
                external.connected = False
                del watcher.devices["external"]

        watcher = Watcher({"external": external, "internal": internal}, disconnect)
        watcher.run()

        self.assertTrue(watcher.allowed[0.5])
        self.assertTrue(watcher.allowed[1.75])
        self.assertTrue(external.closed)

    def test_reconnected_keyboard_is_opened_even_when_event_path_is_reused(self):
        old = Device("keyboard")
        replacement = Device("keyboard", held=True)

        def reconnect(watcher):
            if watcher.elapsed == 0.25:
                old.connected = False
                watcher.devices["keyboard"] = replacement

        watcher = Watcher({"keyboard": old}, reconnect)
        watcher.run()

        self.assertFalse(watcher.allowed[0.5])
        self.assertTrue(watcher.allowed[0.75])
        self.assertTrue(old.closed)

    def test_keyboard_added_after_startup_can_enable_dictation(self):
        keyboard = Device("keyboard", held=True)

        def connect(watcher):
            if watcher.elapsed == 0.75:
                watcher.devices["keyboard"] = keyboard

        watcher = Watcher({}, connect)
        watcher.run()

        self.assertFalse(watcher.allowed[1.0])
        self.assertTrue(watcher.allowed[1.5])

    def test_held_leader_refreshes_grace_until_release_then_expires(self):
        keyboard = Device("keyboard", held=True)

        def release(watcher):
            if watcher.elapsed == 1.0:
                keyboard.held = False

        watcher = Watcher({"keyboard": keyboard}, release)
        watcher.run()

        self.assertTrue(watcher.allowed[0.75])
        self.assertTrue(watcher.allowed[1.25])
        self.assertFalse(watcher.allowed[1.5])


if __name__ == "__main__":
    unittest.main()
