<p align="center">
  <img src="docs/hero.png" alt="Bank Organiser highlighting items on the RuneScape bank, with its plugin window beside it" width="100%">
</p>

<h1 align="center">Bank Organiser</h1>

<p align="center">
  <a href="https://github.com/itsdpraven/rs3-bank-organiser/actions/workflows/tests.yml"><img src="https://github.com/itsdpraven/rs3-bank-organiser/actions/workflows/tests.yml/badge.svg" alt="Tests"></a>
</p>

<p align="center">
  <b>A RuneScape 3 plugin that sorts your bank into sensible tabs, then puts every tab in order.</b><br>
  It shows you what to move and where. You make every drag.
</p>

---

## What it does

Most banks end up as a few half-sorted tabs and hundreds of items in the main
tab. Bank Organiser works out where everything belongs and walks you through it,
one tab at a time, right on top of the real bank.

- **Highlights on your bank.** Items to move glow green, numbered in the order
  to drag them. The tab to drop them on (or the **+** button for a new tab) is
  boxed in green. A banner across the bank says what to do, and after each
  drag tells you whether the item went to the right place.
- **Works from the bank you already have.** Tabs that already fit are kept,
  tabs that fit nothing are reused, and new tabs are only suggested when
  needed. Nothing is deleted. Locked tabs are never touched.
- **Puts the tabs themselves in order**, then **sorts inside each tab**:
  gear by level with each set together, runes in the usual order, potions by
  type from most doses to fewest, herbs grimy → clean → unfinished, logs before
  bows, ores before bars, quest items by quest.
- **Picks an icon for every tab** from your own items (the best weapon for
  Melee, your best food for Food & potions...) and shows you how to set it.
- **Point at any bank item** to see which tab it belongs in. Items in your
  backpack show the number of their tab, so you can deposit into the right
  place.

## Your bank, your rules

- **Two modes:** *Organise my bank* (a full plan of up to 14 tabs) or *Just
  tidy my tabs* (keep your tabs, fix only what's clearly out of place).
- **Plan styles:** Recommended, Compact, Skiller and Simple, or your own.
- **Edit any tab:** rename it, move it, add or delete tabs, choose which kinds
  of item it holds, and send items by name to a tab (type a name or point at
  the item in your bank).
- **Lock** tabs you want left exactly as they are; **Skip for now** or click
  any tab to work on it next.

## How it decides where things go

Items are sorted mostly from the game's own data rather than guesswork:

1. your own rules (items by name, per tab);
2. what the game marks clearly: clue scrolls, Archaeology, Divination,
   holiday and outfit items, currencies and lamps, Summoning and Runecrafting
   supplies;
3. the item's **Grand Exchange category**: Jagex's own list for every
   tradeable item;
4. equipment by **combat style**, from its combat stats;
5. names and right-click options for anything left, and untradeable quest
   items.

On a real 986-item bank, about 99% of items get a specific category.

## Safe by design

- The plugin **never moves, clicks or drags anything**. It only draws
  click-through highlights and text. You do every action yourself.
- It requests **no permissions** and **sends nothing anywhere**.
- Settings, your plan and tab locks are saved only on your computer, and can be
  deleted from the plugin window at any time.

## Install

Once it's approved on the RuneScape Plugin Hub: open the Plugin Hub in game
(the toolbox icon), find **Bank Organiser**, install it, then turn it on in the
**Manage** tab. Open your bank, then the plugin window from its ribbon icon.

To try the development version, see [`bank-organiser/README.md`](bank-organiser/README.md).

## Repository layout

| Path | What's there |
|---|---|
| [`bank-organiser/`](bank-organiser/) | The plugin (what gets uploaded), its tests and its developer README |
| [`tools/`](tools/) | Builds the Plugin Hub upload zip and the listing image |
| [`listing/`](listing/bank-organiser/LISTING.md) | The mod.io listing text |
| [`docs/`](docs/) | Images for this page |
| `bank-organiser-probe/`, `bank-organiser-testkit/` | Development-only helper plugins (never uploaded) |

## Development

The logic is plain Lua 5.4 and is tested outside the game:

```
cd bank-organiser
lua tests/run_tests.lua
```

The tests also run on every push (see the Actions tab). The packaging script
checks the plugin before building the upload:

```
powershell -ExecutionPolicy Bypass -File tools/package-bank-organiser.ps1
```

## Legal

Bank Organiser is a fan-made plugin and isn't made or endorsed by Jagex. Item images are from the [RuneScape Wiki](https://runescape.wiki).
RuneScape is a trademark of Jagex Ltd. Plugins on the official Plugin Hub are
provided under the [Jagex EULA](https://legal.jagex.com/docs/terms/eula), so
this repository has no separate licence.
