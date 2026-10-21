# Bank Organiser

A RuneScape plugin that helps you sort your bank into sensible tabs and then
put each tab in order. It highlights items on your bank and you drag them; the
plugin never moves anything itself.

## What it does

**Organise my bank** (the default) follows a plan of up to 14 tabs:
Teleports & tools, Melee, Ranged, Magic, Necromancy, Jewellery & other gear,
Food & potions, Herblore & farming, Gathering, Crafting & production,
Archaeology, Quest items & clues, Cosmetics & outfits, Everything else.

- It works from your current layout. Each planned tab takes over the bank tab
  that already holds most of its items, tabs that match nothing are reused,
  and new tabs are only made when needed.
- Small planned tabs join a similar tab (a few Necromancy items join the
  biggest combat tab) or the last tab.
- One tab at a time, the items to move glow green, numbered in the order to
  drag them; the tab to drop them on (or the **+** button) is boxed in green.
  Dragging in number order leaves the tab sorted.
- Each tab gets an icon that shows what it holds (the best weapon for Melee, a
  teleport item for Teleports & tools, the best food...). A tab's icon is its
  first item, so a new tab's icon is green item 1 (dropped on +), and kept
  tabs get theirs moved to the front. The window shows each tab's icon.
- When everything is in the right tab, it puts the tabs themselves in the
  plan's order (drag the green tab icon onto the blue one), since kept tabs
  stay put and new tabs start at the end of the tab bar.
- Then it puts each tab in order: drag the
  green item onto the blue one to swap them. Gear goes by level with each set
  together (smithing upgrades as their own set), runes in the usual order,
  potions by type from most doses to fewest, herbs grimy then clean then
  unfinished, logs before bows, ores before bars, quest items by quest.

**Just tidy my tabs** keeps your tabs as they are, works out what each one is
for, and only moves items that clearly belong in another of your tabs (plus
items that aren't in a tab yet). "How picky" sets how strict it is.

On the bank:

- a banner across the bank's title bar says what to do now, and after each
  drag says whether the item went to the right tab;
- numbered badges on the tab icons (green tidy, amber needs work, grey locked);
- pointing at a bank item shows where it belongs;
- backpack items show the number of the tab they belong in, to deposit into
  the right tab (or "+" for a tab that doesn't exist yet).

In the plugin window:

- every tab with how tidy it is, what moves in and out, and a **Lock** button
  (locked tabs are left exactly as they are);
- **Pause**, and **Skip for now** (a skipped tab comes back once the rest are done); click any tab in the list to work on it next;
- **Edit plan**: mode, plan style (Recommended, Compact, Skiller, Simple),
  your tabs (rename, move, add, delete, choose the categories each holds, and
  items by name, typed or picked by pointing at them in the bank), most tabs,
  smallest tab, sorting inside tabs, working on a single open tab, tips on
  hover, backpack badges,
  per-character plans, and **Delete saved data**.

## How items are categorised

Mostly from the game's own data (see `src/classifier.lua`):

1. your own rules (items by name, per tab);
2. what the game marks clearly: clue scrolls, Archaeology, Divination,
   reclaimable holiday/skilling outfits and Treasure Hunter items, currencies,
   tokens, lamps and strange rocks, Summoning and Runecrafting supplies;
3. the item's Grand Exchange category (Jagex's own list), with runes split
   from teleports and teleport jewellery from other jewellery;
4. equipment by combat style, from its combat stats;
5. names and right-click options for the rest;
6. untradeable quest items; then outfits, then "Miscellaneous".

On a real 986-item bank about 95% of items get a specific category. Names and
options are matched in English, so other client languages may misplace some
items (the window says so).

## Data

Settings, tab locks and your plan are saved with the game's PersistentDB, on
this computer only, per character (by character name) unless you turn that
off. The bank is read only while it's open and is never saved. Nothing is
sent anywhere. **Edit plan > Delete saved data** removes everything.

## Files

| Path | Purpose |
|---|---|
| `main.lua` | Start-up, events, and turning the plan into on-screen guidance |
| `plugin.json` | Manifest |
| `src/bank.lua` | Reads the bank and each item's game data |
| `src/bankui.lua` | Finds tabs, slots, tab icons and the backpack on screen |
| `src/classifier.lua`, `src/categories.lua` | Which category each item is |
| `src/presets.lua` | Plan styles |
| `src/guide.lua` | What to move, and the next swap to sort a tab |
| `src/sorter.lua` | The order items go in inside a tab |
| `src/settings.lua` | Settings, tab locks and the plan |
| `src/overlay.lua` | Highlights, badges, banner and tips drawn on the bank |
| `src/ui/` | The plugin window and the Plugin Hub settings screen |
| `tests/` | Development only: tests and a recorded bank (never shipped) |

## Development

Run the tests with Lua 5.4 from this folder:

    lua tests/run_tests.lua          unit tests
    lua tests/e2e/run_e2e.lua        the whole plugin against a fake game client

Try it in the game: link this folder into
`C:\ProgramData\Jagex\RuneScape-BETA\dev_plugins`, then in the console
(Alt + \`) use `prf`, `pon bank-organiser` and `prl bank-organiser`.

The sibling folders `bank-organiser-probe` (records API details for
checking) and `bank-organiser-testkit` (uses dev-world cheats) are for
development only and must never be uploaded.

## Releasing

1. Check the contact address in `plugin.json` (`contactEmailAddress`) matches
   the listing (currently `itsdpraven@proton.me`).
2. Raise `version` (numbers and dots only).
3. Build the upload, which contains only `main.lua`, `plugin.json` and `src/`:

       powershell -ExecutionPolicy Bypass -File ..\tools\package-bank-organiser.ps1

4. Upload `dist\bank-organiser-<version>.zip` on mod.io with the listing text
   and images from `..\listing\bank-organiser\`.
