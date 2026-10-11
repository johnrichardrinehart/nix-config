import unittest
from unittest.mock import patch

from service import Bounds, active_outputs, output_for_geometry


class OutputTests(unittest.TestCase):
    def test_reads_named_logical_outputs(self):
        payload = """{"DP-1":{"logical":{"x":-1920,"y":0,"width":1920,"height":1080}},"DP-2":{"logical":null}}"""
        with patch("service.subprocess.run") as run:
            run.return_value.stdout = payload
            self.assertEqual(
                active_outputs(),
                {"DP-1": Bounds(-1920, 0, 1920, 1080)},
            )

    def test_matches_one_complete_output_rectangle(self):
        geometry = Bounds(0, 0, 1920, 1080)
        outputs = {"DP-1": geometry, "DP-2": Bounds(1920, 0, 1920, 1080)}
        self.assertEqual(output_for_geometry(outputs, geometry), "DP-1")

    def test_rejects_unknown_rectangle(self):
        with self.assertRaisesRegex(RuntimeError, "matches 0"):
            output_for_geometry(
                {"DP-1": Bounds(0, 0, 100, 100)}, Bounds(1, 0, 100, 100)
            )

    def test_rejects_ambiguous_mirrored_outputs(self):
        geometry = Bounds(0, 0, 1920, 1080)
        with self.assertRaisesRegex(RuntimeError, "matches 2"):
            output_for_geometry({"DP-1": geometry, "DP-2": geometry}, geometry)


if __name__ == "__main__":
    unittest.main()
