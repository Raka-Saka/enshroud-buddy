# Notices and credits

## Enshrouded and its data

**Enshrouded** is developed and published by **Keen Games GmbH**. *Unofficial fan project. Not affiliated with or endorsed by Keen Games. Enshrouded and its content are the property of Keen Games GmbH.*

Enshroud Buddy follows Keen Games' Enshrouded Fan Project Guidelines (November 2026): it is free for everyone,
with nothing behind a payment.

This repository includes Keen Games' content, for free use by players who own the game:

- `app/assets/game.json`, `data/export/`: item, recipe, skill, quest and lore names and texts, numbers and map
  positions, taken from the game's files;
- `app/assets/icons/`: item icons, the game's own art as kept on the [Enshrouded wiki](https://enshrouded.wiki.gg)
  (the game draws most of them at runtime, so its files don't hold them);
- `app/assets/skilltree/`: skill tree art;
- `app/assets/map/`, `app/assets/map_preview.jpg`, `height.png`, `shroud_levels.png`, `cold.png`: map imagery
  and grids rendered from the game's own map textures.

All of it is © Keen Games GmbH, and it is not covered by this project's license. Keen Games tolerates this use
under its Fan Project Guidelines and can withdraw that at any time; anything will be changed or removed on their
request.

## Third-party works

| Work | Use | License |
|---|---|---|
| [Flutter](https://flutter.dev) and its plugins `shared_preferences`, `path_provider` | the app | BSD-3-Clause |
| [flutter_map](https://github.com/fleaflet/flutter_map) | the app's map | BSD-3-Clause |
| [latlong2](https://github.com/jifalops/dart-latlong) | map coordinates | Apache-2.0 |
| [Cinzel](https://github.com/NDISCOVER/Cinzel) font, © 2020 The Cinzel Project Authors | skill tree titles | SIL Open Font License 1.1 (`app/assets/fonts/OFL.txt`) |
| [pystray](https://github.com/moses-palmer/pystray) | the agent's tray icon | LGPL-3.0 |
| [Pillow](https://python-pillow.org) | images in the agent and tools | MIT-CMU (HPND) |
| [psutil](https://github.com/giampaolo/psutil) | finding the running game | BSD-3-Clause |
| [python-zstandard](https://github.com/indygreg/python-zstandard) | unpacking save files | BSD-3-Clause |
| [qrcode](https://github.com/lincolnloop/python-qrcode), [six](https://github.com/benjaminp/six) | the pairing QR code | BSD, MIT |
| [Python](https://www.python.org), Tcl/Tk, [PyInstaller](https://pyinstaller.org) bootloader | run the agent as `EnshroudBuddy.exe` | PSF, Tcl/Tk, GPL with bootloader exception |
| AndroidX, Kotlin standard library | the Android app | Apache-2.0 |
| [Google code scanner](https://developers.google.com/ml-kit/vision/barcode-scanning/code-scanner) (Play services) | QR pairing in the app | Google APIs Terms, ML Kit Terms |
| [NumPy](https://numpy.org), [SciPy](https://scipy.org) | map building tools only (not included) | BSD-3-Clause |
| [kfc-parser / EML](https://github.com/Brabb3l/kfc-parser) | runs `tools/eml-export` to export the game data (not included) | GPL-3.0 |
| [Enshrouded Wiki](https://enshrouded.wiki.gg) | pages Ask reads when a question needs them (not included); the item icons' source | the wiki's own terms (its Copyrights page); the icons are Keen Games' art |
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) by Anthropic | answers Ask questions on your own plan (not included) | Anthropic's terms |

The packages above go into the release files as follows. `EnshroudBuddy.exe` bundles Python, Tcl/Tk and the
agent's packages; their full licence texts are in `THIRD_PARTY_LICENSES.txt`, inside the exe (tray menu →
Licences) and next to it on each release (pystray's source: its link above; the exe can be rebuilt with another
version of it, `python tools/build_agent.py`). The app's licences, Flutter's packages and the Android libraries
included, are under Home → Setup → Licenses and credits.

## Thanks

- To the EML / kfc-parser authors, whose loader made the data export possible.
- To the Enshrouded wiki editors.
- To Keen Games for the game.
