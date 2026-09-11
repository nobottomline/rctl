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
        result = self.run_build("--version", "0.3.5")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(p.name for p in (self.root / "packages").rglob("*.deb")), [
            "com.greatlove.rctl_0.3.5_iphoneos-arm.deb", "com.greatlove.rctl_0.3.5_iphoneos-arm64.deb"])

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


if __name__ == "__main__":
    unittest.main()
