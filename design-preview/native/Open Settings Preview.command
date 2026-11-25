#!/usr/bin/env python3
"""Launch the local native preview. Recompile edited views and swap them in place."""
import fcntl
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

here = Path(__file__).resolve().parent
repo = here.parents[1]
app_sources = repo / "Sources/NightrApp"
views = [here / name for name in ("SettingsPreview.swift", "PanePreview.swift", "PreviewEvents.swift")]
views += [app_sources / name for name in ("CompactSettingsForm.swift", "SettingsToolbar.swift", "HotspotJoinMode.swift",
                                           "NetworkChooser.swift", "NightrPopover.swift", "ActivityPresentation.swift",
                                           "DesktopUpdatePresentation.swift")]
key = hashlib.sha256(os.fsencode(repo)).hexdigest()[:16]
cache = Path.home() / "Library/Caches/ai.nightr.settings-preview" / key
cache.mkdir(parents=True, exist_ok=True, mode=0o700)


def publish(name, value):
    pending = cache / (name + ".tmp")
    pending.write_text(value)
    pending.replace(cache / name)


def build_view(build, products, libraries):
    module = "SettingsPreview" + str(time.time_ns())
    image = build / (module + ".dylib")
    result = subprocess.run(["swiftc", "-emit-library", "-module-name", module, "-I", products / "Modules",
                             *views, *libraries, "-o", image])
    return image if result.returncode == 0 else None


def run(check_only):
    with (cache / ("check.lock" if check_only else "watch.lock")).open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if check_only:
                sys.exit("Another preview build check is running.")
            publish("activate", str(time.time_ns()))
            return
        with tempfile.TemporaryDirectory(dir=cache) as build:
            build = Path(build)
            # The preview links individual target objects from SwiftPM's native build layout.
            swift_build = ["swift", "build", "--build-system", "native", "--scratch-path", cache / "swiftpm"]
            subprocess.run([*swift_build, "--target", "NightrPlatform"], cwd=repo, check=True)
            products = Path(subprocess.check_output([*swift_build, "--show-bin-path"], cwd=repo, text=True).strip())
            libraries = []
            for target in ("NightrCore", "NightrController", "NightrPowerProtocol", "NightrPowerClient", "NightrPlatform"):
                library = build / ("lib" + target + ".dylib")
                subprocess.run(["swiftc", "-emit-library", "-o", library, *libraries,
                                *sorted((products / (target + ".build")).glob("*.swift.o"))], check=True)
                libraries.append(library)
            host = build / "Nightr Pane Preview"
            subprocess.run(["swiftc", "-parse-as-library", here / "Host.swift", here / "PreviewEvents.swift",
                            app_sources / "MenuPopoverDismissal.swift", "-o", host], check=True)
            if check_only:
                image = build_view(build, products, libraries)
                if image is None:
                    return 1
                subprocess.run(["swift", here / "CheckProtectionLayout.swift", image], check=True)
                dismissal_check = build / "CheckDismissal"
                subprocess.run(["swiftc", "-parse-as-library", here / "CheckDismissal.swift",
                                app_sources / "MenuPopoverDismissal.swift", "-o", dismissal_check], check=True)
                subprocess.run([dismissal_check], check=True)
                return 0
            process = None
            previous = None
            try:
                while process is None or process.poll() is None:
                    signature = tuple(p.stat().st_mtime_ns if p.exists() else None for p in views)
                    if signature != previous:
                        previous = signature
                        image = build_view(build, products, libraries)
                        if image:
                            publish("revision", str(image.relative_to(cache)))
                            if process is None:
                                process = subprocess.Popen([host, cache])
                        else:
                            print("Build failed. Save a correction to reload.", flush=True)
                    time.sleep(0.4)
            finally:
                if process and process.poll() is None:
                    process.terminate()
                    process.wait()


if __name__ == "__main__":
    if sys.argv[1:] not in ([], ["--check"]):
        sys.exit("Usage: Open Settings Preview.command [--check]")
    sys.exit(run(check_only=sys.argv[1:] == ["--check"]))
