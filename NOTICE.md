# Notices and credits

## Enshrouded and its data

**Enshrouded** is developed and published by **Keen Games GmbH**. Enshroud Buddy is an unofficial fan tool. It
is not affiliated with, endorsed or sponsored by Keen Games.

This repository includes data taken from the game's files, for personal, non-commercial use by players who own
the game:

- `app/assets/game.json`, `data/export/`: item, recipe, skill, quest and lore names and texts, numbers and map
  positions;
- `app/assets/icons/`: item icons;
- `app/assets/skilltree/`: skill tree art;
- `app/assets/map/`, `app/assets/map_preview.jpg`, `height.png`, `shroud_levels.png`, `cold.png`: map imagery
  and grids rendered from the game's own map textures.

All of it is © Keen Games GmbH, and it is not covered by this project's license. The repository is private
while Keen Games is asked whether sharing it is fine. It will be taken down or changed on their request.

## Third-party works

| Work | Use | License |
|---|---|---|
| [Flutter](https://flutter.dev) and its plugins `shared_preferences`, `path_provider` | the app | BSD-3-Clause |
| [flutter_map](https://github.com/fleaflet/flutter_map) | the app's map | BSD-3-Clause |
| [latlong2](https://github.com/jifalops/dart-latlong) | map coordinates | Apache-2.0 |
| [Cinzel](https://github.com/NDISCOVER/Cinzel) font, © 2020 The Cinzel Project Authors | skill tree titles | SIL Open Font License 1.1 (`app/assets/fonts/OFL.txt`) |
| [pystray](https://github.com/moses-palmer/pystray) | the agent's tray icon (installed by `install.bat`, not included) | LGPL-3.0 |
| [Pillow](https://python-pillow.org) | images in the agent and tools (installed, not included) | MIT-CMU (HPND) |
| [psutil](https://github.com/giampaolo/psutil) | finding the running game (installed, not included) | BSD-3-Clause |
| [python-zstandard](https://github.com/indygreg/python-zstandard) | unpacking save files (installed, not included) | BSD-3-Clause |
| [NumPy](https://numpy.org), [SciPy](https://scipy.org) | map building tools only (not included) | BSD-3-Clause |
| [kfc-parser / EML](https://github.com/Brabb3l/kfc-parser) | runs `tools/eml-export` to export the game data (not included) | GPL-3.0 |
| [Enshrouded Wiki](https://enshrouded.wiki.gg) | text Ask may quote. Downloaded to your PC at runtime, not included | CC BY-SA 4.0 |
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) by Anthropic | answers Ask questions on your own plan (not included) | Anthropic's terms |

Each Flutter package's full license text is also in the app, under Home → Setup → licenses (Flutter's
license page).

## Thanks

- To the EML / kfc-parser authors, whose loader made the data export possible.
- To the Enshrouded wiki editors.
- To Keen Games for the game.
