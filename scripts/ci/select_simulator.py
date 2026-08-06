#!/usr/bin/env python3
"""Select the newest available iPhone from `simctl list --json`.

The JSON can be piped on stdin or supplied with --input. The script is pure
apart from I/O so it can be exercised with fixture JSON on Linux.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Iterable


def natural_key(value: str) -> tuple[object, ...]:
    return tuple(
        int(part) if part.isdigit() else part.casefold()
        for part in re.split(r"(\d+)", value)
        if part
    )


def runtime_key(runtime: str) -> tuple[int, ...]:
    version = re.search(r"iOS[- ](\d+(?:[-.]\d+)*)", runtime)
    if not version:
        return ()
    return tuple(int(part) for part in re.split(r"[-.]", version.group(1)))


def available_iphones(payload: dict[str, Any]) -> Iterable[tuple[tuple[int, ...], str, str]]:
    devices = payload.get("devices")
    if not isinstance(devices, dict):
        return
    for runtime, runtime_devices in devices.items():
        if not isinstance(runtime_devices, list):
            continue
        for device in runtime_devices:
            if not isinstance(device, dict):
                continue
            name = device.get("name")
            udid = device.get("udid")
            if (
                isinstance(name, str)
                and name.startswith("iPhone")
                and isinstance(udid, str)
                and udid
                and device.get("isAvailable", False)
            ):
                yield runtime_key(str(runtime)), name, udid


def select_udid(payload: dict[str, Any]) -> str | None:
    candidates = list(available_iphones(payload))
    if not candidates:
        return None
    candidates.sort(key=lambda item: (item[0], natural_key(item[1]), item[2]))
    return candidates[-1][2]


def load_payload(input_path: Path | None) -> dict[str, Any]:
    if input_path is not None:
        with input_path.open(encoding="utf-8") as handle:
            payload = json.load(handle)
    else:
        payload = json.load(sys.stdin)
    if not isinstance(payload, dict):
        raise ValueError("simctl JSON root must be an object")
    return payload


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, help="Read simctl JSON from this file")
    parser.add_argument(
        "--format",
        choices=("udid", "destination"),
        default="udid",
        help="Print a raw UDID or an xcodebuild destination",
    )
    parser.add_argument(
        "--fallback-name",
        help="Use this Simulator name when no available iPhone is present",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        payload = load_payload(args.input)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"select_simulator: invalid input: {error}", file=sys.stderr)
        return 2

    udid = select_udid(payload)
    if args.format == "destination":
        if udid:
            print(f"platform=iOS Simulator,id={udid}")
            return 0
        if args.fallback_name:
            print(f"platform=iOS Simulator,name={args.fallback_name}")
            return 0
    elif udid:
        print(udid)
        return 0

    print("select_simulator: no available iPhone Simulator found", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
