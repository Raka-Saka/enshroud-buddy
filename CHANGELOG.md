# Patch notes

Newest first. Each version is a [release](https://github.com/Raka-Saka/enshroud-buddy/releases) with the PC
program (`EnshroudBuddy.exe`) and the Android app (`EnshroudBuddy.apk`).

## 0.36.0 (2026-11-04)

Update both the app and the PC program: the new app only talks to the new PC program.

- **Safer pairing:** the phone and the PC sign every request with the pairing code instead of sending it, and
  the phone checks the PC's replies. Nobody else on your Wi-Fi can pick up the code or fake data.
- **Live position switch** in the tray menu, kept across updates. The PC program only looks for your position
  in the game's memory while the phone shows the map.
- **One PC program at a time:** opening it again just shows the QR code; updating closes the old one cleanly.
- Saves are read without ever stopping the game from writing them.
- Smaller downloads (history thinned), and the log no longer grows without end.
- **Ask** reads wiki pages only when a question needs them, has no general web search, and always uses your
  Claude plan, never an API key.
- Licences of everything bundled: `THIRD_PARTY_LICENSES.txt` (also in the tray menu) and the app's licence page.
  The README's privacy section now lists everything that goes online.
- The app has its own icon. Shroud and breath timers ignore world settings that read out of range.

## 0.35.0 (2026-11-04)

- **One-file PC install:** `EnshroudBuddy.exe` installs itself (no admin rights), starts with Windows and sits
  in the tray. No Python needed.
- **QR pairing:** Setup → Scan the PC's code. No more typing addresses.
- The app tells you on Home when a new version is out.

## 0.34.5 (2026-11-03)

- Renamed to Enshroud Buddy, following Keen Games' Fan Project Guidelines; Keen's disclaimer is in the app and
  the README.
