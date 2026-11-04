"""Prints the licence texts of Python, Tcl/Tk and the named packages, as installed in the Python running it.

    build/agent-venv/Scripts/python.exe tools/licences_dump.py pystray,six,pillow   # used by build_agent.py
"""
import importlib.metadata as md
import pathlib
import sys

KEYS = ("LICENSE", "LICENCE", "COPYING", "NOTICE")


def section(title, text):
    return "=" * 78 + "\n" + title + "\n" + "=" * 78 + "\n" + text.strip() + "\n"


def main():
    out = []
    base = pathlib.Path(sys.base_prefix)
    out.append(section(f"Python {sys.version.split()[0]} (Python Software Foundation License)",
                       (base / "LICENSE.txt").read_text(encoding="utf-8", errors="replace")))
    for t in sorted((base / "tcl").glob("t*8*/license.terms")):
        out.append(section(f"Tcl/Tk ({t.parent.name}; Tcl is under the same terms)", t.read_text(encoding="utf-8", errors="replace")))
    for name in sys.argv[1].split(","):
        d = md.distribution(name)
        meta = d.metadata
        files = [f for f in (d.files or []) if any(k in f.name.upper() for k in KEYS)]
        texts = [pathlib.Path(f.locate()).read_text(encoding="utf-8", errors="replace") for f in files]
        lic = (meta.get("License-Expression") or meta.get("License") or "").splitlines()
        home = meta.get("Home-page") or next(
            (u.split(", ", 1)[-1] for u in meta.get_all("Project-URL") or []), "")
        head = f"{meta['Name']} {d.version}" + (f" ({lic[0][:80]})" if lic else "")
        body = (f"Source: {home}\n\n" if home else "") + ("\n\n".join(texts) or "(no licence file in the package)")
        out.append(section(head, body))
    sys.stdout.write("\n".join(out))


if __name__ == "__main__":
    main()
