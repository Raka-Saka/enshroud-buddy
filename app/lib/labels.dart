import 'l10n.dart';

// Our own names for values the data keeps in English (logic compares them): shown in the chosen language here.
// Until ui/<code>.json has a word, the game's own translation of it (gt) stands in, when there is one.

String _or(String shown, String en) => shown == en ? gt(en) : shown;

/// A weapon type ("Bow", "Two-handed axe"...) as shown.
String weaponLabel(String en) => _or(switch (en) {
  'Bow' => tr('Bow'),
  'Dagger' => tr('Dagger'),
  'Staff' => tr('Staff'),
  'Wand' => tr('Wand'),
  'Shield' => tr('Shield'),
  'Greatsword' => tr('Greatsword'),
  'Two-handed axe' => tr('Two-handed axe'),
  'Hammer' => tr('Hammer'),
  'Sword' => tr('Sword'),
  'Axe' => tr('Axe'),
  'Mace' => tr('Mace'),
  'Utility' => tr('Utility'),
  _ => en,
}, en);

/// A class ("Warrior", "Ranger", "Mage") as shown.
String classLabel(String en) => _or(switch (en) {
  'Warrior' => tr('Warrior'),
  'Ranger' => tr('Ranger'),
  'Mage' => tr('Mage'),
  'Neutral' => tr('Neutral'),
  _ => en,
}, en);

/// A gear slot's label (ItemStats.slotLabels: "Head", "Melee weapon"...) as shown.
String slotName(String en) => _or(switch (en) {
  'Head' => tr('Head'),
  'Chest' => tr('Chest'),
  'Hands' => tr('Hands'),
  'Legs' => tr('Legs'),
  'Feet' => tr('Feet'),
  'Ring' => tr('Ring'),
  'Backpack' => tr('Backpack'),
  'Glider' => tr('Glider'),
  'Grappling hook' => tr('Grappling hook'),
  'Spell' => tr('Spell'),
  'Melee weapon' => tr('Melee weapon'),
  'Staff / wand' => tr('Staff / wand'),
  'Bow' => tr('Bow'),
  'Shield' => tr('Shield'),
  'Arrows' => tr('Arrows'),
  'Consumable' => tr('Consumable'),
  'Tool' => tr('Tool'),
  _ => en,
}, en);
