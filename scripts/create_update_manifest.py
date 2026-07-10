from __future__ import annotations

import argparse
import hashlib
import json
from datetime import UTC, datetime
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--notes", default="")
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    base = f"https://github.com/{args.repository}/releases/latest/download"
    windows = args.assets / "langbai-resolver-Setup.exe"
    manifest = {
        "version": args.version,
        "notes": args.notes or f"langbai解析 {args.version} 更新",
        "published_at": datetime.now(UTC).isoformat(),
        "platforms": {
            "windows": {
                "url": f"{base}/langbai-resolver-Setup.exe",
                "sha256": sha256(windows),
            },
            "android": {"url": f"{base}/langbai-resolver-Android.apk"},
            "ios": {"url": f"{base}/langbai-resolver-iOS.ipa"},
            "web": {"url": f"{base}/langbai-resolver-Web.zip"},
            "macos": {"url": f"https://github.com/{args.repository}/releases/latest"},
            "linux": {"url": f"https://github.com/{args.repository}/releases/latest"},
        },
    }
    args.output.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
