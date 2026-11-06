# Patch notes

Newest first. Each version is a [release](https://github.com/Raka-Saka/enshroud-buddy/releases) with the PC
program (`EnshroudBuddy.exe`) and the Android app (`EnshroudBuddy.apk`).

## 0.39.0 (2026-11-06)

- **iPhone, iPad and any browser:** the PC program now serves the app as a web page. Click the tray icon (Pair a
  phone) and scan the second QR code with the camera: the app opens in the browser, already paired. Add it to
  the home screen to use it like an app. Same screens as on Android, minus voice and the code scanner. On the PC
  itself: tray menu → Open the app in the browser (handy on a second monitor).
- **Playing as a guest:** Setup → Game save → "A friend's world" reads just your character (gear, bag, skills,
  Shroud time from the host's Flame strength you set) and your live position, instead of one of your own worlds.
- **Share build:** Character → Build → Share build makes a picture of your build and gear for Discord or a chat,
  with the same in words.
- Time in the Shroud now counts the Inner Fires skill.
- Live position shows up much sooner after the game starts (it could take up to 10 minutes).
- Read aloud and voice questions now use the app's language instead of always English.

## 0.38.0 (2026-11-06)

- **15 languages:** English, Deutsch, Français, Español, Italiano, Português (Brasil), Polski, Русский,
  Українська, Türkçe, 日本語, 한국어, 简体中文, 繁體中文 and ไทย, the languages the game itself ships. The app follows
  your phone's language; Setup → Language picks another.
- Item names, descriptions, lore, quests, skills and places use **Keen's own translations** from the game, so
  they read exactly as in your game. Menus and explanations are our translations; corrections are welcome.
- The PC program (tray menu, pairing window, the guide over the game) follows the app's language, and Ask
  answers in it.

## 0.37.0 (2026-11-05)

- **Guide over the game:** pick a place on the phone's map (a missing unique piece, a chest, anything the guide
  can lead to) and the PC marks it on your game screen: a gold marker on the spot, or an arrow at the edge when
  it's out of view, with its name, distance and height. It is a see-through window that clicks pass through,
  shown only while the game is in front. Needs the game in borderless or windowed mode and Live position on;
  tray menu → Guide over the game turns it off.
- **Plan tracker over the game:** the Plan tab's next tasks show in a corner of the game screen, like the
  game's quest list ("Take 12 × Iron Bar · Here: Large Chest #3"), and the marker points to the next thing to
  gather.
- **Completion:** lore pages and unique loot found so far ("Lore 212 / 340"), and with nothing else to do, the
  marker leads to the nearest lore page or unique piece you're still missing.

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
