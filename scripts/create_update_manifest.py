from __future__ import annotations

import argparse
import hashlib
import json
import re
from datetime import UTC, datetime
from pathlib import Path


_VERSION = re.compile(
    r"^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)"
    r"(?:-(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
_REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
_SHA256 = re.compile(r"^[0-9a-fA-F]{64}$")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _asset(assets: Path, name: str, *, required: bool = True) -> Path | None:
    path = assets / name
    if path.is_file():
        return path
    if required:
        raise FileNotFoundError(f"Required release asset is missing: {path}")
    return None


def _platform_release(base: str, path: Path) -> dict[str, object]:
    return {
        "url": f"{base}/{path.name}",
        "sha256": sha256(path),
        "size_bytes": path.stat().st_size,
    }


def build_manifest(
    *,
    version: str,
    repository: str,
    notes: str,
    assets: Path,
) -> dict[str, object]:
    if not _VERSION.fullmatch(version):
        raise ValueError("Invalid SemVer release version")
    if not _REPOSITORY.fullmatch(repository):
        raise ValueError("Repository must use the owner/name form")

    windows = _asset(assets, "langbai-resolver-Setup.exe", required=False)
    android = _asset(assets, "langbai-resolver-Android.apk")
    android_variants = {
        "android-arm64": _asset(
            assets, "langbai-resolver-Android-arm64.apk", required=False
        ),
        "android-armv7": _asset(
            assets, "langbai-resolver-Android-armv7.apk", required=False
        ),
        "android-x86_64": _asset(
            assets, "langbai-resolver-Android-x86_64.apk", required=False
        ),
    }
    ios = _asset(assets, "langbai-resolver-iOS.ipa", required=False)
    web = _asset(assets, "langbai-resolver-Web.zip", required=False)
    signer_file = _asset(
        assets, "windows-signing-cert-sha256.txt", required=False
    )
    if windows is None and signer_file is not None:
        raise FileNotFoundError(
            "Windows signing certificate fingerprint requires a Windows Setup"
        )
    assert android is not None

    base = f"https://github.com/{repository}/releases/download/v{version}"
    platforms: dict[str, dict[str, object]] = {
        "android": _platform_release(base, android),
    }
    for platform, variant in android_variants.items():
        if variant is not None:
            platforms[platform] = _platform_release(base, variant)
    if windows is not None:
        windows_release = _platform_release(base, windows)
        if signer_file is not None:
            signer = signer_file.read_text(encoding="utf-8").strip().lower()
            if not _SHA256.fullmatch(signer):
                raise ValueError("Windows signing certificate SHA-256 is invalid")
            windows_release["signing_certificate_sha256"] = signer
        else:
            windows_release["unsigned"] = True
        platforms["windows"] = windows_release
    if ios is not None:
        platforms["ios"] = _platform_release(base, ios)
    if web is not None:
        platforms["web"] = _platform_release(base, web)
    return {
        "version": version,
        "notes": notes or f"langbai解析 {version} 更新",
        "published_at": datetime.now(UTC).isoformat(),
        "platforms": platforms,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--notes", default="")
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    manifest = build_manifest(
        version=args.version,
        repository=args.repository,
        notes=args.notes,
        assets=args.assets,
    )
    args.output.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
