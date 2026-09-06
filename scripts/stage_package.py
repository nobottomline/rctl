#!/usr/bin/env python3
"""Finalize package metadata before Theos applies the installation prefix."""

import pathlib
import plistlib
import sys


def stage_package(stage: pathlib.Path, scheme: str) -> None:
    if scheme not in ("", "rootless"):
        raise ValueError(f"unsupported package scheme: {scheme}")
    rootless = scheme == "rootless"
    web_path = "usr/local/share/rctl/web/index.html" if rootless else "var/mobile/rctl/index.html"
    web = stage / web_path
    if not web.is_file() or web.stat().st_size == 0:
        raise ValueError(f"required control client is missing or empty: {web_path}")
    # layout/README.md documents the source tree; it is not a runtime artifact.
    (stage / "README.md").unlink(missing_ok=True)
    if not rootless:
        return

    control = stage / "DEBIAN/control"
    lines = control.read_text().splitlines()
    fields = dict(line.split(": ", 1) for line in lines if ": " in line)
    if fields.get("Architecture") != "iphoneos-arm64":
        raise ValueError("Theos did not select the rootless package architecture")
    lines = ["Depends: ellekit, firmware (>= 15.0)" if line.startswith("Depends:") else line
             for line in lines]
    control.write_text("\n".join(lines) + "\n")

    plist_path = stage / "Library/LaunchDaemons/com.greatlove.rctld.plist"
    with plist_path.open("rb") as source:
        plist = plistlib.load(source)
    plist["ProgramArguments"] = ["/var/jb/usr/local/bin/rctld"]
    with plist_path.open("wb") as target:
        plistlib.dump(plist, target, sort_keys=False)

    for name in ("postinst", "prerm"):
        script = stage / "DEBIAN" / name
        contents = script.read_text()
        if "RCTL_PREFIX=''" not in contents:
            raise ValueError(f"{name}: missing package prefix marker")
        contents = contents.replace("#!/bin/sh\n", "#!/var/jb/bin/sh\n", 1)
        contents = contents.replace("RCTL_PREFIX=''", "RCTL_PREFIX='/var/jb'", 1)
        contents = contents.replace("WEB_CLIENT=/var/mobile/rctl/index.html",
                                    "WEB_CLIENT=$RCTL_PREFIX/usr/local/share/rctl/web/index.html")
        script.write_text(contents)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: stage_package.py STAGING_DIR SCHEME")
    stage_package(pathlib.Path(sys.argv[1]), sys.argv[2])
