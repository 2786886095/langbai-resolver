from __future__ import annotations

import argparse
from pathlib import Path


ZIP_PACKAGE = "org.apache.commons.compress.archivers.zip."
REQUIRED_REFLECTED_CLASSES = {
    f"{ZIP_PACKAGE}AsiExtraField",
    f"{ZIP_PACKAGE}ExtraFieldUtils",
    f"{ZIP_PACKAGE}X5455_ExtendedTimestamp",
    f"{ZIP_PACKAGE}X7875_NewUnix",
    f"{ZIP_PACKAGE}ZipExtraField",
}


def read_class_mapping(path: Path) -> dict[str, str]:
    mappings: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if raw_line[:1].isspace() or not raw_line.endswith(":"):
            continue
        source, separator, target = raw_line[:-1].partition(" -> ")
        if separator:
            mappings[source] = target
    return mappings


def verify_mapping(path: Path) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"Android R8 mapping not found: {path}")
    mappings = read_class_mapping(path)
    missing = sorted(REQUIRED_REFLECTED_CLASSES.difference(mappings))
    if missing:
        raise ValueError(
            "R8 mapping is missing reflected ZIP classes: " + ", ".join(missing)
        )
    renamed = {
        source: target
        for source, target in mappings.items()
        if source.startswith(ZIP_PACKAGE) and source != target
    }
    if renamed:
        detail = ", ".join(f"{source} -> {target}" for source, target in renamed.items())
        raise ValueError(f"Reflected ZIP classes were renamed by R8: {detail}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mapping", type=Path, required=True)
    args = parser.parse_args()
    verify_mapping(args.mapping)
    print("Android parser reflection mapping verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
