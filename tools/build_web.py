"""The app as a web page (Flutter web), for the PC agent to serve at http://PC:4750/app/ (iPhone, iPad, a
tablet, a second screen): build/web.zip, what tools/build_agent.py puts in the exe.

    python tools/build_web.py [--no-build]

Everything the page loads comes from the agent: no CDN for Flutter's engine (--no-web-resources-cdn) and no
service worker. Leaves out what the page never loads (the WebAssembly renderer, debug symbols).
"""
import argparse
import os
import pathlib
import shutil
import subprocess
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
WEB = ROOT / "app" / "build" / "web"
ZIP = ROOT / "build" / "web.zip"


def skip(rel):
    return rel.endswith(".symbols") or "/skwasm" in "/" + rel


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-build", action="store_true", help="zip app/build/web as it is")
    a = ap.parse_args()
    if not a.no_build:
        flutter = shutil.which("flutter") or "flutter"
        subprocess.run([flutter, "build", "web", "--release", "--base-href", "/app/", "--no-web-resources-cdn",
                        "--pwa-strategy=none"], cwd=ROOT / "app", check=True, shell=os.name == "nt",
                       env={**os.environ, "MSYS_NO_PATHCONV": "1"})
    ZIP.parent.mkdir(parents=True, exist_ok=True)
    n = 0
    with zipfile.ZipFile(ZIP, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for f in sorted(WEB.rglob("*")):
            rel = f.relative_to(WEB).as_posix()
            if f.is_file() and not skip(rel):
                z.write(f, rel)
                n += 1
    print(f"{ZIP}: {n} files, {ZIP.stat().st_size // 1_000_000} MB")


if __name__ == "__main__":
    main()
