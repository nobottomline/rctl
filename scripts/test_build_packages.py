#!/usr/bin/env python3
"""Exercise build orchestration with a fake compiler and real Debian metadata."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class BuildPackagesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        (self.root / "bin").mkdir()
        source = Path(__file__).resolve().parent
        for script in ("build-packages.sh", "build-rootless.sh"):
            shutil.copy2(source / script, self.root / "scripts" / script)
        (self.root / "control").write_text("Version: 0.3.4\n")
        self.executable("scripts/release_check.sh", "#!/bin/sh\nexit 0\n")
        self.executable("bin/git", "#!/bin/sh\nprintf '123456789abc\\n'\n")
        self.executable("bin/make", '''#!/usr/bin/env python3
import os, pathlib, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[2])
args = dict(arg.split('=', 1) for arg in sys.argv[3:] if '=' in arg)
arch = 'iphoneos-arm64' if args['THEOS_PACKAGE_SCHEME'] == 'rootless' else 'iphoneos-arm'
out = root / 'packages'
if arch == 'iphoneos-arm64': out /= 'rootless'
out.mkdir(parents=True, exist_ok=True)
version = args['PACKAGE_VERSION']
with tempfile.TemporaryDirectory() as temp:
    control = pathlib.Path(temp) / 'DEBIAN'
    control.mkdir()
    metadata_arch = 'all' if os.getenv('CORRUPT_BUILD') else arch
    (control / 'control').write_text(f'Package: com.greatlove.rctl\\nVersion: {version}\\nArchitecture: {metadata_arch}\\nMaintainer: Test\\nDescription: fixture\\n')
    subprocess.run(['dpkg-deb', '-b', temp, str(out / f'com.greatlove.rctl_{version}_{arch}.deb')], check=True, stdout=subprocess.DEVNULL)
''')
        self.env = dict(os.environ, PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"], THEOS=str(self.root))

    def executable(self, name, contents):
        path = self.root / name
        path.write_text(contents)
        path.chmod(0o755)

    def run_build(self, *args, wrapper="build-packages.sh"):
        return subprocess.run([str(self.root / "scripts" / wrapper), *args], env=self.env, capture_output=True, text=True)

    def test_both_architectures_share_explicit_version(self):
        result = self.run_build("--version", "0.4.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(p.name for p in (self.root / "packages").rglob("*.deb")), [
            "com.greatlove.rctl_0.4.0_iphoneos-arm.deb", "com.greatlove.rctl_0.4.0_iphoneos-arm64.deb"])
        for package in (self.root / "packages").rglob("*.deb"):
            version = subprocess.check_output(["dpkg-deb", "-f", str(package), "Version"], text=True).strip()
            for previous in ("0.3.4", "0.3.4~rootless14", "0.4.0~rc.4"):
                self.assertEqual(subprocess.run(["dpkg", "--compare-versions", version, "gt", previous]).returncode, 0)

    def test_default_version_upgrades_legacy_candidate(self):
        result = self.run_build(wrapper="build-rootless.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        packages = list((self.root / "packages").rglob("*.deb"))
        self.assertEqual(len(packages), 1)
        version = subprocess.check_output(["dpkg-deb", "-f", str(packages[0]), "Version"], text=True).strip()
        self.assertRegex(version, r"^0\.3\.4~test\.\d{14}\.123456789abc$")
        for operator, other in (("gt", "0.3.4~rootless14"), ("lt", "0.3.4")):
            self.assertEqual(subprocess.run(["dpkg", "--compare-versions", version, operator, other]).returncode, 0)

    def test_invalid_inputs_and_wrong_build_are_rejected(self):
        for args in (("--scheme", "roothide"), ("--version", "../0.3.5"), ("--version",), ("--install",)):
            self.assertNotEqual(self.run_build(*args).returncode, 0)
        self.env["CORRUPT_BUILD"] = "1"
        self.assertNotEqual(self.run_build("--version", "0.3.5").returncode, 0)


class WebStagingTest(unittest.TestCase):
    """Run the real staging recipe with isolated Theos and npm fixtures."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        source = Path(__file__).resolve().parent.parent
        for directory in ("mk", "theos/makefiles", "bin", "audio", "obj",
                          "web/src", "web/dist", "web/node_modules"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / "Makefile", self.root / "Makefile")
        shutil.copy2(source / "mk/native-target.mk", self.root / "mk/native-target.mk")
        for include in ("common.mk", "aggregate.mk"):
            (self.root / "theos/makefiles" / include).touch()
        (self.root / "theos/makefiles/common.mk").write_text(
            "SHELL := /bin/bash\nECHO_NOTHING = @(\nECHO_END = )\n")
        (self.root / "audio/Makefile").write_text("all:\n\t@true\n")
        for name in ("rctlappmedia.dylib", "rctlaudio.dylib"):
            (self.root / "obj" / name).write_text("native fixture\n")
        (self.root / "audio/rctlaudio.plist").write_text("plist fixture\n")
        (self.root / "control").write_text("Version: 0.4.0\n")
        for name in ("index.html", "package.json"):
            (self.root / "web" / name).write_text("fixture\n")
        stale = self.root / "web/dist/index.html"
        stale.write_text("Version: 0.3.4\n")
        # Even a newer cached output must not hide changed external inputs.
        os.utime(stale, (2000000000, 2000000000))
        npm = self.root / "bin/npm"
        npm.write_text('''#!/bin/sh
set -eu
test "$*" = "run build"
test "${FAIL_WEB_BUILD:-0}" != 1
cp ../control dist/index.html
''')
        npm.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"])

    def stage(self, scheme):
        staging = self.root / ("stage-" + (scheme or "rootful"))
        (staging / "Library/MobileSubstrate/DynamicLibraries").mkdir(parents=True)
        result = subprocess.run([
            "make", "after-stage", "THEOS=" + str(self.root / "theos"),
            "THEOS_PACKAGE_SCHEME=" + scheme, "THEOS_STAGING_DIR=" + str(staging),
            "THEOS_OBJ_DIR=" + str(self.root / "obj"),
        ], cwd=self.root, env=self.env, capture_output=True, text=True)
        path = "usr/local/share/rctl/web" if scheme else "var/mobile/rctl"
        return result, staging / path / "index.html"

    def test_both_lanes_refresh_cached_client(self):
        for scheme in ("", "rootless"):
            with self.subTest(scheme=scheme):
                (self.root / "web/dist/index.html").write_text("Version: 0.3.4\n")
                os.utime(self.root / "web/dist/index.html", (2000000000, 2000000000))
                result, artifact = self.stage(scheme)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(artifact.read_text(), "Version: 0.4.0\n")

    def test_failed_build_cannot_package_stale_client(self):
        self.env["FAIL_WEB_BUILD"] = "1"
        for scheme in ("", "rootless"):
            with self.subTest(scheme=scheme):
                result, artifact = self.stage(scheme)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(artifact.exists())


if __name__ == "__main__":
    unittest.main()
