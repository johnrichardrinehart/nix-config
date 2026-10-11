import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("cliphist_picker.py")
SPEC = importlib.util.spec_from_file_location("cliphist_picker", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class HistoryTests(unittest.TestCase):
    def test_parse_history_preserves_decode_input(self):
        entries = MODULE.parse_history(
            "42\t[[ binary data 46 KiB png 703x439 ]]\n41\thello world\n"
        )

        self.assertEqual(entries[0].raw, "42\t[[ binary data 46 KiB png 703x439 ]]")
        self.assertEqual(entries[0].label, "[[ binary data 46 KiB png 703x439 ]]")
        self.assertEqual(entries[1].label, "hello world")

    def test_match_is_case_insensitive(self):
        entry = MODULE.HistoryEntry(raw="1\tHello World", label="Hello World")

        self.assertTrue(MODULE.matches(entry, "WORLD"))
        self.assertFalse(MODULE.matches(entry, "image"))

    def test_window_size_is_capped_with_display_margin(self):
        self.assertEqual(MODULE.capped_window_size(3840, 2160), (1200, 760))
        self.assertEqual(MODULE.capped_window_size(900, 600), (804, 504))

    def test_image_mime_detection(self):
        self.assertTrue(MODULE.is_image_mime("image/png"))
        self.assertFalse(MODULE.is_image_mime("application/octet-stream"))

    def test_entry_kind_uses_cliphist_image_metadata(self):
        image = MODULE.HistoryEntry(
            raw="1\t[[ binary data 46 KiB png 703x439 ]]",
            label="[[ binary data 46 KiB png 703x439 ]]",
        )
        text = MODULE.HistoryEntry(raw="2\thello", label="hello")
        binary = MODULE.HistoryEntry(
            raw="3\t[[ binary data 2 MiB application/octet-stream ]]",
            label="[[ binary data 2 MiB application/octet-stream ]]",
        )

        self.assertEqual(MODULE.entry_kind(image), "image")
        self.assertEqual(MODULE.entry_kind(text), "text")
        self.assertEqual(MODULE.entry_kind(binary), "binary")


if __name__ == "__main__":
    unittest.main()
