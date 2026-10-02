#!/usr/bin/env python3
"""Fetch only the pinned, attributed FlyWire aggregate graph (about 95 MB).

Data are CC BY-NC 4.0; see data/DATA_LICENSE.md. No package dependencies.
"""
from pathlib import Path
import hashlib
import os
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
REVISION = "8839d84cd24888a4251a2e227792b6f26fbee776"
SOURCE = f"https://raw.githubusercontent.com/dawsonamf/siliconfly/{REVISION}/data"
FILES = {
    "neurons.bin": (4177712, "c48bd4a0ab61dc912b82832720d456854b11b6b12f872b25c769b4e11fe48e6a"),
    "synapses.bin": (90551902, "8989e0b9b231654046c5726c92f5c825df1b0002aca4ed84b18dcaa76ed8c14b"),
}


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def main():
    destination = ROOT / "data"
    destination.mkdir(exist_ok=True)
    for name, (size, expected) in FILES.items():
        target = destination / name
        if target.is_file() and target.stat().st_size == size and digest(target) == expected:
            print(f"Verified {name}")
            continue
        partial = target.with_suffix(".download")
        try:
            with urllib.request.urlopen(f"{SOURCE}/{name}", timeout=60) as source, partial.open("wb") as output:
                total = 0
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    total += len(chunk)
                    if total > size:
                        raise RuntimeError(f"Unexpected download size for {name}")
                    output.write(chunk)
            if partial.stat().st_size != size or digest(partial) != expected:
                raise RuntimeError(f"Size or SHA256 mismatch for {name}")
            os.replace(partial, target)
            print(f"Downloaded and verified {name}")
        finally:
            partial.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
