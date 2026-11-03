"""Build the PC agent as one Windows program, EnshroudBuddy.exe, for players without Python.

    python tools/build_agent.py      # writes dist/EnshroudBuddy.exe

Bundles agent/agent.py with tools/, the packages in agent/requirements.txt plus qrcode, and the files the agent
reads (app/assets/game.json, the height map, the export in data/export that tools/release.py ships). Running
the exe installs it (see self_install in agent.py). Builds in its own venv (build/agent-venv) with pinned
versions, so whatever else this PC's Python has installed doesn't end up in the exe.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
WORK = ROOT / "build" / "agent"
VENV = ROOT / "build" / "agent-venv"
TOOLS = ["pyinstaller==6.17.0", "qrcode==8.2"]
DATA = ["app/assets/game.json", "app/assets/height.png", "app/assets/height.json",
        "data/export/items.jsonl", "data/export/recipes.jsonl", "data/export/skills.jsonl",
        "data/export/item_stats.jsonl", "data/export/balancing.json", "data/export/map/index.tsv"]


def icon(path):
    """The tray's round icon as the exe's icon."""
    from PIL import Image, ImageDraw

    img = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse([24, 24, 232, 232], fill=(19, 34, 42, 255), outline=(242, 163, 58, 255), width=16)
    d.polygon([(128, 56), (176, 152), (128, 200), (80, 152)], fill=(242, 163, 58, 255))
    img.save(path, sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (256, 256)])


def venv_python():
    py = VENV / "Scripts" / "python.exe"
    if not py.exists():
        subprocess.run([sys.executable, "-m", "venv", str(VENV)], check=True)
    subprocess.run([str(py), "-m", "pip", "install", "-q", "--disable-pip-version-check",
                    "-r", str(ROOT / "agent" / "requirements.txt"), *TOOLS], check=True)
    return py


def main():
    py = venv_python()
    WORK.mkdir(parents=True, exist_ok=True)
    ico = WORK / "agent.ico"
    icon(ico)
    args = [str(py), "-m", "PyInstaller", "--noconfirm", "--clean", "--onefile", "--noconsole",
            "--name", "EnshroudBuddy", "--icon", str(ico), "--distpath", str(DIST), "--workpath", str(WORK),
            "--specpath", str(WORK), "--paths", str(ROOT / "tools"),
            "--hidden-import", "pystray._win32", "--hidden-import", "PIL.ImageTk"]
    for rel in DATA:
        args += ["--add-data", f"{ROOT / rel};{pathlib.PurePosixPath(rel).parent}"]
    subprocess.run(args + [str(ROOT / "agent" / "agent.py")], check=True)
    exe = DIST / "EnshroudBuddy.exe"
    print(f"{exe} ({exe.stat().st_size / 1e6:.0f} MB)")


if __name__ == "__main__":
    main()
