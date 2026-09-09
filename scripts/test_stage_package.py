#!/usr/bin/env python3
"""Exercise staging against the real maintainer-script and launchd templates."""

import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest

from stage_package import stage_package

ROOT = pathlib.Path(__file__).resolve().parent.parent


class StagePackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rctl-stage-test-")
        self.addCleanup(self.temporary.cleanup)
        self.stage = pathlib.Path(self.temporary.name)
        shutil.copytree(ROOT / "layout", self.stage, dirs_exist_ok=True)

    def prepare(self, rootless=True):
        architecture = "iphoneos-arm64" if rootless else "iphoneos-arm"
        control = (ROOT / "control").read_text().replace("Architecture: iphoneos-arm\n",
                                                       f"Architecture: {architecture}\n")
        (self.stage / "DEBIAN/control").write_text(control)
        relative = "usr/local/share/rctl/web/index.html" if rootless else "var/mobile/rctl/index.html"
        web = self.stage / relative
        web.parent.mkdir(parents=True, exist_ok=True)
        web.write_text("<!doctype html><title>rctl</title>")
        return web

    def test_rootless_metadata_and_persistent_state(self):
        self.prepare()
        stage_package(self.stage, "rootless")
        control = (self.stage / "DEBIAN/control").read_text()
        self.assertIn("Architecture: iphoneos-arm64\n", control)
        self.assertIn("Depends: ellekit, firmware (>= 15.0)\n", control)
        self.assertFalse((self.stage / "README.md").exists())
        with (self.stage / "Library/LaunchDaemons/com.greatlove.rctld.plist").open("rb") as source:
            plist = plistlib.load(source)
        self.assertEqual(plist["ProgramArguments"], ["/var/jb/usr/local/bin/rctld"])
        self.assertEqual(plist["StandardErrorPath"], "/tmp/rctld.err.log")
        for name in ("postinst", "prerm"):
            script = self.stage / "DEBIAN" / name
            contents = script.read_text()
            self.assertTrue(contents.startswith("#!/var/jb/bin/sh\n"))
            self.assertIn("RCTL_PREFIX='/var/jb'", contents)
            self.assertIn("RELAY_PREF=/var/mobile/Library/Preferences/", contents)
            self.assertNotIn("RELAY_PREF=/var/jb/", contents)
            subprocess.run(["/bin/sh", "-n", str(script)], check=True)
        self.assertIn("WEB_CLIENT=$RCTL_PREFIX/usr/local/share/rctl/web/index.html",
                      (self.stage / "DEBIAN/postinst").read_text())

    def test_rootful_templates_are_unchanged(self):
        self.prepare(rootless=False)
        paths = ["DEBIAN/control", "DEBIAN/postinst", "DEBIAN/prerm",
                 "Library/LaunchDaemons/com.greatlove.rctld.plist"]
        before = {path: (self.stage / path).read_bytes() for path in paths}
        stage_package(self.stage, "")
        self.assertEqual(before, {path: (self.stage / path).read_bytes() for path in paths})

    def test_rootless_restart_is_requested_not_executed(self):
        self.prepare()
        stage_package(self.stage, "rootless")
        for name in ("postinst", "prerm"):
            contents = (self.stage / "DEBIAN" / name).read_text()
            helper = re.search(r"^request_gui_restart\(\) \{\n.*?^\}",
                               contents, re.MULTILINE | re.DOTALL)
            self.assertIsNotNone(helper)
            self.assertNotIn("killall -9 SpringBoard", contents.replace(helper.group(), ""))
            for cydia, descriptor, expected in (
                ("6 1", "6>&1", "finish:restart\n"),
                ("", "", "sbreload"),
                ("invalid 1", "", "sbreload"),
                ("6 1", "6>&-", "sbreload"),
            ):
                with self.subTest(script=name, cydia=cydia, descriptor=descriptor):
                    shell = ("set -e\nRCTL_PREFIX=/var/jb\n"
                             "killall() { echo UNEXPECTED_RESTART; }\n" +
                             helper.group() + "\nrequest_gui_restart " + descriptor)
                    result = subprocess.run(["/bin/sh", "-c", shell],
                                            env={"CYDIA": cydia}, text=True,
                                            capture_output=True, check=True)
                    self.assertIn(expected, result.stdout)
                    self.assertNotIn("UNEXPECTED_RESTART", result.stdout)
            # Preserve the existing rootful/manual deployment behavior.
            result = subprocess.run(["/bin/sh", "-c",
                                     "RCTL_PREFIX=''\nkillall() { echo ROOTFUL_RESTART; }\n" +
                                     helper.group() + "\nrequest_gui_restart"],
                                    text=True, capture_output=True, check=True)
            self.assertEqual(result.stdout, "ROOTFUL_RESTART\n")

    def test_empty_control_client_is_rejected_in_both_lanes(self):
        for rootless in (True, False):
            self.prepare(rootless).write_text("")
            with self.assertRaisesRegex(ValueError, "control client"):
                stage_package(self.stage, "rootless" if rootless else "")

    def test_wrong_architecture_is_rejected(self):
        self.prepare()
        control = self.stage / "DEBIAN/control"
        control.write_text(control.read_text().replace("iphoneos-arm64", "iphoneos-arm"))
        with self.assertRaisesRegex(ValueError, "architecture"):
            stage_package(self.stage, "rootless")

    def test_unknown_scheme_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "unsupported package scheme"):
            stage_package(self.stage, "other")


if __name__ == "__main__":
    unittest.main()
