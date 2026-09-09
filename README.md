# LunRollHistory

Logs every group loot roll, manual `/roll`, and loot award in raid, then gets the
data out of WoW and into SQLite.

Built for Midnight 12.1 (Season 2). Standalone: no dependencies on other addons,
no shipped textures or fonts.

## Install

Download the latest release and unzip it into
`World of Warcraft/_retail_/Interface/AddOns/`, so that the folder is named
`LunRollHistory` and `LunRollHistory.toc` sits directly inside it.

To work on it instead, clone straight into the AddOns folder:

```bash
cd "/path/to/World of Warcraft/_retail_/Interface/AddOns"
git clone https://github.com/YOURNAME/LunRollHistory.git
```

The repository root *is* the addon folder, so edits are live: `/reload` in game
picks them up.

Then `/reload` or restart, and `/lrh` opens the window.

If you previously ran this as RollLedger, the old database is imported
automatically on first load and you can delete the old folder.

## Opening it

Three ways:

- **`/lrh`** (or `/lunrollhistory`) - toggles the window.
- **Minimap button** - the dice icon on the minimap ring. Left click opens the
  ledger, right click jumps to capture settings, drag moves it around the ring.
  Hide it with `/lrh minimap` or the toggle on the Appearance page.
- **Addon compartment** - the menu behind the icon next to the minimap clock,
  wired up through the TOC so it costs no taint.

## Commands

| Command | Effect |
| --- | --- |
| `/lrh` | Toggle the window |
| `/lrh minimap` | Show or hide the minimap button |
| `/lrh export` | Open the Export page |
| `/lrh settings` | Open the Capture Settings page |
| `/lrh clean` | Remove already-logged items that fail the current filters |
| `/lrh sweep` | Re-read the client's loot history and backfill anything missed |
| `/lrh stats` | Print a summary to chat |
| `/lrh wipe` | Clear the log (asks first) |

## The window

`preview.html` is a static mock of the interface, rendered from the same colour
and spacing values the addon uses. Open it in a browser to check the look, click
the swatches to try the accent presets.

The sidebar logo is `media/Logo.tga` (128x128, uncompressed 32-bit, power-of-two
as WoW requires; PNG is not a format the client can load). Swap in your own by
replacing that file at the same dimensions. The same art is used for the minimap
button and the addon compartment entry.

Six pages behind a sidebar: **Roll History** (filterable, searchable list of every
roll), **Statistics** (per-player win rate, average roll, contested rolls only),
**Capture Settings**, **Appearance**, **Export**, and **About**.

**Am I Unlucky?** rates a player 0-100 against what chance would have given
them. Two bars: **average roll**, which has a known distribution since a `/roll` is
uniform over 1-100, and **items obtained**, scoring items won against your share
of each contest - four people rolling means 0.25 of a win each.

Each bar's fill is the percentile its sentence states, never a ratio: an
Items obtained bar three-quarters full next to "1 of 5" means you placed above
three quarters of your peers, not that you won three quarters of anything.

The rating ranks on the z-score, so sample size counts. The Average roll row
ranks on the raw average instead, because that is the number printed beside it.

Every percentage on the page is measured against the other players in your
history, because every one of them is phrased "than X% of players" and a number
that says players has to mean players. On your own, with nobody to compare
against, the wording switches to "than X% of what chance would give you".

Items from the loot-award log are reported next to the rating but deliberately
kept out of it. "Items received" has no denominator the way "rolls won" does, it
counts items handed over in trade, and it misses anything below the quality
filter. Folding two differently-shaped observations into one number would make
the rating easier to state and harder to trust. Both become z-scores, so a
small sample is pulled toward 50 rather than reading as spectacular luck, and
five contested rolls are required before a rating shows at all. 75 and above
earns a star, 25 and below a skull. Those are raid target icon textures, not
emoji, because the client's fonts have no emoji glyphs and a star character
renders as a blank box. Uncontested drops are excluded from the win model since
winning alone says nothing.

**Roll History** columns are resizable: drag the divider in the header, right
click one to reset. A drag is a transfer between the two columns the divider
separates, so the divider tracks the cursor and nothing else on the row moves.
Resizing the column to the left of a divider instead looks equivalent and is
not: with a flexible column further left it absorbs the change, everything
after it slides, and the divider cannot move at all. Widths persist. The Item column is flexible and absorbs
leftover space; when the window gets too narrow for that, the fixed columns give
up their slack proportionally rather than letting the row overflow. A squeeze
only affects the rendered width, so widening the window restores what you chose.

**Appearance** carries a full HSV colour picker for the accent (hue strip,
saturation and brightness sliders, hex entry, and the old palette demoted to
shortcut swatches), a font dropdown listing every client font that actually
loads plus anything registered with LibSharedMedia if it is installed, and a
font size scale from 70% to 160%. All three apply live. The picker, dropdown,
and hue strip are all built from the addon's own frames, so none of it goes near
`ColorPickerFrame` or the `UIDropDownMenu` globals.

Settings pages scroll and their rows size themselves to their own wrapped text.
A fixed row height means a three-line description spills into the row below it,
and the whole page runs off the bottom of the window the moment someone raises
the font size, so both are measured rather than assumed.

The list is virtualised. Only enough row frames to fill the viewport are ever
created, so a 20,000-entry log scrolls exactly as cheaply as a 20-entry one.

Everything is drawn from flat 1px textures and client fonts. No art assets, no
Blizzard templates beyond bare `EditBox` and `ScrollFrame`, which keeps it a few
kilobytes and stops patches from breaking the skin when template names change.

## What it captures

**Group loot rolls** (`C_LootHistory`) - the real prize. The server broadcasts
loot history to the whole group, so a single client sees *everyone's* roll
values, roll types, and the winner. No addon comms, and nobody else needs it
installed.

