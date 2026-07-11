from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from resolve_release_version import read_flutter_version  # noqa: E402


def read_project_version(pubspec: Path) -> str:
    return read_flutter_version(pubspec)[0]


def read_project_build_number(pubspec: Path) -> int:
    return read_flutter_version(pubspec)[1]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pubspec", type=Path, required=True)
    parser.add_argument("--github-env", type=Path)
    args = parser.parse_args()
    version, build_number = read_flutter_version(args.pubspec)
    if args.github_env is not None:
        with args.github_env.open("a", encoding="utf-8", newline="\n") as output:
            output.write(f"APP_VERSION={version}\n")
            output.write(f"APP_BUILD_NUMBER={build_number}\n")
    print(version)


if __name__ == "__main__":
    main()
