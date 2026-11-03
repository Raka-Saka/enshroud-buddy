"""Where the agent finds its files, from source or as the one-file EnshroudBuddy.exe (tools/build_agent.py).

RES holds what it only reads (app/assets/game.json, height map, data/export): the repo from source, the exe's
unpacked bundle when frozen. DATA holds what it writes (config.json with the pairing code, logs, history,
traces, the Ask workspace): agent/ from source, %LOCALAPPDATA%/EnshroudBuddy for the exe.
"""
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FROZEN = bool(getattr(sys, "frozen", False))
RES = pathlib.Path(getattr(sys, "_MEIPASS", ROOT))
DATA = pathlib.Path(os.environ.get("LOCALAPPDATA", pathlib.Path.home())) / "EnshroudBuddy" if FROZEN else ROOT / "agent"
DATA.mkdir(parents=True, exist_ok=True)
EXPORT = RES / "data" / "export"