**Manual `/roll`** (`CHAT_MSG_SYSTEM`) - for guilds running rolls by hand.

**Loot awards** (`CHAT_MSG_LOOT`) - who actually ended up holding the item,
which is not always who won the roll. This fires for *everything* that drops,
so two filters sit in front of it, both on the Capture Settings page:

- **Minimum loot quality**, default Rare. Reagents, cooking mats and vendor
  trash sit below Rare, which is what keeps them out. Quality is read from the
  hyperlink's own colour code, present the instant the message arrives;
  `GetItemInfo` needs the item cached and returns nil until it is.
- **Gear only**, off by default. Drops anything that is not a weapon or a piece
  of armour, via `GetItemInfoInstant`, which answers without a cache round trip.

An item whose quality cannot be determined is kept rather than dropped: logging
a stray reagent is a smaller failure than silently losing a roll. Loot rolls and
manual rolls are never filtered.

**Clean up existing log** on the same page, or `/lrh clean`, applies both
filters retroactively to entries already recorded.

Chat parsing is compiled from Blizzard's own global strings
(`RANDOM_ROLL_RESULT`, `LOOT_ITEM`, ...) rather than hardcoded English, so it
works on any locale, including ones using positional specifiers like `%2$s`.

## Getting the data out

Addons have no file I/O - no `io`, no `os.execute`. The only persistence is
SavedVariables, a Lua table the client serializes to:

```
WTF/Account/<ACCOUNT>/SavedVariables/LunRollHistory.lua
```

It is written **on logout or `/reload`**, never mid-raid. Then:

```bash
python3 tools/lunrollhistory_import.py \
  ~/'World of Warcraft/_retail_/WTF/Account/*/SavedVariables/LunRollHistory.lua' \
  --db rolls.sqlite --csv rolls.csv --summary
```

No dependencies beyond the standard library. Re-running is safe: rows are keyed
on `(account, uid)`, so imports accumulate rather than duplicate. That matters,
because the in-game log prunes oldest entries past the History size setting -
import regularly and the database outlives the rolling window. Old
`RollLedgerDB` files still import.

### Schema

`drops` -> `drop_rolls` (one row per player per item), plus `manual_rolls` and
`loot_events`. The `v_rolls` view joins drops to rolls:

```sql
SELECT player, COUNT(*) AS rolls, SUM(is_winner) AS wins, ROUND(AVG(roll),1) AS avg
FROM v_rolls
WHERE roll_type NOT IN ('Pass','NoRoll')
GROUP BY player ORDER BY wins DESC;
```

## Taint safety

The addon writes to no Blizzard-owned table or frame. Three things were removed
after a `blocked from an action only available to the Blizzard UI` report:

- **No `UISpecialFrames` entry.** Inserting a frame name there taints Blizzard's
  table, and the taint rides into `CloseSpecialWindows` and from there into the
  ESC / game-menu path. ESC is handled on our own frame instead, and keyboard
  capture is left alone entirely while `InCombatLockdown()` is true.
- **No `StaticPopupDialogs` entry.** Registering a dialog there hands our
  insecure table to Blizzard's popup code for every popup afterwards, not just
  ours. The wipe confirmation is drawn from the addon's own widgets.
- **No regions created on `UIParent`.** The font probe lives on a private
  hidden frame.

If a block ever appears again, `/console taintLog 2`, `/reload`, reproduce it,
then read `Logs/taint.log` in the WoW folder. It names the exact file and
function, which beats guessing.

## Midnight-specific notes

**Secret values.** Since the Midnight addon restrictions, APIs can hand back
values that throw when touched. Every event handler runs inside `pcall`, and no
value reaches the database without passing through `ns:SafeStr` / `ns:SafeNum`.
If a player name comes back secret, that roll is stored with a null name rather
than taking the addon down. `Core.lua` picks up a secret-check global
automatically if your build exposes one; add its name to the `isSecret` line if
it differs.

**No addon messages during boss encounters.** This addon sends none. Every
client already sees the full group loot history, so cross-client sync buys
nothing.

**Restricted chat during encounters and M+.** `/roll` messages fired mid-pull
may arrive unreadable. Group loot history is unaffected and resolves after the
kill, which is when rolls happen anyway. `/lrh sweep` backfills.

**Struct field renames.** Blizzard has renamed loot-history fields repeatedly.
`ns:Field(tbl, "playerName", "name")` tries several candidates, and enum values
are decoded from `Enum.EncounterLootDropRollState` at runtime instead of being
hardcoded, so a renumbered enum will not silently mislabel Greed as Need.

## Tests

```bash
lua5.1 tests/run.lua       # 210 assertions
```

Paths resolve relative to the script, so it runs from any checkout. CI runs the
same suite on every push, plus a syntax check and a non-ASCII guard.

The harness stubs `CreateFrame` with an explicit whitelist of real WoW widget
methods, so any invented API call fails loudly instead of silently no-opping.
It builds every page headlessly and exercises tab filtering, search, list
virtualisation, scroll clamping, accent switching, the wipe confirmation, ESC
being inert during combat, the two Blizzard tables staying untouched, and the
migration from the old addon name - plus the capture-layer tests: duplicate
`LOOT_HISTORY_UPDATE_DROP` events collapsing into one record, GUID-only entries
resolving to names, secret values failing safely, and CSV quoting surviving item
names with commas and periods.

## Notes on the look

The visual language (dark violet panels, accent-underlined tabs, sidebar with
section headers) is modelled on the EllesmereUI options window. No EllesmereUI
code, art, or dependency is involved - it is an independent implementation.

## Legal

Reading loot history and parsing chat are ordinary addon operations well inside
the WoW UI policy. Nothing here automates gameplay.
