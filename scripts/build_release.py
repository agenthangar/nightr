#!/usr/bin/env python3
"""Build, sign, notarize and verify the actual universal Nightr release.

Requires genuine Developer ID Application and Installer identities and an
existing notarytool keychain profile. Never creates unsigned release artifacts.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import notary_checkpoint

ROOT = Path(__file__).resolve().parent.parent

def phase(message):
    print(message, file=sys.stderr, flush=True)

def run(*args, **kwargs):
    # Retain compiler, signing and notary diagnostics on failure. Arguments never
    # include certificate passwords or private keys; credential import is CI-only.
    try:
        result = subprocess.run([str(a) for a in args], text=True, capture_output=True,
                                check=True, timeout=kwargs.pop("timeout", 600), **kwargs)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        for output in (error.stdout, error.stderr):
            if output:
                phase((output.decode(errors="replace") if isinstance(output, bytes) else output)[-32768:])
        raise
    if result.stderr: phase(result.stderr[-32768:])
    return result.stdout.strip()

def runtime(lock, destination):
    for arch, item in lock["architectures"].items():
        with tempfile.TemporaryDirectory(prefix="nightr-python-") as temporary:
            archive = Path(temporary) / "runtime.tar.gz"
            with urllib.request.urlopen(item["url"], timeout=60) as source, archive.open("wb") as output:
                shutil.copyfileobj(source, output)
            with archive.open("rb") as source:
                digest = hashlib.file_digest(source, "sha256").hexdigest()
            if digest != item["sha256"]: raise RuntimeError("Bundled runtime checksum mismatch")
            with tarfile.open(archive) as bundle:
                bundle.extractall(temporary, filter="data")
            shutil.copytree(Path(temporary) / "python", destination / arch, symlinks=True)
    (destination / "bin").mkdir()
    shutil.copy2(ROOT / "packaging/python3", destination / "bin/python3")
    (destination / "bin/python3").chmod(0o755)

def sign(path, identity, identifier=None):
    arguments = ["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity]
    if identifier: arguments += ["--identifier", identifier]
    run(*arguments, path)

def create_cli_alias(macos):
    # Contents/MacOS is a code directory. Use the signed Mach-O directly rather
    # than a shell wrapper whose extended-attribute signature would not survive
    # all package transports. The app signature seals this internal link.
    (macos / "nightr").symlink_to("nightr-native")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--resume-run-id")
    args = parser.parse_args()
    if sys.platform != "darwin" or not re.fullmatch(r"0\.[0-9]+\.[0-9]+", args.version):
        parser.error("A macOS host and stable patch version are required")
    names = ["NIGHTR_TEAM_ID", "NIGHTR_APPLICATION_IDENTITY", "NIGHTR_INSTALLER_IDENTITY", "NIGHTR_NOTARY_PROFILE"]
    settings = {key: os.environ.get(key, "") for key in names}
    if not all(settings.values()) or not re.fullmatch(r"[A-Z0-9]{10}", settings["NIGHTR_TEAM_ID"]):
        parser.error("Genuine Developer ID application/installer signing and notarization configuration is required")
    team = settings["NIGHTR_TEAM_ID"]
    for key in ["NIGHTR_APPLICATION_IDENTITY", "NIGHTR_INSTALLER_IDENTITY"]:
        if f"({team})" not in settings[key]: parser.error("Signing identities must match the configured team")
    identities = run("/usr/bin/security", "find-identity", "-v")
    if settings["NIGHTR_APPLICATION_IDENTITY"] not in identities or settings["NIGHTR_INSTALLER_IDENTITY"] not in identities:
        parser.error("Both genuine Developer ID identities must be installed in the build keychain")
    args.output.mkdir(parents=True, exist_ok=True)
    checkpoint = notary_checkpoint.Checkpoint(args.output / "checkpoint", args.version, team, resume_run_id=args.resume_run_id)
    with tempfile.TemporaryDirectory(prefix="nightr-release-") as temporary:
        stage = Path(temporary)
        if not args.resume_run_id:
            source_root = stage / "source"
            source_root.mkdir()
            shutil.copy2(ROOT / "Package.swift", source_root / "Package.swift")
            for directory in ["Sources", "native-tests", "packaging"]:
                shutil.copytree(ROOT / directory, source_root / directory, symlinks=True)
            policy = source_root / "Sources/NightrInstallerGuard/BuildPolicy.swift"
            policy.write_text("enum BuildPolicy { static let teamID = " + json.dumps(team) + "; static let version = " + json.dumps(args.version) + " }\n")
            scratch = stage / "build"
            phase("Building universal native targets")
            run("/usr/bin/swift", "build", "--package-path", source_root, "--scratch-path", scratch, "-c", "release", "--arch", "arm64", "--arch", "x86_64")
            binaries = Path(run("/usr/bin/swift", "build", "--package-path", source_root, "--scratch-path", scratch, "-c", "release", "--arch", "arm64", "--arch", "x86_64", "--show-bin-path"))
            app = stage / "Nightr.app"
            macos = app / "Contents/MacOS"; resources = app / "Contents/Resources"
            macos.mkdir(parents=True); resources.mkdir()
            for source, target in [("NightrApp", "NightrApp"), ("nightr-native", "nightr-native"), ("NightrPowerHelper", "nightr-powerhelper"), ("NightrNetworkWorker", "NightrNetworkWorker")]:
                shutil.copy2(binaries / source, macos / target)
                architectures = run("/usr/bin/lipo", "-archs", macos / target).split()
                if sorted(architectures) != ["arm64", "x86_64"]: raise RuntimeError(f"Non-universal binary: {target}")
            create_cli_alias(macos)
            daemon = app / "Contents/Library/LaunchDaemons"; daemon.mkdir(parents=True)
            shutil.copy2(ROOT / "packaging/ai.nightr.powerhelper.plist", daemon)
            agents = app / "Contents/Library/LaunchAgents"; agents.mkdir(parents=True)
            shutil.copy2(ROOT / "packaging/ai.nightr.agent.plist", agents)
            shutil.copytree(ROOT / "libexec", resources / "libexec")
            shutil.copy2(ROOT / "scripts/nightr_install.py", resources / "libexec/nightr_install.py")
            shutil.copytree(ROOT / "zsh", resources / "zsh")
            shutil.copy2(ROOT / "LICENSE", resources / "LICENSE")
            shutil.copy2(ROOT / "packaging/homebrew-contract.json", resources / "homebrew-contract.json")
            icon_renderer = resources / "render-nightr-icon"
            run("/usr/bin/swiftc", "-parse-as-library", ROOT / "Sources/NightrCore/MoonSparkArtwork.swift", ROOT / "scripts/render_icon.swift", "-o", icon_renderer)
            run(icon_renderer, resources / "Nightr.icns")
            icon_renderer.unlink()
            phase("Downloading checksum-pinned standalone Python runtimes")
            runtime(json.loads((ROOT / "packaging/runtime-lock.json").read_text()), resources / "runtime")
            info = {"CFBundleIdentifier": "ai.nightr.app", "CFBundleName": "Nightr", "CFBundleDisplayName": "Nightr",
                    "CFBundleExecutable": "NightrApp", "CFBundleIconFile": "Nightr", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": args.version,
                    "CFBundleVersion": args.version, "LSMinimumSystemVersion": "13.0", "LSUIElement": True,
                    "NSHighResolutionCapable": True, "NightrTeamID": team, "NightrProtocolVersion": 1,
                    "NSLocationWhenInUseUsageDescription": "Nightr uses location permission to show nearby Wi-Fi names when you choose a hotspot."}
            with (app / "Contents/Info.plist").open("wb") as output: plistlib.dump(info, output)
            phase("Signing app and bundled executables")
            # Sign every standalone Python Mach-O before signing its enclosing app.
            magic = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}
            for path in sorted((resources / "runtime").rglob("*")):
                if path.is_file() and not path.is_symlink():
                    with path.open("rb") as source: header = source.read(4)
                    if header in magic: sign(path, settings["NIGHTR_APPLICATION_IDENTITY"])
            for binary, identifier in [("nightr-native", "ai.nightr.controller"), ("nightr-powerhelper", "ai.nightr.powerhelper"), ("NightrNetworkWorker", "ai.nightr.networkworker")]:
                sign(macos / binary, settings["NIGHTR_APPLICATION_IDENTITY"], identifier)
            sign(app, settings["NIGHTR_APPLICATION_IDENTITY"], "ai.nightr.app")
            run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures", app)
            # Notarize/staple the app independently so its DMG copy is assessable.
            appzip = stage / "Nightr.zip"
            run("/usr/bin/ditto", "-c", "-k", "--keepParent", app, appzip)
            guard_binary = stage / "ai.nightr.installguard"
            shutil.copy2(binaries / "NightrInstallerGuard", guard_binary)
            sign(guard_binary, settings["NIGHTR_APPLICATION_IDENTITY"], "ai.nightr.installguard")
            guard_arches = run("/usr/bin/lipo", "-archs", guard_binary).split()
            if sorted(guard_arches) != ["arm64", "x86_64"]: raise RuntimeError("Installer guard is not universal")
            checkpoint.retain("app", appzip)
            checkpoint.retain("guard", guard_binary)
        else:
            appzip = checkpoint.path("app")
            notary_checkpoint.validate_app_zip(appzip)
            run("/usr/bin/ditto", "-x", "-k", appzip, stage)
            app = stage / "Nightr.app"
            guard_binary = stage / "ai.nightr.installguard"
            shutil.copy2(checkpoint.path("guard"), guard_binary)
            notary_checkpoint.verify_restored(app, guard_binary, team, args.version, run)
            guard_binary.chmod(0o755)
            if checkpoint.has("package"):
                notary_checkpoint.verify_package(checkpoint.path("package"), team, args.version, run)
            if checkpoint.has("dmg"):
                requirement = f'anchor apple generic and certificate leaf[subject.OU] = "{team}"'
                run("/usr/bin/codesign", "--verify", "--strict", "-R=" + requirement, checkpoint.path("dmg"))
        checkpoint.notarize("app", settings["NIGHTR_NOTARY_PROFILE"], run)
        run("/usr/bin/xcrun", "stapler", "staple", app)
        run("/usr/bin/xcrun", "stapler", "validate", app)
        notary_checkpoint.verify_restored(app, guard_binary, team, args.version, run)
        package = stage / "Nightr.pkg"
        if checkpoint.has("package"):
            shutil.copy2(checkpoint.path("package"), package)
        else:
            package_scripts = stage / "package-scripts"
            shutil.copytree(ROOT / "packaging/package-scripts", package_scripts)
            shutil.copy2(guard_binary, package_scripts / "ai.nightr.installguard")
            payload = stage / "payload"; (payload / "Applications").mkdir(parents=True)
            shutil.copytree(app, payload / "Applications/Nightr.app", symlinks=True)
            (payload / "usr/local/bin").mkdir(parents=True)
            (payload / "usr/local/bin/nightr").symlink_to("/Applications/Nightr.app/Contents/MacOS/nightr")
            privileged = payload / "Library/PrivilegedHelperTools"; privileged.mkdir(parents=True)
            shutil.copy2(guard_binary, privileged / "ai.nightr.installguard")
            # Root-owned state/lock files are intentionally outside the payload.
            # Canonical app replacement must also permit a verified rollback.
            components = stage / "components.plist"
            with components.open("wb") as output:
                plistlib.dump([{"RootRelativeBundlePath": "Applications/Nightr.app", "BundleIsRelocatable": False,
                               "BundleIsVersionChecked": False, "BundleHasStrictIdentifier": True,
                               "BundleOverwriteAction": "upgrade"}], output)
            unsigned = stage / "unsigned.pkg"
            phase("Building signed installer package")
            run("/usr/bin/pkgbuild", "--root", payload, "--identifier", "ai.nightr.package", "--version", args.version, "--install-location", "/", "--ownership", "recommended", "--component-plist", components, "--scripts", package_scripts, unsigned)
            run("/usr/bin/productsign", "--sign", settings["NIGHTR_INSTALLER_IDENTITY"], "--timestamp", unsigned, package)
            checkpoint.retain("package", package)
        checkpoint.notarize("package", settings["NIGHTR_NOTARY_PROFILE"], run)
        run("/usr/bin/xcrun", "stapler", "staple", package)
        run("/usr/bin/xcrun", "stapler", "validate", package)
        name = f"Nightr-{args.version}-universal.dmg"; dmg = args.output / name
        if checkpoint.has("dmg"):
            shutil.copy2(checkpoint.path("dmg"), dmg)
        else:
            image = stage / "image"; image.mkdir()
            shutil.copytree(app, image / "Nightr.app", symlinks=True); shutil.copy2(package, image / "Nightr.pkg")
            (image / "Install Nightr.txt").write_text("Open Nightr.pkg to install the signed app and command. Then open Nightr and choose Set up to explicitly authorize its power helper. Protection starts only when you enable it.\n")
            run("/usr/bin/hdiutil", "create", "-volname", "Nightr", "-srcfolder", image, "-format", "UDZO", "-ov", dmg)
            sign(dmg, settings["NIGHTR_APPLICATION_IDENTITY"])
            checkpoint.retain("dmg", dmg)
        checkpoint.notarize("dmg", settings["NIGHTR_NOTARY_PROFILE"], run)
        run("/usr/bin/xcrun", "stapler", "staple", dmg); run("/usr/bin/xcrun", "stapler", "validate", dmg)
        phase("Verifying final signed DMG read-only")
        run(sys.executable, ROOT / "scripts/verify_release.py", "--dmg", dmg, "--team-id", team, "--version", args.version)
        with dmg.open("rb") as source: digest = hashlib.file_digest(source, "sha256").hexdigest()
        manifest = {"schemaVersion": 1, "version": args.version, "platform": "macos", "minVersion": "13.0", "architectures": ["arm64", "x86_64"],
                    "teamID": team, "bundleID": "ai.nightr.app", "controllerID": "ai.nightr.controller", "helperID": "ai.nightr.powerhelper", "protocolVersion": 1,
                    "asset": {"name": name, "url": f"https://github.com/agenthangar/nightr/releases/download/v{args.version}/{name}", "sha256": digest, "size": dmg.stat().st_size}}
        template = (ROOT / "packaging/nightr.rb.in").read_text()
        (args.output / "nightr.rb").write_text(template.replace("{{VERSION}}", args.version).replace("{{SHA256}}", digest))
        (args.output / "nightr-release.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return 0
if __name__ == "__main__": raise SystemExit(main())
