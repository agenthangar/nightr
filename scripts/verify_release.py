#!/usr/bin/env python3
"""Read-only verification of the actual mounted notarized release (no install)."""
import argparse
from pathlib import Path
import subprocess
import tempfile
import nightr_install

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dmg", required=True, type=Path)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    nightr_install.run(["/usr/bin/codesign", "--verify", "--strict", "-R", f'anchor apple generic and certificate leaf[subject.OU] = "{args.team_id}"', args.dmg])
    nightr_install.run(["/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", args.dmg])
    nightr_install.run(["/usr/bin/xcrun", "stapler", "validate", args.dmg])
    with tempfile.TemporaryDirectory(prefix="nightr-verify-") as temporary:
        with nightr_install.mounted_dmg(args.dmg, Path(temporary)) as mount:
            app = mount / "Nightr.app"
            nightr_install.verify_app(app, args.team_id, args.version)
            nightr_install.verify_package(mount / "Nightr.pkg", args.team_id)
            nightr_install.run(["/usr/bin/xcrun", "stapler", "validate", mount / "Nightr.pkg"])
            for name in ["NightrApp", "nightr-native", "nightr-powerhelper", "NightrNetworkWorker"]:
                output = nightr_install.run(["/usr/bin/lipo", "-archs", app / "Contents/MacOS" / name])
                if sorted(output.split()) != ["arm64", "x86_64"]:
                    raise RuntimeError("Release binary is not universal: " + name)
            # No app launch: validate both bundled interpreters without loading UI
            # or touching real HOME; config/editor modules are compiled offline.
            resources = app / "Contents/Resources"
            for arch in ["arm64", "x86_64"]:
                interpreter = resources / "runtime" / arch / "bin/python3"
                nightr_install.run(["/usr/bin/codesign", "--verify", "--strict", interpreter])
                if not interpreter.exists(): raise RuntimeError("Bundled runtime is missing: " + arch)
            if not (resources / "libexec/nightr_install.py").is_file(): raise RuntimeError("Package installer is missing")
    print("Verified signed universal app, helper, controller, runtimes, installer and stapled DMG")
    return 0
if __name__ == "__main__": raise SystemExit(main())
