#!/usr/bin/env python3
"""Check a trusted local public base before extracting it for personalization."""

import pathlib
import subprocess
import sys
import tarfile


def inspect(package: str) -> None:
    package_id, architecture = [subprocess.check_output(
        ["dpkg-deb", "-f", package, field], text=True).strip()
        for field in ("Package", "Architecture")]
    if package_id != "com.greatlove.rctl" or architecture not in ("iphoneos-arm", "iphoneos-arm64"):
        raise ValueError("unsupported public package identity or architecture")
    daemon = "usr/local/bin/rctld"
    other_daemon = "var/jb/" + daemon
    if architecture == "iphoneos-arm64":
        daemon, other_daemon = other_daemon, daemon
    config = "var/mobile/Library/Preferences/com.greatlove.rctl.relay.plist"
    protected = (config, "var/jb/" + config, daemon)
    seen = set()
    total = 0
    found = False
    process = subprocess.Popen(["dpkg-deb", "--fsys-tarfile", package], stdout=subprocess.PIPE)
    try:
        with tarfile.open(fileobj=process.stdout, mode="r|") as archive:
            for entry in archive:
                path = pathlib.PurePosixPath(entry.name)
                if path.is_absolute() or ".." in path.parts:
                    raise ValueError("unsafe archive path")
                name = str(path)
                if name in seen or len(seen) >= 100_000:
                    raise ValueError("duplicate archive path or too many entries")
                seen.add(name)
                total += entry.size
                if not 0 <= entry.size <= 512 << 20 or total > 1 << 30:
                    raise ValueError("archive size exceeds limit")
                if name in protected[:2]:
                    raise ValueError("base package already contains relay configuration")
                if any(target.startswith(name + "/") for target in protected) and not entry.isdir():
                    raise ValueError("non-directory runtime or identity ancestor")
                # dpkg extraction must not follow links supplied by a base archive.
                if entry.issym() or entry.islnk() or entry.isdev() or entry.isfifo():
                    raise ValueError("linked or special archive entries are unsupported")
                if name == other_daemon:
                    raise ValueError("package runtime does not match architecture")
                if name == daemon:
                    found = entry.isfile() and entry.size > 0
        # Drain tar padding before waiting for the producer.
        while process.stdout.read(65536):
            pass
        if process.wait() != 0 or not found:
            raise ValueError("missing package runtime or invalid archive")
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.terminate()
        process.wait()


if __name__ == "__main__":
    try:
        inspect(sys.argv[1])
    except (ValueError, tarfile.TarError, subprocess.SubprocessError, IndexError) as error:
        sys.exit(f"public package rejected: {error}")
