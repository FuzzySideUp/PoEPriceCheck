# PoEPriceCheck

A macOS menu-bar price checker for **Path of Exile 2** and **Path of Exile 1** that works while you play through
**GeForce NOW**.

Overlays like Awakened PoE Trade and Exiled Exchange 2 read the item text from the clipboard. Under
GeForce NOW the game runs on NVIDIA's cloud PC, so that clipboard never reaches your Mac. PoEPriceCheck
reads the **tooltip off your screen** with Apple's Vision OCR instead. Hover an item, press **⌃D**, and a
small panel shows the price next to the cursor.

![Rare item: fuzzy trade search with toggleable stats](docs/rare-fuzzy-search.png)

| Currency stack (poe.ninja) | Unique (poe.ninja) |
|---|---|
| ![Currency](docs/currency-stack.png) | ![Unique](docs/unique.png) |

## What it does

- **Currency, fragments, runes, essences, omens, ritual items, uniques:** priced from
  [poe.ninja](https://poe.ninja/poe2) (cached for 15 minutes), with the stack total.
- **Rares and magic items:** priced with a **fuzzy** search on the official trade site, because searching
  every exact stat usually finds nothing. The search:
  - uses only the stats that drive value (skill levels, movement speed, spirit, life, resistances,
    crit, cast/attack speed, DPS, defences…) and skips filler mods
  - folds related mods into pseudo totals: total life, total elemental resistance, attributes
  - searches **minimums only**, a margin below each roll (default 10%), with no maximums
  - replaces local defence and damage mods with the item's Armour/Evasion/ES or DPS
  - **relaxes automatically** below 10 results (drops the item-level floor, widens the margin, then
    drops the least important stat) and shows what it changed
  - lets you tick/untick stats and change the margin in the panel, then **Search again**, or
    **Open on trade site**
- **Unidentified items:** priced by base type and unidentified tier.
- **PoE 1 or PoE 2, detected automatically:** with menu › Game › Auto (the default) each check works out
  which game the tooltip is from: the league in the area overlay, the window title if it names the game,
  PoE 2's item class line and "Requires:" wording, and which game's data knows the item. Items both games
  have (Divine Orb) keep the last game. The panel footer shows the game; hover it for the reason. You can
  also fix the game to PoE 1 or PoE 2 in the same menu. PoE 1 uses poe.ninja's PoE 1 prices
  (shown in chaos and divine) and the PoE 1 trade site. OCR can't see sockets, so for body armours and
  two-handed weapons the panel has a **Links** control (Any / 5L / 6L) that picks the 5L/6L poe.ninja price
  or adds a links filter to the trade search. PoE 1 tooltips show no item level unless you hold Alt, so
  PoE 1 searches don't filter on item level.
- **League:** read from the in-game area overlay when it's on screen (e.g. "Forbidden Rites League");
  otherwise poe.ninja's current league, or pick one from the menu.
- Respects GGG's `X-Rate-Limit-*` headers.

It is **read-only**: it captures the screen and calls public price APIs. It never sends keystrokes or
clicks to the game.

## How it works

1. A listen-only keyboard tap (plus a regular global hotkey) sees ⌃D even when GeForce NOW or Chrome has
   grabbed the keyboard in fullscreen.
2. ScreenCaptureKit grabs the display. Vision OCRs it in about 0.2 s on Apple Silicon.
3. The tooltip is found as the stack of **centre-aligned** text lines on a **near-black panel**. Stash
   tab labels, the right-aligned map overlay and world text are rejected. Text colour, normalised for
   brightness so dimmed tooltips still work, gives the rarity and mod types.
4. Lines are matched to trade stat IDs with fuzzy matching against the trade site's stat templates, which
   tolerates OCR typos.
5. If a frame looks smeared by video compression, it re-captures once.

## Download

Get `PoEPriceCheck-<version>-macOS.zip` from the [latest release](https://github.com/FuzzySideUp/PoEPriceCheck/releases/latest)
(macOS 14+, universal binary), unzip it and move `PoEPriceCheck.app` to Applications. The app isn't
notarized, so on first launch right-click it › Open › Open. Then grant the two permissions listed under
Install below.

## Install

To build it yourself instead: macOS 14+ on Apple Silicon (built and tested on an M4 at 3840×2160), Xcode 15+ / Swift 5.10+.

```bash
git clone https://github.com/FuzzySideUp/PoEPriceCheck.git
```

```bash
cd PoEPriceCheck && scripts/build_app.sh
```

```bash
open ~/Applications/PoEPriceCheck.app
```

The build script signs with your Apple Development certificate if you have one. That keeps the
permissions below across rebuilds; with ad-hoc signing macOS may ask again after each rebuild.

Grant two permissions when prompted (System Settings › Privacy & Security), then quit and reopen the app:

- **Screen & System Audio Recording:** to read the tooltip
- **Input Monitoring:** so ⌃D works while GeForce NOW holds the keyboard in fullscreen

The dollar-sign menu-bar icon has the hotkey, league, default margin, listing status, panel size, and
"Save captures" for debugging.

## Development

```bash
swift test --scratch-path ~/Library/Caches/PoEPriceCheck/build
```

- `Fixtures/screens/` holds real GeForce NOW tooltip captures (cropped) with expected parses. The
  fixture test runs every one through OCR, tooltip detection and parsing.
- `POE_LIVE=1 swift test … --filter LiveTests` hits poe.ninja and the trade API.
- `swift run --scratch-path ~/Library/Caches/PoEPriceCheck/build ocrtool <image> [cursorX cursorY] [--all] [--price]`
  shows what the OCR sees, the parsed item, the fuzzy search, and optionally live prices.
- With **Save captures** on, each check writes a PNG and OCR JSON to
  `~/Library/Application Support/PoEPriceCheck/captures`. A step-by-step log is in `log.txt` next to it.
- `ocrtool … --game poe1` uses the PoE 1 data and APIs.
- `scripts/build_app.sh --refresh-data` re-downloads trade stats and base types (both games) after a patch.
- If the project lives in an iCloud-synced folder, keep builds outside it (as above): Finder metadata
  on build products breaks code signing.

## Status

Early. Tested on one 4K display at 1× scaling. Other resolutions should work, but the detection thresholds
were tuned on 4K captures. PoE 2 is the most tested; PoE 1 support is new.

## License

MIT. See [LICENSE](LICENSE). Game data in `Data/` and the screenshots in `Fixtures/` and `docs/` show
Path of Exile content, which belongs to Grinding Gear Games.

## Disclaimer

Unofficial fan project, not affiliated with or endorsed by Grinding Gear Games or NVIDIA. Price data
comes from [poe.ninja](https://poe.ninja) and the
official trade site ([PoE 1](https://www.pathofexile.com/trade), [PoE 2](https://www.pathofexile.com/trade2)).
Base-type data comes from [RePoE](https://github.com/repoe-fork/repoe-fork). Use the trade API considerately.
