#!/usr/bin/env python3

import unittest

from brightness_sync import ddc_target, parse_backlight, parse_detect, parse_vcp


class ParseTests(unittest.TestCase):
    def test_detect_skips_laptop_and_phantom_displays(self) -> None:
        output = """Invalid display
   I2C bus:          /dev/i2c-9
   DRM connector:    card1-eDP-1
   Monitor:          BOE::

Display 1
   I2C bus:          /dev/i2c-18
   DRM connector:    card1-DP-5
   Monitor:          DEL:DELL U3225QE:ABC

Phantom display
   I2C bus:          /dev/i2c-10
   DRM connector:    card1-DP-1
   Monitor:          DEL:DELL U3225QE:ABC

Display 2
   I2C bus:          /dev/i2c-19
   DRM connector:    card1-DP-6
   Monitor:          DEL:DELL U2520D:DEF
"""
        self.assertEqual(parse_detect(output), [18, 19])

    def test_backlight_fraction_is_scaled_to_monitor_maximum(self) -> None:
        backlight = parse_backlight("intel_backlight,backlight,23040,24%,96000\n")
        self.assertEqual(backlight, (23040, 96000))
        self.assertEqual(parse_vcp("VCP 10 C 75 100\n"), (75, 100))
        self.assertEqual(ddc_target(backlight, 100), 24)
        self.assertEqual(ddc_target(backlight, 255), 61)
        self.assertEqual(ddc_target((255, 255), 100), 100)
        with self.assertRaises(ValueError):
            parse_vcp("VCP 10 ERR\n")


if __name__ == "__main__":
    unittest.main()
