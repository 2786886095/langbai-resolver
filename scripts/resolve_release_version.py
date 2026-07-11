from __future__ import annotations

import argparse
import os
import re
from pathlib import Path


SEMVER_PATTERN = re.compile(
    r"^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)"
    r"(?:-(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)


def _parts(version: str) -> tuple[tuple[int, int, int], tuple[str, ...]]:
    without_build = version.split("+", 1)[0]
    core_text, separator, prerelease_text = without_build.partition("-")
    core = tuple(int(part) for part in core_text.split("."))
    prerelease = tuple(prerelease_text.split(".")) if separator else ()
    return (core[0], core[1], core[2]), prerelease


def compare_versions(left: str, right: str) -> int:
    left = resolve_version(left, "")
    right = resolve_version(right, "")
    left_core, left_pre = _parts(left)
    right_core, right_pre = _parts(right)
    if left_core != right_core:
        return 1 if left_core > right_core else -1
    if not left_pre and not right_pre:
        return 0
    if not left_pre:
        return 1
    if not right_pre:
        return -1
    for left_part, right_part in zip(left_pre, right_pre, strict=False):
        if left_part == right_part:
            continue
        left_number = int(left_part) if left_part.isdigit() else None
        right_number = int(right_part) if right_part.isdigit() else None
        if left_number is not None and right_number is not None:
            return 1 if left_number > right_number else -1
        if left_number is not None:
            return -1
        if right_number is not None:
            return 1
        return 1 if left_part > right_part else -1
    if len(left_pre) == len(right_pre):
        return 0
    return 1 if len(left_pre) > len(right_pre) else -1


def resolve_version(version_input: str, ref_name: str) -> str:
    version = version_input.strip()
    if not version:
        version = ref_name.strip()
        if version.startswith("v"):
            version = version[1:]
    if not SEMVER_PATTERN.fullmatch(version):
        raise ValueError(
            "Release version must be valid SemVer without a v prefix "
            "(for example 1.2.3 or 1.2.3-rc.1)."
        )
    return version


def read_flutter_version(pubspec: Path) -> tuple[str, int]:
    match = re.search(r"(?m)^version:\s*([^\s#]+)", pubspec.read_text(encoding="utf-8"))
    if match is None:
        raise ValueError(f"No version field found in {pubspec}")
    raw = match.group(1)
    version, separator, build_text = raw.rpartition("+")
    if not separator or not build_text.isdigit() or int(build_text) <= 0:
        raise ValueError("Flutter pubspec version must include a positive build number")
    build_number = int(build_text)
    if build_number > 2_100_000_000:
        raise ValueError("Flutter build number exceeds the Android versionCode limit")
    return resolve_version(version, ""), build_number


def validate_release_pubspec(version: str, pubspec: Path) -> int:
    project_version, build_number = read_flutter_version(pubspec)
    if version != project_version:
        raise ValueError(
            f"Release {version} does not match pubspec version {project_version}."
        )
    return build_number


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--input",
        default=os.getenv("RELEASE_VERSION_INPUT", ""),
        help="workflow_dispatch version input",
    )
    parser.add_argument(
        "--newer-than",
        default="",
        help="fail unless the resolved version is newer than this version or v-tag",
    )
    parser.add_argument(
        "--ref",
        default=os.getenv("GITHUB_REF_NAME", ""),
        help="GitHub ref name used for tag-triggered releases",
    )
    parser.add_argument(
        "--github-env",
        type=Path,
        default=Path(os.environ["GITHUB_ENV"]) if "GITHUB_ENV" in os.environ else None,
    )
    parser.add_argument(
        "--pubspec",
        type=Path,
        help="require the release version to match this Flutter pubspec",
    )
    args = parser.parse_args()

    version = resolve_version(args.input, args.ref)
    build_number: int | None = None
    if args.pubspec is not None:
        build_number = validate_release_pubspec(version, args.pubspec)
    if args.newer_than:
        previous = args.newer_than.strip()
        if previous.startswith("v"):
            previous = previous[1:]
        if compare_versions(version, previous) <= 0:
            raise ValueError(
                f"Release {version} must be newer than the latest release {previous}."
            )
    if args.github_env is not None:
        with args.github_env.open("a", encoding="utf-8", newline="\n") as output:
            output.write(f"RELEASE_VERSION={version}\n")
            output.write(
                f"RELEASE_BUILD_NAME={version.split('-', 1)[0].split('+', 1)[0]}\n"
            )
            if build_number is not None:
                output.write(f"RELEASE_BUILD_NUMBER={build_number}\n")
    print(version)


if __name__ == "__main__":
    main()
