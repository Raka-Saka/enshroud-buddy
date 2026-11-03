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

> **Status: private preview.** The app carries data taken from the game's files (names, texts, icons, map
> art), which belong to Keen Games. This repository stays private until Keen says whether sharing it is fine.
> Please don't pass the files on. See [NOTICE.md](NOTICE.md).

## What you need

- A Windows PC with Enshrouded on Steam.
- **Python 3.10 or newer** from [python.org](https://www.python.org/downloads/). Tick **"Add python.exe to PATH"**
  in its installer.
- An Android phone on the same home network as the PC.

## Install

### On the PC (once)

1. Download this repository: **Code → Download ZIP** on GitHub, then unzip it somewhere that stays put (for
   example `Documents\EnshroudBuddy`).
2. Open the `agent` folder and run **`install.bat`**. It installs four Python packages, and can start the
   agent with Windows.
3. Run **`start.bat`**. A small round icon appears in the tray (bottom right, maybe under the `^` arrow).
4. If Windows asks whether Python may use the network, allow **Private networks**. That's how the phone
   reaches it.
5. Right-click the tray icon. The first lines show the **Phone address**, something like `192.168.1.20:4750`,
   and the **Pairing code**, like `K7PM-3QXD`. A PC on both cable and Wi-Fi shows two addresses; either can
   work.

### On the phone

1. Get **`release/enshroudbuddy.apk`** onto the phone: download it from GitHub in the phone's browser (signed
   in), or copy it over by cable or cloud drive.
2. Open it and allow the install ("install unknown apps" for your browser or file app).
3. Open the app, tap the **gear icon** on Home (Setup), enter the Phone address and the Pairing code, and
   tap **Connect**.
4. In **Game save**, pick your world and character, then **Read this save**. The rest of the app fills in
   within seconds, and again after every game save (about every 30 s while you play).

## Good to know

- **Only your phone gets in.** The agent answers only devices on your home network that send its pairing code,
  so other devices, and web pages open in a browser, get nothing: no inventory, position or questions on your
  Claude plan. The code is made once per PC and kept in `agent\config.json`. Delete that file to make a new one.

- **The agent only reads.** It copies your save files and reads the copies; it never changes a save or the
  game's files.
- **Live position** (your arrow on the map, the guide, glide measuring) reads the running game's memory,
  read-only, about once a second. It never writes to the game, injects anything or touches other players.
  Whether Enshrouded's anti-cheat could mind this isn't known. If you'd rather not take that chance,
  open `start.bat` in Notepad and add `--no-live` after both `agent.py`. Everything else keeps working from
  your saves.
- **Playing in a friend's world:** the world is saved on the host's PC, so your PC only has your character.
  You'll see your gear and map, but not their bases and chests.
- **Ask** needs [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and signed in on the PC
  (it runs on your own Claude plan). The agent then keeps a local copy of the
  [Enshrouded wiki](https://enshrouded.wiki.gg) for it, refreshed weekly. Without Claude Code, Ask just says it
  isn't available.
- **Privacy:** everything stays on your home network. Only Ask (through Claude Code) and the weekly wiki copy
  go online.

## Troubleshooting

- **"Agent unreachable":** the agent must be running (tray icon), the phone on the same network, and the
  address typed exactly with `:4750`. A PC with two addresses: try the other one. Check that Windows Firewall
  allows Python on private networks.
- **Wrong character or world:** Setup → Game save.
- **An amber notice on Home** means the save holds something new to the reader (often after a game patch).
  Most things keep working; a fix comes with the next version.
- The agent writes a log to `agent\agent.log`.

## For developers

- `app/` is the Flutter app (`flutter build apk --release`).
- `agent/agent.py` is the PC agent.
- `tools/` holds the save reader (`ksd.py`, `state.py`) and the live position (`livepos.py`, `motion.py`,
  `glide.py`).
- `tools/build_db.py` and `tools/build_map.py` turn a game-data export (`tools/eml-export`, run with the
  [EML loader](https://github.com/Brabb3l/kfc-parser)) into the app's assets.
- `tools/release.py` assembles this repository.
