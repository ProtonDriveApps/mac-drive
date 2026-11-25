#!/usr/bin/env python3
"""Capture and verify the Apple toolchain identity used by Bazel actions."""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable, Sequence


CommandRunner = Callable[[Sequence[str]], str]


def run(command: Sequence[str], environment=None) -> str:
    return subprocess.run(
        command,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=environment,
    ).stdout.strip()


def cache_identities(observed):
    """Apple release labels separate caches without fingerprinting installations."""
    build = observed['host']['macos_build']
    architecture = observed['host']['architecture']
    if not re.fullmatch(r"[A-Za-z0-9._-]+", build) or not re.fullmatch(r"[A-Za-z0-9_]+", architecture):
        raise ValueError("Cannot determine a valid macOS build/architecture cache identity")
    version, xcode_build = observed['xcode']['version'], observed['xcode']['build']
    if not all(re.fullmatch(r'[A-Za-z0-9._-]+', value) for value in (version, xcode_build)):
        raise ValueError('Cannot determine a valid Xcode version/build cache identity')
    return f"macos-{build}-{architecture}", f"xcode-{version}-{xcode_build}"


def _match(pattern: str, value: str, description: str) -> tuple[str, ...]:
    match = re.search(pattern, value, re.MULTILINE)
    if not match:
        raise ValueError(f"Could not parse {description} from:\n{value}")
    return match.groups()


def capture(runner: CommandRunner | None = None, *, environment=None) -> dict[str, object]:
    environment = dict(os.environ if environment is None else environment)
    if runner is None:
        runner = lambda command: run(command, environment)
    developer_dir = environment.get('DEVELOPER_DIR') or runner(['/usr/bin/xcode-select', '-p'])
    if not developer_dir or not Path(developer_dir).is_absolute():
        raise ValueError('Cannot resolve the selected Apple developer directory')
    environment['DEVELOPER_DIR'] = developer_dir
    xcode_version, xcode_build = _match(
        r"^Xcode (.+)$\n^Build version (.+)$",
        runner(["/usr/bin/xcodebuild", "-version"]),
        "Xcode version",
    )
    swift_version, swiftlang, clang = _match(
        r"Apple Swift version ([^ ]+) \(swiftlang-([^ ]+) clang-([^)]+)\)",
        runner(["/usr/bin/xcrun", "swift", "--version"]),
        "Swift version",
    )

    sdks: dict[str, dict[str, str]] = {}
    for sdk in ("macosx",):
        sdks[sdk] = {
            "version": runner(["/usr/bin/xcrun", "--sdk", sdk, "--show-sdk-version"]),
            "build": runner(["/usr/bin/xcrun", "--sdk", sdk, "--show-sdk-build-version"]),
        }

    return {
        "schema_version": 1,
        "xcode": {"version": xcode_version, "build": xcode_build},
        "swift": {
            "version": swift_version,
            "swiftlang": swiftlang,
            "clang": clang,
        },
        "sdks": sdks,
        "host": {
            "architecture": platform.machine(),
            "macos_build": runner(["/usr/bin/sw_vers", "-buildVersion"]),
        },
        "developer_dir": developer_dir,
    }


def mismatches(expected: object, observed: object, path: str = "") -> list[str]:
    if isinstance(expected, dict):
        if not isinstance(observed, dict):
            return [f"{path or '<root>'}: expected an object, observed {observed!r}"]
        differences: list[str] = []
        for key, expected_value in expected.items():
            child_path = f"{path}.{key}" if path else key
            if key not in observed:
                differences.append(f"{child_path}: missing")
            else:
                differences.extend(mismatches(expected_value, observed[key], child_path))
        return differences
    if expected != observed:
        return [f"{path}: expected {expected!r}, observed {observed!r}"]
    return []


def verify(root, observed, *, manifest=None, xcode_version_file=None):
    expected = json.loads((manifest or root / 'toolchains/apple.json').read_text())
    expected['xcode'] = {'version': (xcode_version_file or root / '.xcodeversion').read_text().strip()}
    differences = mismatches(expected, observed)
    if differences:
        raise ValueError('Apple toolchain does not match the pinned manifest:\n' +
                         '\n'.join('  - ' + difference for difference in differences))


def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--manifest",
        type=Path,
        default=repo_root / "toolchains" / "apple.json",
    )
    parser.add_argument(
        "--xcode-version-file",
        type=Path,
        default=repo_root / ".xcodeversion",
    )
    parser.add_argument("--capture", action="store_true")
    args = parser.parse_args()

    observed = capture()
    if args.capture:
        print(json.dumps(observed, indent=2, sort_keys=True))
        return 0

    try:
        verify(repo_root, observed, manifest=args.manifest, xcode_version_file=args.xcode_version_file)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1

    print(
        "Apple toolchain verified: "
        f"Xcode {observed['xcode']['version']} ({observed['xcode']['build']}), "
        f"Swift {observed['swift']['version']}, {observed['host']['architecture']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
