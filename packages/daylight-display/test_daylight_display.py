#!/usr/bin/env python3

import datetime as dt
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from daylight_display import (
    Location,
    _parse_geoclue_output,
    current_and_next,
    read_software_brightness,
    solar_event,
)


class SolarEventTests(unittest.TestCase):
    def setUp(self) -> None:
        self.location = Location(42.0, -71.0, 1000, "test")

    def test_attleboro_summer_events_are_accurate_to_twenty_minutes(self) -> None:
        day = dt.date(2026, 6, 21)
        sunrise = solar_event(day, 42.0, -71.0, "sunrise")
        sunset = solar_event(day, 42.0, -71.0, "sunset")
        self.assertLess(
            abs(sunrise - dt.datetime(2026, 6, 21, 9, 10, tzinfo=dt.UTC)),
            dt.timedelta(minutes=20),
        )
        self.assertLess(
            abs(sunset - dt.datetime(2026, 6, 22, 0, 25, tzinfo=dt.UTC)),
            dt.timedelta(minutes=20),
        )

    def test_breakpoints_step_and_wrap_across_midnight(self) -> None:
        config = {
            "breakpoints": [
                {
                    "event": "sunrise",
                    "offsetMinutes": 60,
                    "brightness": 100,
                    "temperature": 6500,
                },
                {
                    "event": "sunset",
                    "offsetMinutes": 50,
                    "brightness": 20,
                    "temperature": 3000,
                },
            ],
        }
        current, following = current_and_next(
            config,
            self.location,
            dt.datetime(2026, 6, 21, 16, tzinfo=dt.UTC),
        )
        self.assertEqual((current.brightness, current.temperature), (100, 6500))
        self.assertEqual((following.brightness, following.temperature), (20, 3000))

    def test_geoclue_output_is_parsed(self) -> None:
        output = """
Latitude:    42.063120°
Longitude:   -71.247800°
Accuracy:    26000.000000 meters
Description: ipf fallback (from GeoIP data)
"""
        self.assertEqual(
            _parse_geoclue_output(output),
            (42.06312, -71.2478, 26000.0, "ipf fallback (from GeoIP data)"),
        )


class SoftwareBrightnessTests(unittest.TestCase):
    def test_published_factor_is_read_and_clamped(self) -> None:
        with tempfile.TemporaryDirectory() as runtime_dir:
            with mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": runtime_dir}):
                self.assertEqual(read_software_brightness(), 1.0)
                path = Path(runtime_dir) / "brightness-notify" / "software-brightness"
                path.parent.mkdir()
                path.write_text("0.067\n")
                self.assertAlmostEqual(read_software_brightness(), 0.067)
                path.write_text("1.5\n")
                self.assertEqual(read_software_brightness(), 1.0)
                path.write_text("garbage\n")
                self.assertEqual(read_software_brightness(), 1.0)


if __name__ == "__main__":
    unittest.main()
