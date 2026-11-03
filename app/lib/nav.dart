import 'package:flutter/foundation.dart';

/// The bottom navigation's destinations.
class Tabs {
  static const home = 0, plan = 1, map = 2, character = 3, codex = 4;
}

/// Which bottom tab is showing; any screen can switch it.
final appTab = ValueNotifier<int>(Tabs.home);

/// Character's sub-tabs: Build, Gear, Inventory, Bases.
class CharacterTabs {
  static const build = 0, gear = 1, inventory = 2, bases = 3;
}

final characterTab = ValueNotifier<int>(CharacterTabs.build);

/// Codex's sub-tabs: Items, Sets, Lore, Quests.
class CodexTabs {
  static const items = 0, sets = 1, lore = 2, quests = 3;
}

final codexTab = ValueNotifier<int>(CodexTabs.items);

/// Switch to a tab, optionally a Character or Codex sub-tab.
void goTo(int tab, {int? character, int? codex}) {
  if (character != null) characterTab.value = character;
  if (codex != null) codexTab.value = codex;
  appTab.value = tab;
}
