# Boble Loot — Copilot instructions

Boble Loot is a **World of Warcraft (Retail) addon** written in Lua that
augments [RCLootCouncil](https://www.curseforge.com/wow/addons/rclootcouncil)
with a 0–100 recommendation score per loot candidate. A small Python tool
under `tools/` generates the dataset the addon consumes.

There are effectively two sub-projects in this repo: the **Lua addon**
(top level + `UI/`, `Data/`, `Libs/`) and the **Python data pipeline**
(`tools/`).

## Build / test / lint

- Lua: there is no build step. The addon is loaded by WoW via `BobleLoot.toc`.
  Any new Lua file must be added to `BobleLoot.toc` in load order, or it
  will not be sourced in-game.
- In-game smoke test: `/bl` opens the panel; `TestRunner.lua` drives
  `RCLootCouncil:Test()` so the Score column can be exercised without a
  real boss kill.
- Python tests (pytest, 50+ cases under `tools/tests/`):
  - Full suite: `cd tools && py -m pytest`
  - Single test: `cd tools && py -m pytest tests/test_wowaudit.py::test_convert_round_trip_sim_values`
  - Config lives in `tools/pytest.ini`; `testpaths = tests`.
- Regenerate data: `py tools/wowaudit.py` (API mode, needs
  `WOWAUDIT_API_KEY` in `.env` or env) or `py tools/wowaudit.py --wowaudit <csv> --bis <json>` (convert mode).
  Output always lands at `Data/BobleLoot_Data.lua` regardless of CWD —
  the script resolves paths relative to itself.

## Architecture

The addon namespace is the standard WoW pattern: `local ADDON_NAME, ns = ...`.
Each file attaches itself to `ns` (e.g. `ns.Scoring = Scoring`,
`ns.TestRunner = Test`). The AceAddon instance is exposed as both
`ns.addon` and `_G.BobleLoot`. Ace3 libraries are pulled via `LibStub`
(AceAddon-3.0, AceConsole-3.0, AceDB-3.0, AceComm-3.0, AceSerializer-3.0).
SavedVariables: `BobleLootDB` (per-profile options), `BobleLootSyncDB`
(persisted synced dataset).

Big-picture flow:

1. `tools/wowaudit.py` writes `Data/BobleLoot_Data.lua` — a pure-data
   Lua file containing per-character sims, BiS lists, attendance,
   M+ counts, item history, and `simsKnown` sets. The file is gitignored
   because it contains roster info; `BobleLoot_Data.example.lua` ships
   as a placeholder.
2. `Core.lua` initializes AceDB with defaults (weights, caps, toggles)
   and registers `/bl` / `/bobleloot`.
3. `Scoring.lua` is the pure scoring kernel. Given
   `(itemID, candidateName, profile, data)` it returns
   `(score 0..100, breakdown)`. Missing components drop out and their
   weight is redistributed across the remaining components.
4. `Sync.lua` (AceComm prefix `"BobleLootSync"`, LibDeflate-compressed
   `"BULK"` messages) propagates the dataset and the leader's
   transparency-mode toggle to other Boble Loot clients in the raid.
   Receivers persist into `BobleLootSyncDB`.
5. `VotingFrame.lua` hooks RCLootCouncil's voting frame and adds the
   sortable **Score** column with the breakdown tooltip (council view).
6. `LootFrame.lua` hooks RCLootCouncil's candidate frame to show each
   player their own score when transparency mode is on.
7. `UI/` (Theme, SettingsPanel, MinimapButton) is a from-scratch options
   UI — **not** AceConfig. `RaidReminder.lua`, `LootHistory.lua`, and
   `TestRunner.lua` are auxiliary in-game tools.

## Key conventions

- **Score column non-negotiables** are documented at the top of
  `Scoring.lua`. The most important one: the **nil-vs-zero invariant**.
  - `char.sims[itemID]` is a numeric upgrade %, but zero-result sims
    are omitted from the table.
  - `char.simsKnown[itemID]` is a parallel set of itemIDs that the
    pipeline actually queried (even with a 0% result).
  - `simComponent` returns `nil` only when *neither* table has the item
    (truly unsimmed). A real 0% sim must return `0.0`, not `nil`.
  - When sim weight is active and `simComponent` returns `nil`,
    `Scoring:Compute` hard-returns `nil` for that candidate. This
    intentionally suppresses the row rather than score it as zero.
  - Do **not** collapse `simsKnown` into `sims` via a sentinel
    (e.g. `-1`); the two-table shape is load-bearing on both the
    Python and Lua sides. If you change the data shape, update
    `tools/wowaudit.py` (and its tests) and `Scoring.lua` together.
- **TOC ordering matters.** `Libs\Libs.xml` and `Data\BobleLoot_Data.lua`
  must load before any `.lua` that references them. New files go at the
  bottom of `BobleLoot.toc` unless they have explicit dependencies.
- **Interface version** in `BobleLoot.toc` (`## Interface:`) tracks
  retail WoW; bump it when targeting a new patch.
- **Slash commands** are registered through `AceConsole-3.0` in
  `Core.lua`. Add subcommands there (`/bl <something>`), not in
  individual feature files.
- **Sync changes** must preserve backward compatibility with older
  clients in the raid (versioned dataset announcement). The AceComm
  prefix is `"BobleLootSync"` and messages are LibDeflate-compressed
  `AceSerializer` payloads sent as `"BULK"`.
- **Generated/secret files are gitignored**: `Data/BobleLoot_Data.lua`,
  `.env`, `tools/.cache/*.json`, `BobleLoot-*.zip`. Never commit them.
  When adding examples, mirror the `Data/BobleLoot_Data.example.lua`
  pattern.
- **Python tool layout**: `tools/wowaudit.py` is a single-file script
  with both an HTTP-fetch mode and a CSV/XLSX convert mode auto-selected
  by CLI args. Tests import it via `importlib.util` (see
  `tools/tests/test_wowaudit.py`) so `main()` does not run on import —
  keep any new top-level side effects out of module scope.
- **Design docs / plans** for past and in-flight work live in
  `docs/superpowers/{plans,specs}/`. Skim the relevant batch plan
  (e.g. `batch-1b-scoring-nil-vs-zero-plan.md`) before changing
  scoring, sync protocol, or UI internals — the rationale for current
  invariants is captured there, not in code comments.
