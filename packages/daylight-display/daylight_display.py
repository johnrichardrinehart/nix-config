#!/usr/bin/env python3
"""Set wl-gammarelay brightness and temperature from solar breakpoints."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import re
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

ZENITH_DEGREES = 90.833


@dataclass(frozen=True)
class Location:
    latitude: float
    longitude: float
    accuracy_meters: float
    source: str


@dataclass(frozen=True)
class Setting:
    at: dt.datetime
    brightness: int
    temperature: int


def solar_event(
    day: dt.date, latitude: float, longitude: float, event: str
) -> dt.datetime:
    """Return sunrise or sunset as a UTC datetime using the NOAA algorithm."""
    rising = event == "sunrise"
    day_of_year = day.timetuple().tm_yday
    longitude_hour = longitude / 15.0
    approximate_time = day_of_year + ((6 if rising else 18) - longitude_hour) / 24.0
    mean_anomaly = 0.9856 * approximate_time - 3.289
    true_longitude = (
        mean_anomaly
        + 1.916 * math.sin(math.radians(mean_anomaly))
        + 0.020 * math.sin(math.radians(2 * mean_anomaly))
        + 282.634
    ) % 360
    right_ascension = (
        math.degrees(math.atan(0.91764 * math.tan(math.radians(true_longitude)))) % 360
    )
    right_ascension += (
        math.floor(true_longitude / 90) * 90 - math.floor(right_ascension / 90) * 90
    )
    right_ascension /= 15

    sin_declination = 0.39782 * math.sin(math.radians(true_longitude))
    cos_declination = math.cos(math.asin(sin_declination))
    cos_hour_angle = (
        math.cos(math.radians(ZENITH_DEGREES))
        - sin_declination * math.sin(math.radians(latitude))
    ) / (cos_declination * math.cos(math.radians(latitude)))
    if not -1 <= cos_hour_angle <= 1:
        raise ValueError(
            f"no {event} occurs at latitude {latitude} on {day.isoformat()}"
        )

    hour_angle = (
        360 - math.degrees(math.acos(cos_hour_angle))
        if rising
        else math.degrees(math.acos(cos_hour_angle))
    )
    local_mean_time = (
        hour_angle / 15 + right_ascension - 0.06571 * approximate_time - 6.622
    )
    utc_hour = (local_mean_time - longitude_hour) % 24
    expected_utc_hour = (6 if rising else 18) - longitude_hour
    utc_hour += round((expected_utc_hour - utc_hour) / 24) * 24
    return dt.datetime.combine(day, dt.time(), dt.UTC) + dt.timedelta(hours=utc_hour)


def schedule(
    config: dict[str, Any], location: Location, now: dt.datetime
) -> list[Setting]:
    local_now = now.astimezone()
    settings: list[Setting] = []
    for day_delta in range(-2, 3):
        day = local_now.date() + dt.timedelta(days=day_delta)
        events: dict[str, dt.datetime] = {}
        for breakpoint in config["breakpoints"]:
            event = breakpoint["event"]
            if event not in events:
                events[event] = solar_event(
                    day, location.latitude, location.longitude, event
                )
            settings.append(
                Setting(
                    at=events[event]
                    + dt.timedelta(minutes=breakpoint["offsetMinutes"]),
                    brightness=breakpoint["brightness"],
                    temperature=breakpoint["temperature"],
                )
            )
    return sorted(settings, key=lambda item: item.at)


def current_and_next(
    config: dict[str, Any], location: Location, now: dt.datetime
) -> tuple[Setting, Setting]:
    settings = schedule(config, location, now)
    past = [setting for setting in settings if setting.at <= now]
    future = [setting for setting in settings if setting.at > now]
    if not past or not future:
        raise RuntimeError("solar breakpoint window does not cover the current time")
    return past[-1], future[0]


def _parse_geoclue_output(output: str) -> tuple[float, float, float, str]:
    def number(name: str) -> float:
        match = re.search(rf"^{name}:\s*([-+0-9.]+)", output, re.MULTILINE)
        if match is None:
            raise ValueError(f"GeoClue output did not contain {name.lower()}")
        return float(match.group(1))

    description = re.search(r"^Description:\s*(.+)$", output, re.MULTILINE)
    return (
        number("Latitude"),
        number("Longitude"),
        number("Accuracy"),
        description.group(1) if description else "unspecified source",
    )


def query_location(geoclue: str, config: dict[str, Any]) -> Location:
    process = subprocess.Popen(
        [geoclue, "--timeout=30", "--accuracy-level=4"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={**os.environ, "LC_ALL": "C"},
    )
    lines: list[str] = []
    try:
        assert process.stdout is not None
        for line in process.stdout:
            lines.append(line)
            if line.startswith("Description:"):
                break
    finally:
        if process.poll() is None:
            process.terminate()
        _, stderr = process.communicate(timeout=2)

    output = "".join(lines)
    if not output or "Description:" not in output:
        detail = stderr.strip() or f"helper exited with status {process.returncode}"
        raise RuntimeError(f"GeoClue did not return a location: {detail}")
    latitude, longitude, accuracy, description = _parse_geoclue_output(output)
    maximum_accuracy = config["location"]["maximumAccuracyMiles"] * 1609.344
    if accuracy > maximum_accuracy:
        raise ValueError(
            f"GeoClue accuracy radius is {accuracy / 1609.344:.0f} miles; "
            f"maximum is {config['location']['maximumAccuracyMiles']} miles"
        )
    precision = config["location"]["coordinatePrecisionDegrees"]
    return Location(
        latitude=round(latitude / precision) * precision,
        longitude=round(longitude / precision) * precision,
        accuracy_meters=accuracy,
        source=f"GeoClue: {description}",
    )


def cache_path() -> Path:
    cache_root = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    return cache_root / "daylight-display" / "location.json"


def save_location(location: Location) -> None:
    path = cache_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(location.__dict__))


def load_location() -> Location:
    values = json.loads(cache_path().read_text())
    values["source"] = "cached GeoClue"
    return Location(**values)


def locate(geoclue: str, config: dict[str, Any]) -> Location:
    try:
        location = query_location(geoclue, config)
        save_location(location)
        return location
    except (
        OSError,
        RuntimeError,
        ValueError,
        TimeoutError,
        subprocess.SubprocessError,
    ) as error:
        print(f"daylight-display: live location unavailable: {error}", file=sys.stderr)
        try:
            return load_location()
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as cache_error:
            raise RuntimeError(
                "no live or cached location is available"
            ) from cache_error


def software_brightness_path() -> Path | None:
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime_dir:
        return None
    return Path(runtime_dir) / "brightness-notify" / "software-brightness"


def read_software_brightness() -> float:
    """Return the software dimming factor published by brightness-notify."""
    path = software_brightness_path()
    if path is None:
        return 1.0
    try:
        value = float(path.read_text())
    except (OSError, ValueError):
        return 1.0
    return min(max(value, 0.0), 1.0)


def set_property(busctl: str, name: str, signature: str, value: str) -> None:
    subprocess.run(
        [
            busctl,
            "--user",
            "set-property",
            "rs.wl-gammarelay",
            "/",
            "rs.wl.gammarelay",
            name,
            signature,
            value,
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )


def apply(busctl: str, setting: Setting | None) -> None:
    base = 1.0 if setting is None else setting.brightness / 100
    set_property(busctl, "Brightness", "d", str(base * read_software_brightness()))
    if setting is not None:
        set_property(busctl, "Temperature", "q", str(setting.temperature))


def status(config: dict[str, Any], geoclue: str, now: dt.datetime) -> None:
    location = locate(geoclue, config)
    current, following = current_and_next(config, location, now)
    print(
        f"location: {location.latitude:.3f}, {location.longitude:.3f} "
        f"({location.source}, accuracy radius {location.accuracy_meters / 1609.344:.0f} mi)"
    )
    print(f"brightness: {current.brightness}%")
    print(f"temperature: {current.temperature}K")
    print(f"active since: {current.at.astimezone().isoformat(timespec='minutes')}")
    print(f"next change: {following.at.astimezone().isoformat(timespec='minutes')}")


def run(config: dict[str, Any], busctl: str, geoclue: str, interval: int) -> None:
    # brightness-notify sends SIGUSR1 to reapply its software factor immediately.
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGUSR1})
    location: Location | None = None
    next_location_update = 0.0
    refresh_seconds = config["location"]["refreshMinutes"] * 60
    while True:
        wait = interval
        now_monotonic = time.monotonic()
        if location is None or now_monotonic >= next_location_update:
            try:
                location = locate(geoclue, config)
                next_location_update = now_monotonic + refresh_seconds
            except (
                OSError,
                ValueError,
                TypeError,
                RuntimeError,
                json.JSONDecodeError,
            ) as error:
                print(f"daylight-display: no usable location: {error}", file=sys.stderr)
                wait = min(interval, 60)
        setting = None
        if location is not None:
            setting, _ = current_and_next(config, location, dt.datetime.now(dt.UTC))
        try:
            apply(busctl, setting)
        except subprocess.CalledProcessError as error:
            print(
                f"daylight-display: could not update wl-gammarelay: {error}",
                file=sys.stderr,
            )
        signal.sigtimedwait({signal.SIGUSR1}, wait)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("run", "status"))
    parser.add_argument(
        "--config", type=Path, default=Path("/etc/daylight-display.json")
    )
    parser.add_argument("--busctl", default="busctl")
    parser.add_argument("--geoclue", default="where-am-i")
    parser.add_argument("--interval", type=int, default=30)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    if args.command == "run":
        run(config, args.busctl, args.geoclue, args.interval)
    else:
        status(config, args.geoclue, dt.datetime.now(dt.UTC))


if __name__ == "__main__":
    main()
