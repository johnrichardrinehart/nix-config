import ast
import os
import unittest
from collections import deque
from pathlib import Path


DAEMON_PATH = Path(
    os.environ.get(
        "MOONSHINE_DAEMON_SOURCE", Path(__file__).parent.parent / "daemon.py"
    )
)


class Chunk(list):
    def tolist(self):
        return list(self)


class Stream:
    def __init__(self):
        self.calls = []

    def add_audio(self, samples, sample_rate):
        self.calls.append(("add_audio", samples, sample_rate))

    def stop(self):
        self.calls.append(("stop",))

    def start(self):
        self.calls.append(("start",))


class Gate:
    def __init__(self, *, transcribing=True):
        tree = ast.parse(DAEMON_PATH.read_text(), filename=str(DAEMON_PATH))
        function = next(
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef)
            and node.name == "_sync_transcription_gate"
        )
        self.leader = False
        self.stream = Stream()
        self.namespace = {
            "_dictating": False,
            "_leader_allows_start": lambda: self.leader,
            "_transcribing": transcribing,
            "_preroll": deque(maxlen=10),
            "stream": self.stream,
            "SAMPLE_RATE": 16000,
        }
        exec(
            compile(
                ast.Module(body=[function], type_ignores=[]), str(DAEMON_PATH), "exec"
            ),
            self.namespace,
        )

    def sync(self):
        return self.namespace["_sync_transcription_gate"]()


class TranscriptionGateTests(unittest.TestCase):
    def test_audio_outside_leader_window_is_not_transcribed(self):
        gate = Gate()

        self.assertFalse(gate.sync())
        self.assertFalse(gate.sync())

        # Closing finalizes the open segment exactly once; idle passes do no work.
        self.assertEqual(gate.stream.calls, [("stop",), ("start",)])

    def test_leader_press_replays_preroll_oldest_first(self):
        gate = Gate(transcribing=False)
        gate.namespace["_preroll"].extend([Chunk([1.0]), Chunk([2.0])])
        gate.leader = True

        self.assertTrue(gate.sync())

        self.assertEqual(
            gate.stream.calls,
            [("add_audio", [1.0], 16000), ("add_audio", [2.0], 16000)],
        )
        self.assertFalse(gate.namespace["_preroll"])

    def test_dictation_keeps_transcribing_after_leader_window(self):
        gate = Gate()
        gate.namespace["_dictating"] = True

        # The stop phrase must still be heard without the leader.
        self.assertTrue(gate.sync())
        self.assertEqual(gate.stream.calls, [])

        gate.namespace["_dictating"] = False
        self.assertFalse(gate.sync())
        self.assertEqual(gate.stream.calls, [("stop",), ("start",)])


if __name__ == "__main__":
    unittest.main()
