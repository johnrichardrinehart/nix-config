import ast
import os
import types
import unittest
from pathlib import Path
from unittest import mock


DAEMON_PATH = Path(
    os.environ.get(
        "MOONSHINE_DAEMON_SOURCE", Path(__file__).parent.parent / "daemon.py"
    )
)


class ExitRequested(Exception):
    def __init__(self, status):
        self.status = status


def load_restart_daemon(*, shutting_down=False, notification_error=None):
    tree = ast.parse(DAEMON_PATH.read_text(), filename=str(DAEMON_PATH))
    function = next(
        node
        for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name == "_restart_daemon"
    )

    def request_exit(status):
        raise ExitRequested(status)

    exit_mock = mock.Mock(side_effect=request_exit)
    exec_mock = mock.Mock()
    log_mock = mock.Mock()
    notify_mock = mock.Mock(side_effect=notification_error)
    namespace = {
        "_shutting_down": shutting_down,
        "log_msg": log_mock,
        "notify_msg": notify_mock,
        "os": types.SimpleNamespace(_exit=exit_mock, execv=exec_mock),
        "sys": types.SimpleNamespace(executable="python", argv=["daemon.py"]),
    }
    exec(
        compile(ast.Module(body=[function], type_ignores=[]), str(DAEMON_PATH), "exec"),
        namespace,
    )
    return namespace["_restart_daemon"], exit_mock, exec_mock, log_mock, notify_mock


class DaemonLifecycleTests(unittest.TestCase):
    def test_restart_exits_for_service_supervisor(self):
        restart, exit_mock, exec_mock, log_mock, notify_mock = load_restart_daemon()

        with self.assertRaises(ExitRequested) as raised:
            restart("PulseAudio capture ended")

        self.assertEqual(raised.exception.status, 1)
        exit_mock.assert_called_once_with(1)
        exec_mock.assert_not_called()
        log_mock.assert_called_once_with(
            "PulseAudio capture ended; exiting for service restart"
        )
        notify_mock.assert_called_once_with(
            "Moonshine restarting",
            "PulseAudio capture ended",
            timeout=2500,
            urgency="normal",
        )

    def test_restart_exits_even_when_notification_fails(self):
        restart, exit_mock, exec_mock, _, _ = load_restart_daemon(
            notification_error=RuntimeError("notification service unavailable")
        )

        with self.assertRaises(ExitRequested) as raised:
            restart("PulseAudio capture failed")

        self.assertEqual(raised.exception.status, 1)
        exit_mock.assert_called_once_with(1)
        exec_mock.assert_not_called()

    def test_shutdown_exits_successfully_without_requesting_restart(self):
        restart, exit_mock, exec_mock, log_mock, notify_mock = load_restart_daemon(
            shutting_down=True
        )

        with self.assertRaises(ExitRequested) as raised:
            restart("PulseAudio capture ended")

        self.assertEqual(raised.exception.status, 0)
        exit_mock.assert_called_once_with(0)
        exec_mock.assert_not_called()
        log_mock.assert_not_called()
        notify_mock.assert_not_called()


if __name__ == "__main__":
    unittest.main()
