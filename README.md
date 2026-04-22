# Boble Loot

A World of Warcraft (Retail) addon that augments
[RCLootCouncil](https://www.curseforge.com/wow/addons/rclootcouncil) with
a **0–100 recommendation score** for every loot candidate, computed from:

| Factor                         | Source                              |
|--------------------------------|-------------------------------------|
| Sim upgrade %                  | WoWAudit per-character item sims    |
| BiS membership                 | Wowhead / hand-curated BiS lists    |
| Recent items received          | Your loot tracking spreadsheet      |
| Raid attendance                | Your attendance tracker             |
| Mythic+ dungeons done (this season) | WoWAudit / dungeons-done counter |

Weights are configurable in-game and the score column is added directly
to the RCLootCouncil voting window.

---

## Install

1. Copy `BobleLoot/` into `World of Warcraft/_retail_/Interface/AddOns/`.
2. Install **RCLootCouncil** (required) from CurseForge / Wago.
3. Make sure the standard **Ace3** libraries plus **LibDeflate** are
   available. Most users already have them (RCLootCouncil ships them);
   if you load this addon standalone, drop the libraries into a `Libs/`
   folder and uncomment the include in `embeds.xml`. (Without LibDeflate
   the addon still works locally — only raid sync is disabled.)
4. Generate a real data file (next section) and place it at
   `BobleLoot/Data/BobleLoot_Data.lua`. A sample ships out of the
   box so the addon loads even with no data.
5. `/reload` in-game.

## Refresh data

A single tool, `tools/wowaudit.py`, generates `Data/BobleLoot_Data.lua`.
It supports two modes, auto-selected by the arguments you pass.

### Mode A — Fetch from WoWAudit API (recommended for raid leaders)

Requires a WoWAudit team API key (admin-only, found under your team's
*Settings → API*).

```bash
py tools/wowaudit.py --api-key YOUR_TEAM_KEY
```

The output is written to `BobleLoot/Data/BobleLoot_Data.lua` (resolved
relative to the script, so it always lands in the right addon folder).
Override with `--out` if needed.

Or, easier, copy `.env.example` to `.env` in the repo root and put your
key there as `WOWAUDIT_API_KEY=...` — the script auto-loads it and
`.env` is gitignored. You can also set `WOWAUDIT_API_KEY` in your
shell environment. Then just:

```bash
py tools/wowaudit.py
```

Use `--dump-raw response.json` once if your team's response shape
differs from the defaults; then use `--field-map` to remap field names
without touching the script.

### Mode B — Convert a manual export

```bash
py tools/wowaudit.py \
    --wowaudit  path/to/wowaudit_export.csv \
    --bis       path/to/bis.json
```

Passing `--wowaudit` switches the script into convert mode (no API call
is made). `--bis` is required in this mode.

CSV requirements (XLSX also supported; install `openpyxl`):

| column            | meaning                                  |
|-------------------|------------------------------------------|
| `character`       | `Name-Realm` exactly as it appears in WoW |
| `mplus_dungeons`  | M+ dungeons completed this season (numeric) |
| `attendance`      | 0..100                                    |
| `items_received`  | recent loot received                      |
| `sim_<itemID>`    | one column per item, value = % DPS upgrade |

`bis.json` is `{ "Name-Realm": [itemID, ...] }`.

After regenerating, `/reload` in-game (or relog).

## Sharing data with the rest of the raid

Only the **raid leader (or whoever runs the tool)** needs to maintain
the data file. The addon automatically distributes it to every other
Boble Loot user in the same raid:

1. Raid leader runs `tools/wowaudit.py`, then `/reload`s in-game.
2. On joining a raid, every Boble Loot client announces its dataset
   version. Anyone with a stale (or missing) dataset asks the leader for
   theirs and receives it over WoW's addon channel (compressed with
   LibDeflate).
3. Receivers persist the dataset in `BobleLootSyncDB`, so it survives
   relog even if the leader is offline.

The leader can also force a re-broadcast at any time with `/bl broadcast`.

## Transparency mode

When the raid leader enables **transparency mode** (in `/bl` config or
via `/bl transparency on`), every raid member running Boble Loot will
see *their own* 0–100 score on each item RCLootCouncil shows them in
the candidate roll/loot frame, with the same per-component breakdown
tooltip the council sees.

- Only the actual group leader can toggle it; the setting is broadcast
  over the raid addon channel and re-sent on roster changes so late
  joiners pick it up.
- Players not present in the synced dataset just see no extra UI.
- Turn it off and the score line disappears for everyone instantly.

## In-game

* `/bl` (or `/bobleloot`) — open the options panel (weights, caps, BiS partial credit, transparency toggle).
* `/bl broadcast` — re-announce your dataset to the raid (raid leader only really needs this).
* `/bl transparency on|off` — leader-only quick toggle for transparency mode.
* `/bl score <itemID> <Name-Realm>` — print a score breakdown to chat.
* When RCLootCouncil opens its voting frame, a new sortable **Score**
  column appears. Hover for the per-component breakdown.

## Scoring formula

```
score = 100 * Σ (w_i * c_i)   over components with data
        ───────────────────
              Σ w_i
```
Each component is normalized to `[0,1]`:

| Component   | Normalization                                  |
|-------------|------------------------------------------------|
| sim         | `min(simPct / simCap, 1)`                      |
| bis         | `1` if on BiS, else `partialBiSValue` (default 0.25) |
| history     | `1 - min(itemsReceived / historyCap, 1)`       |
| attendance  | `attendance / 100`                             |
| mplus       | `min(mplusScore / mplusCap, 1)`                |

Weights from the options panel auto-renormalize so the five sliders
always sum to 100%.

## Files

```
BobleLoot.toc          addon manifest
embeds.xml             Ace3 include (commented out by default)
Core.lua               AceAddon init, slash commands, RC detection
Scoring.lua            pure scoring algorithm
Config.lua             AceConfig options panel
Sync.lua               raid-channel data + settings distribution (AceComm + LibDeflate)
VotingFrame.lua        RCVotingFrame column hook + tooltip (council)
LootFrame.lua          RCLootFrame "Your score" hook (transparency mode)
Data/BobleLoot_Data.lua       generated; ships with a sample
tools/wowaudit.py             fetch from WoWAudit API or convert a CSV/XLSX export
tools/sample_input/           example inputs for convert mode
```

## Status

v0.1 — advisory only. The addon does not auto-vote and does not modify
any RCLootCouncil decision flow.
