# Enshroud Buddy

A companion for **Enshrouded** on your Android phone, fed by a small agent on your gaming PC. It reads your save
files and shows your game on the phone, while you play or away from the PC:

- **Map** with every place, chest, lore note, fishing spot and Shroud Root, your explored area, Shroud levels
  and cold zones, your bases, and your own pins. With the game running it shows where you are, and the
  **guide** leads you to a place. It tells on foot from gliding, checks whether a glide reaches against the
  terrain, and suggests higher ground to launch from.
- **Unique loot**: search any piece that lies in a chest, or a whole set ("Farmer Set", cosmetics too), and
  the map shows only where it is. "Unique loot only" shows what you're still missing, by kind. Each chest
  says how high it is: under the surface (caves, cellars, the sea floor), on an island, or above or below you.
- **Hollow Halls**: each hall's floor plan (your floor bright when you're inside), what's left to find there
  against what you already have, its quests, and a check before you go: level, gear, damage the Hollow
  resist or fear, grappling hook, healing.
- **Character**: your gear, bag and every chest (search across all of them), bases and stations, build and
  skill tree with gear advice for your level, survival numbers (Shroud time, cold, breath), and your progress
  over time.
- **Plan**: pick what you want to make; it lists what to gather, craft and fetch, and where, nearest first,
  with a farming route.
- **Codex**: every item, recipe, set, lore page and quest from the game's own data; find gear by the skill or
  stat it gives.
- **Ask** (optional): questions about your game answered by Claude, from your save and the game data.

<p align="center">
  <img src="docs/screenshots/home.png" width="160" alt="Home">
  <img src="docs/screenshots/map.png" width="160" alt="Map with unique loot">
  <img src="docs/screenshots/build.png" width="160" alt="Character build">
  <img src="docs/screenshots/skill-tree.png" width="160" alt="Skill tree">
  <img src="docs/screenshots/base-3d.png" width="160" alt="A base in 3D">
  <img src="docs/screenshots/codex.png" width="160" alt="Codex">
</p>

> *Unofficial fan project. Not affiliated with or endorsed by Keen Games. Enshrouded and its content are the property of Keen Games GmbH.*
>
> Free for everyone, under Keen Games' Fan Project Guidelines. See [NOTICE.md](NOTICE.md).

## What you need

- A Windows PC with Enshrouded on Steam.
- An Android phone on the same home network (Wi-Fi) as the PC.

## Install

Both files are on the **[latest release](../../releases/latest)** page.

### On the PC (once)

1. Download **`EnshroudBuddy.exe`** and open it.
2. Windows may say it "protected your PC", because the program isn't signed. Click **More info**, then
   **Run anyway**.
3. If Windows asks whether Enshroud Buddy may use the network, tick **Private networks** and allow it. That's
   how the phone reaches it.
4. A window shows a **QR code**. Keep it open for the phone.

That's all: it starts with Windows from now on, as a small round icon in the tray (bottom right, maybe under
the `^` arrow). To show the QR code again, click that icon. To remove it, right-click it, **Uninstall from this
PC**.

### On the phone

1. Open the release page in the phone's browser and tap **`EnshroudBuddy.apk`**.
2. Open the download. Android asks once to allow installs from your browser: allow it, then **Install**.
3. Open the app, tap the **gear icon** on Home (Setup), then **Scan the PC's code** and point the phone at the
   QR code.
4. In **Game save**, pick your world and character, then **Read this save**. The rest of the app fills in
   within seconds, and again after every game save (about every 30 s while you play).

### Updates

The app tells you on Home when a new version is out: tap **Update** and install over the old one, nothing is
lost. For the PC, download the new `EnshroudBuddy.exe` and open it: it replaces the old one and starts again.

## Good to know

- **Only your phone gets in.** The agent answers only devices on your home network that send its pairing code,
  so other devices, and web pages open in a browser, get nothing: no inventory, position or questions on your
  Claude plan. The code is made once per PC and kept in `config.json` (in `%LOCALAPPDATA%\EnshroudBuddy`, or
  `agent\` from source). Delete that file to make a new one.

- **The agent only reads.** It copies your save files and reads the copies; it never changes a save or the
  game's files.
- **Live position** (your arrow on the map, the guide, glide measuring) reads the running game's memory,
  read-only, about once a second. It never writes to the game, injects anything or touches other players.
  Whether Enshrouded's anti-cheat could mind this isn't known. If you'd rather not take that chance, start the
  agent with `--no-live` (from source: add it after both `agent.py` in `start.bat`). Everything else keeps
  working from your saves.
- **Playing in a friend's world:** the world is saved on the host's PC, so your PC only has your character.
  You'll see your gear and map, but not their bases and chests.
- **Ask** needs [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and signed in on the PC
  (it runs on your own Claude plan). The agent then keeps a local copy of the
  [Enshrouded wiki](https://enshrouded.wiki.gg) for it, refreshed weekly. Without Claude Code, Ask just says it
  isn't available.
- **Privacy:** everything stays on your home network. Only Ask (through Claude Code), the weekly wiki copy and
  the app's daily look for a new version on GitHub (which sends nothing about you) go online.

## Troubleshooting

- **"Agent unreachable":** the agent must be running (tray icon) and the phone on the same Wi-Fi as the PC.
  Scan the code again (click the tray icon). Check that Windows Firewall allows Enshroud Buddy (or Python, from
  source) on private networks.
- **Wrong character or world:** Setup → Game save.
- **An amber notice on Home** means the save holds something new to the reader (often after a game patch).
  Most things keep working; a fix comes with the next version.
- The agent writes a log to `agent\agent.log`.

## For developers

- `app/` is the Flutter app (`flutter build apk --release`).
- `agent/agent.py` is the PC agent. From source it needs Python 3.10 or newer: run `agent\install.bat` once,
  then `agent\start.bat`. `python tools/build_agent.py` builds `EnshroudBuddy.exe`.
- `tools/` holds the save reader (`ksd.py`, `state.py`) and the live position (`livepos.py`, `motion.py`,
  `glide.py`).
- `tools/build_db.py` and `tools/build_map.py` turn a game-data export (`tools/eml-export`, run with the
  [EML loader](https://github.com/Brabb3l/kfc-parser)) into the app's assets.
- `tools/release.py` assembles this repository.
