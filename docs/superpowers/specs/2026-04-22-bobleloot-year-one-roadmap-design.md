# BobleLoot — Year-One Roadmap

**Date:** 2026-04-22
**Starting version:** 1.0.0
**Status:** Design approved, pending per-batch implementation plans

## Objective

Define the full set of features, fixes, and refactors that take BobleLoot
from the just-shipped v1.0.0 to a mature, year-one-in-production state.
The roadmap is a **prioritization and scope document** — not a schedule.
It exists so the two collaborators (UI side and data/correctness side)
work from a single source of truth and stay out of each other's lanes.

Individual items are executed via per-batch implementation plans written
in later sessions; this document is the stable parent they inherit from.

## Collaboration model

Two sides share the codebase:

- **UI side** — owns surfaces (score column, tooltips, minimap button,
  settings panel, toasts, history viewer, comparison popouts, empty/error
  states). Modifies `VotingFrame.lua`, `LootFrame.lua`, `RaidReminder.lua`,
  the new `UI/` modules, and anything rendered on screen.
- **Data / correctness side** — Kotoma92 + GitHub Copilot. Owns scoring
  logic, sync protocol payloads, `wowaudit.py`, persistence schema,
  RCLootCouncil SavedVar reads, and CI/automation. Modifies `Scoring.lua`,
  `Sync.lua`, `LootHistory.lua`, `Core.lua` event wiring, `tools/`.

Items carry an ownership tag:

- `[UI]` — entirely UI-side
- `[Data]` — entirely data-side
- `[Cross]` — both sides. The data side defines the wire/protocol/contract;
  the UI side defines what the player sees. The contract is agreed in the
  item's implementation plan before either side ships.

## Batching model

Batches are **loose ordering**, not calendar quarters. Each batch is a
coherent release unit that makes sense to ship as one version. Items can
slide between batches when reality demands, but within a batch the items
belong together because they share a theme or because earlier items unblock
later ones.

- **Batch 1 → v1.1** — Foundational resilience. Pipeline doesn't die,
  scoring is correct, sync can't corrupt state, and the core UI gets the
  long-promised VoidstormGamba-aligned overhaul.
- **Batch 2 → v1.2** — Everyday UX and scoring nuance. Spec-aware sims,
  trial/bench roles, BOE/vault history, leader-change correctness,
  chunked sync, pinnable score-explanation panel.
- **Batch 3 → v1.3** — Council differentiation. The features that shift
  BobleLoot from "score column" to "decision-support tool": side-by-side
  comparison, ghost weights, first-class history viewer, toast
  notifications, per-night score trends.
- **Batch 4 → v2.0** — Platform hardening & year-two survival. Multi-tier
  BiS, RC version compatibility, export/import for leader handoff,
  colorblind palette, empty/error-state audit, catalyst/tier-token
  tracking.

## Non-goals (explicitly out of scope)

The following were considered and rejected. They are listed here so they
are not re-litigated in a later session.

1. **Standalone-without-RC mode.** RCLootCouncil is the product's reason
   for existing. If RC is missing we show a prominent warning banner, we
   do not build a parallel UI surface. (Was Q3 item in the original
   full-stack agent proposal.)
2. **HMAC dataset signing.** The threat model — "troll in my own raid" —
   is already gated by who the raid leader invited. Shared-secret
   distribution over the addon channel defeats the cryptography anyway.
   The `UnitIsGroupLeader(sender)` check on every authoritative message
   (Batch 2.5) is proportionate. (Was Q4 item.)
3. **Static HTML export page for the raid.** WoWAudit already provides
   the "raid-visible dashboard" surface. Inline-JSON mirror sites are
   duplication. (Was Q4 item.)
4. **Raidbots source adapter.** The pluggable-source-chain abstraction
   is YAGNI for a hypothetical second sim source. Batch 2.1 keeps the
   WoWAudit fetch behind one clean function signature so a future swap
   is a small refactor, not an architecture change. (Was Q2 item.)
5. **In-game per-item score override editor.** Batch 4.7 instead ships a
   `scoreOverrides = { [itemID] = number }` table in the generated
   `BobleLoot_Data.lua`. Python tool owns the data file; no UI code
   needed. (Downgraded from original Q4 item.)
6. **Full live-preview config panel redesign.** The UI Overhaul spec
   (2026-04-22-ui-overhaul-design.md) already replaces `Config.lua` with
   a custom panel in v1.1. A small live-updating example row inside the
   new `BuildWeightsTab` is sufficient — no separate redesign item.
   (Downgraded from original Q4 item.)
7. **No web companion dashboard** of any kind.
8. **No theme switcher.** Single fixed palette from the UI Overhaul spec.
9. **No localization** in year one. No `Locales/` exists and no demand
   has surfaced.

---

## Batch 1 — Foundational resilience (v1.1)

Purpose: stop the bleeding. These are the failure modes most likely to
kill adoption in the first eight weeks, plus the UI overhaul that ships
with the same release.

### 1.1 `[Data]` `wowaudit.py` hardening

Current behaviour: `http_get_json` calls `sys.exit()` on any HTTP or
network error, leaving the raid with whatever stale Lua file was on disk
and no indication anything happened. Single-endpoint maintenance windows
kill the whole run.

Changes:
- Wrap each endpoint call independently; partial success produces a
  Lua file annotated with `-- WARNING: <endpoint> failed: <reason>`
- Add response-schema validation (`schemas/wowaudit_v*.json`) with
  per-character warnings rather than aborts.
- Cache every successful endpoint response to `tools/.cache/<endpoint>.json`;
  add a `--use-cache` flag that replays the last successful call.
- Emit a human-readable run report: characters added/removed, characters
  with zero sim data, BiS list diff, M+ cap change.

### 1.2 `[Data]` Fix `Scoring:Compute` nil-vs-zero collision

`simComponent` returns `nil` when `char.sims[itemID]` is nil and `0.0`
when the value is literally zero. `Scoring:Compute` currently treats
both identically, dropping a player who genuinely simmed zero out of
the council score. Fix by distinguishing "no data" from "data is zero"
using a separate `char.simsKnown` set or a sentinel.

### 1.3 `[Data]` pytest harness for `wowaudit.py`

Add `tools/tests/test_wowaudit.py` covering convert-mode round-trip
against `tools/sample_input/`, `_best_wishlist_score` edge cases
(empty spec map, negative percentages), `_full_name` realm-space
stripping, and `build_lua` missing-column exit. Run with
`pytest tools/` in CI.

### 1.4 `[Data]` `BobleLootSyncDB.schemaVersion` field

Write `BobleLootSyncDB.schemaVersion = 1` during `Sync:Setup()`. No
migrations yet; the field exists so Batch 2's migration framework has
a clean baseline to detect "old install, no version" vs "version 1".

### 1.5 `[Cross]` Sync protocol versioning + CRC32

Wire format currently has no version field on the outer envelope and no
payload integrity check. Silent corruption is possible the first time a
message shape changes.

- Add `proto = 2` field to every AceSerializer envelope.
- CRC32 (via LibDeflate's built-in) over every compressed payload.
- Receiver rejects unrecognized `proto` and bad CRC; logs once per
  session per sender; never deserializes garbage.
- HELLO message advertises sender's highest supported `pv`; sender
  speaks the minimum of both peers.
- Protocol version bump means subsequent messages from this batch
  (and Batch 2's chunked transfer) carry `proto = 2` onward.

Cross contract: data side owns the wire format. UI side surfaces a
muted warning toast (per Batch 3.12) when a rejected message is logged.

### 1.6 `[UI]` Score cell: missing-vs-zero + raid-anchored gradient + freshness

Today the score cell shows `0` or a blank for both "not in dataset" and
"has data, genuine zero." These are opposite council situations.

- `—` in muted grey for missing-from-dataset with tooltip:
  `"<Name> is not in the BobleLoot dataset. Run tools/wowaudit.py
  and /reload."`
- `0` in the normal numeric style for confirmed-zero with tooltip
  showing which components contributed zero.
- Replace the hard 40/70 red/yellow/green threshold with a gradient
  anchored to the current session's median and max — a score two
  points below median reads differently from a score of 18.
- Add a small corner badge when `_G.BobleLoot_Data.generatedAt` is
  older than 72 hours (yellow) or older than 7 days (red).

### 1.7 `[UI]` Tooltip hierarchy overhaul

The current tooltip is dense but lacks scannable hierarchy. Target
the Details! / BigWigs readability bar.

- Bold title, separator, then a four-column row per component:
  `[label] [raw stat, muted] [weight%] [normalized 0-1, blue] [= pts, white]`
- Footer block with raid context: `Median 61 | Max 88 | This: 74`
- Caveat line when renormalization is meaningful (2+ components
  excluded): `"Score over [active weight sum]% of data"`
- Both `VotingFrame.lua` and `LootFrame.lua` iterate a shared
  `COMPONENT_ORDER` constant (fixes the quiet `pairs()` ordering bug
  in `LootFrame.lua:attachLabel`).

### 1.8 `[UI]` Minimap button + LibDataBroker launcher

Full design already specified in
`docs/superpowers/specs/2026-04-22-ui-overhaul-design.md` — this roadmap
entry exists only to acknowledge the v1.1 deliverable. See that spec for
icon, right-click menu, tooltip contents, persistence shape, and the
`/bl minimap` slash command.

### 1.9 `[UI]` Custom settings panel (replaces `Config.lua`)

Full design already specified in
`docs/superpowers/specs/2026-04-22-ui-overhaul-design.md`. Horizontal
tabs (Weights / Tuning / Loot DB / Data / Test), dark-surface/cyan-accent
VoidstormGamba theme, Blizzard Settings API proxy, AceConfig removed.

When implementing the Weights tab, include a small live-updating example
score row (the downgraded remnant of the former "live-preview config
panel" idea — scope is one row updating in response to slider movement,
not a separate preview surface).

---

## Batch 2 — Everyday UX and scoring nuance (v1.2)

### 2.1 `[Data]` Spec-aware sim selection

Today `_best_wishlist_score` in `wowaudit.py` takes max across all specs,
so a Holy Paladin with a Retribution wishlist has their sim dominated by
Ret scores on Strength plate. Add `mainspec` field to the data file
(from WoWAudit's role/spec field) and use only the matching spec's sim
by default, with a tuning toggle to revert to max-across-specs.

Keep the fetch logic behind one clean function signature so a future
Raidbots swap is a small refactor (deferred pluggable-source-chain work
reduces to this seam).

### 2.2 `[Data]` Role field + per-role history weight multiplier

Trial raiders with no loot history currently score impossibly high on
the history component. Add a `role` field to the data file
(`raider` / `trial` / `bench`) populated from WoWAudit's member status.
Expose a per-role history-weight multiplier in the Tuning tab (default
`trial = 0.5x`) so trial players have reduced history influence.

### 2.3 `[Data]` Cross-tier decay via `--tier` preset

`lootMinIlvl` currently requires manual tuning every tier. Ship a
bundled `tools/tiers/<tier>.json` map of `ilvlFloor`, `mplusCap`,
`historyDays`, `softFloor`, and BiS path per tier name. Add `--tier TWW-S3`
flag that applies the preset without the raid leader needing to memorize
the numbers on patch day.

### 2.4 `[Data]` BOE and Great Vault loot in history

BOE drops and Vault selections are currently invisible to loot history,
so a raider who bought two BiS pieces or vaulted a trinket looks
identical to a fresh player. Audit both sources (RC BOE logs,
`C_WeeklyRewards` for vault) and add a `vault` category in `LootHistory`
with configurable weight (default 0.5x a normal drop).

### 2.5 `[Data]` Tighten sender identity check for DATA messages

`Sync.lua:OnComm` currently checks `UnitIsGroupLeader(sender)` for
SETTINGS and SCORES but not for DATA. A non-leader with a forged
`generatedAt` timestamp can push an arbitrary dataset. Add the leader
check to DATA; extend to a configurable `BobleLootSyncDB.trustedSenders`
whitelist.

### 2.6 `[Data]` Invalidate `addon._leaderScores` on `PARTY_LEADER_CHANGED`

Transparency mode caches the leader's computed scores as
`addon._leaderScores`. When leadership passes mid-raid, these stale
scores remain visible until the next voting-frame open. Clear the cache
on `PARTY_LEADER_CHANGED`.

### 2.7 `[Data]` DB migration framework + automatic prune

Add `BobleLootDB.profile.dbVersion` (initially absent = 0). On
`OnInitialize`, run a sequential `Migrations` table; each migration is
idempotent and bumps `dbVersion`. First real migration converts any
legacy `mplusScore` fields to `mplusDungeons = 0` with a log warning.

Also: prune `BobleLootSyncDB.data` older than 90 days in `Sync:Setup`,
and clean `BobleLootSyncDB.pendingChunks` on every startup.

### 2.8 `[Cross]` Chunked sync protocol v2

Full-dataset single-message broadcasts approach addon-channel throttling
as the roster + sim column count grows. Add `DATACHUNK` message type:

```lua
{ kind = "DATACHUNK", v = version, seq = N, total = N, chunk = payload }
```

- Receiver accumulates in `BobleLootSyncDB.pendingChunks[sender][version]`;
  promotes to `BobleLoot_Data` only when all `total` chunks arrive.
- 30-second timeout discards incomplete transfers.
- HELLO `pv = 2` negotiation; `pv = 1` peers fall back to full-DATA.

Cross contract: data side owns chunking/reassembly. UI side shows a
progress toast (via Batch 3.12) during transfer and a failure toast on
timeout.

### 2.9 `[UI]` "Why this score" pinnable explanation panel

Tooltips disappear on mouse move; councils want to pin the breakdown
while arguing. Add:

- Slash command `/bl explain <Name-Realm>` opens a persistent
  movable AceGUI frame for the currently selected session item.
- Right-click on a score cell in the voting frame opens the same frame.
- Contents: the full tooltip content (1.7) plus a copy-to-chat button
  for council transcript use.

### 2.10 `[UI]` Conflict indicator `~` prefix

When two candidates' scores are within a configurable threshold (default
5 points), prefix both with `~` in the column: `~74` / `~71`. Signals to
the council that the score is not decisive and they should apply judgment.
Threshold lives in the new Settings panel under a Display group.

### 2.11 `[UI]` Transparency-mode compact label + player-side opt-out

The current `"Your score: 74"` transparency label on the RC loot frame
is verbose. Change to `"BL: 74"`; tooltip already explains the rest.
Add a player-side opt-out (profile key, independent of leader toggle)
so a player can always suppress the label on their own screen even when
the leader enables transparency mode.

---

## Batch 3 — Council differentiation (v1.3)

### 3.1 `[Data]` Per-character partial-success ingestion

If `/wishlists` returns data for 18 of 20 characters, the current code
silently emits empty sims for the missing two. Track `fetch_warnings`
and embed them as a Lua comment block at the top of
`BobleLoot_Data.lua` so the raid leader can see which characters
have incomplete data.

### 3.2 `[Data]` Versioned BiS directory

Replace the flat `bis.json` with `bis/<tier>/<class>-<spec>.json`.
`--bis` accepts either a file (backward-compat) or a directory; merges
all JSON files found. Each file is `{ "Name-Realm": [itemIDs] }`.
Per-spec files make per-patch updates reviewable as single-file diffs.

### 3.3 `[Data]` `--bis-from-wishlist` flag

Derive BiS membership from WoWAudit wishlists — any item whose best-spec
score exceeds a threshold (e.g. `2.0%`) is marked BiS for that character.
Removes the most significant manual maintenance burden from the data
pipeline.

### 3.4 `[Data]` GitHub Actions weekly refresh

Add `.github/workflows/refresh.yml` with:

- **lint job** — `pytest tools/` and luacheck on all Lua files
  (`.luacheckrc` configured for WoW globals).
- **refresh job** — scheduled weekly, runs `wowaudit.py`, opens a PR
  titled `chore: weekly data refresh (<date>)` with the data diff.
  API key in GitHub Actions secret `WOWAUDIT_API_KEY`.

### 3.5 `[Data]` Wasted-loot flagging in history

Items that were awarded (logged in RC history) but later disenchanted
or traded away should not count against the recipient's next score.
Hook `TRADE_CLOSED` + inspect `GetTradePlayerItemInfo` to detect, and
mark the history entry as 0-weight.

### 3.6 `[Data]` Bench-mode scoring data layer

Compute scores for all roster members (not just current session
candidates). Expose `ns.Scoring:ComputeAll(itemID)` returning a sorted
list. Consumed by Batch 3.13's UI surface.

### 3.7 `[Cross]` RCLootCouncil schema-drift detection

`LootHistory.lua` falls back across multiple field names for ilvl and
time. Add `LH:DetectSchemaVersion(db)` that checks for `factionrealm`
and other expected keys, logs the detected shape, and increments
`BobleLootDB.profile.rcSchemaDetected` counter visible in
`/bl lootdb` output. Prominent warning if detection fails.

Cross contract: data side detects; UI side shows a warning banner in
the Settings panel's Data tab when detection fails.

### 3.8 `[Cross]` Historical score-trend tracking

Store per-night score-per-item for each player in `BobleLootDB`
(leader-side, just the final float + itemID + timestamp). After four
weeks, surface a sparkline or delta in the score tooltip
("Boble's score has dropped 12 points since tier start").

Cross contract: data side stores and exposes the history; UI side
renders the sparkline in the tooltip (1.7) and in the Explain panel
(2.9).

### 3.9 `[UI]` Side-by-side candidate comparison popout

Shift-click on a score cell opens a resizable movable AceGUI frame
(480×320) showing two columns — the clicked candidate and the
currently-sorted-top candidate. Each component rendered as a bar scaled
to its full weight. Differential (`+7.2 pts`) highlighted on the row
with the largest gap. Directly answers "why is A ranked above B?"
without mental arithmetic.

### 3.10 `[UI]` Ghost weights preview button

Small button anchored to the score column header. Toggles rendering
under an alternate weight preset (default "Farm" — tunable in Settings).
Recomputation is local and instant; no network traffic. Two-second
sanity check of "would our farm weights change the call?"

### 3.11 `[UI]` Loot history viewer

Standalone scrolling table UI via `/bl history` and the minimap
right-click menu. Columns: Player / Item / Date / Response / Weight
Credit. Filters: player dropdown, date-range slider mirroring the
existing `lootHistoryDays` config. Total row per player at the bottom
showing the weighted sum — exactly the number driving the history
score component. Follows the lib-st pattern RC uses natively.

### 3.12 `[UI]` Toast notification system

Replace chat prints for status events (sync complete, dataset stale,
transparency toggled, protocol warning from 1.5, chunk progress
from 2.8). Anchored frame 280×40px top-centre of screen. Fade in 0.2s,
hold 3s, fade 0.5s. One toast queued; subsequent events update the
visible toast's text in place. Success = green, warning = yellow,
error = red. Never uses `UIErrorsFrame`.

### 3.13 `[UI]` Bench-mode UI surface

`/bl benchscore` prints a sorted score table for the current item to
the officer chat channel. Consumes `ns.Scoring:ComputeAll` from 3.6.
Addresses the "is it worth benching X for Y on this boss?" decision.

---

## Batch 4 — Platform hardening & year-two survival (v2.0)

### 4.1 `[Data]` Multi-tier BiS management

`--tier-config` YAML mapping tier names to ilvl floors, mplus caps,
history windows, and BiS file paths. Tier-1 BiS kept read-only in
Settings so historical score displays remain accurate even after
Tier-2 is live.

### 4.2 `[Data]` Tier-token and catalyst item tracking

Catalyst conversions and tier-token awards bypass RC's normal logging.
Hook `C_CurrencyInfo` vault/catalyst flows and `ITEM_CHANGED` to
capture them. Weight separately (configurable, default 0.75x a normal
drop).

### 4.3 `[Data]` Export / import for leader handoff

- `wowaudit.py --export <path.json>` writes a portable JSON bundle
  (dataset + scoring config, no secrets).
- `/bl import <path>` loads the JSON into `BobleLootSyncDB.data` and
  re-broadcasts.

Solves "I'm the new leader, I don't have Python or an API key on day one."

### 4.4 `[Data]` Rate limiting + exponential backoff

`http_get_json` currently has no retry. The weekly CI run will hit
WoWAudit's rate limits over a long season (the historical-data loop
fetches one request per raid week). Add exponential backoff:
5s / 30s / cached-fallback. Track `X-RateLimit-Remaining` if present.

### 4.5 `[Data]` Character rename / realm transfer migration

After a year, some characters transfer realms. Both `BobleLootSyncDB`
and `RCLootCouncilLootDB` will have stale `Name-OldRealm` keys. Ship
a `renames.json` sidecar (`bis/` neighbour) mapping
`"Old-Realm": "New-Realm"`. The build step applies renames before
emitting; `LootHistory:Apply` checks `BobleLootDB.profile.renames`
before the name lookup.

### 4.6 `[Data]` Automated scoring regression tests in CI

Add `tools/test_scoring.py`: reads a sample `BobleLoot_Data.lua` via a
regex-based parser, runs the scoring formula in Python, asserts
expected outputs. Exercises nil-sim, zero-history-cap, all-nil-component,
and the 1.2 nil-vs-zero fix. Runs in CI before every release.

### 4.7 `[Data]` `scoreOverrides` table in `BobleLoot_Data.lua`

For edge-case items (cosmetic mounts, legendary memories, high-variance
trinkets), the Python tool writes a `scoreOverrides = { [itemID] = float }`
table. `Scoring:Compute` checks this before computing. No in-game
editor; maintenance is in the same workflow as the BiS files.

### 4.8 `[Cross]` RCLootCouncil version-compatibility matrix

Known-shape table keyed by RC major version, storing field-path
resolvers for each RC version the addon has been tested against.
Detected RC version (from `_G.RCLootCouncil.version`) selects the
right resolver.

Cross contract: data side owns the compatibility table; UI side
renders a "Tested on RC %s, detected %s" line in the Settings panel's
Data tab, coloured green on match, yellow on "newer than tested,"
red on unsupported.

### 4.9 `[Cross]` Write score into RC candidate `Note` field

RC allows addons to pre-populate the per-candidate Note field. On
voting frame open, write `note = tostring(score)` if the note is blank.
Council members who don't run BobleLoot still see the number in RC's
native Note column.

Cross contract: data side computes; UI side writes the note via the
existing `RCVotingFrame:UpdateScrollTable` hook.

### 4.10 `[UI]` "RC not detected" warning banner

After a 10-second startup grace period, if RC is not hooked, show a
prominent banner in the Settings panel's Data tab reading
`"|cffff5555RCLootCouncil not detected. Score column will appear once
RC loads.|r"` — replacing the current "No data file loaded" message
which is a different condition.

Replaces what was originally spec'd as standalone-without-RC mode
(cut — see Non-goals #1).

### 4.11 `[UI]` Colorblind-safe palette

Add a "Color mode" dropdown in the Settings panel's Display group:

- **Default** — current red/yellow/green ramp.
- **Deuter/Protan** — orange-to-blue (`#FF8C00` low, `#4D94FF` high).
- **High Contrast** — white text on coloured backgrounds rather than
  coloured text on default background.

Applies to score cells, transparency label, toast system, and
comparison popout bars. Stored per-profile via AceDB.

### 4.12 `[UI]` Empty and error states audit

Single pass across every UI surface to ensure every empty/error
condition has a designed state, not an accidental blank:

- Score cell, no dataset entry — done in 1.6.
- Score cell, no components with data — `"?"` in muted grey.
- History viewer, zero entries — centred help text explaining how to
  widen the date window or check RC loot history.
- Sync timeout — toast reading `"Dataset sync timed out — using local
  data."` rather than silence.
- Settings panel Data tab, RC missing — see 4.10.
- Settings panel Test tab, RC missing or solo — button disabled with
  tooltip explaining why.

---

## Cross-cutting principles

These govern every implementation plan. Any deviation requires written
justification in the affected plan.

### Product

1. **Never block a raid action.** Every BobleLoot frame is closeable in
   one Escape press and does not overlap RC's voting or loot frames by
   default. Score is advisory; RC's workflow is primary.
2. **Missing data is a state, not a failure.** `—` for missing, `0` for
   confirmed zero, never nil.
3. **Tooltips are the documentation.** No wiki, no help panel. Every
   interactive element's tooltip stands alone.
4. **Density serves council, scannability serves raiders.** Council
   surfaces (voting frame, tooltip, comparison popout) earn dense
   information. Player surfaces (transparency label, toast) communicate
   at a glance.
5. **Configuration changes show immediate, visible consequence.**

### Technical

6. **Ship-survivable sync.** Every cross-client message carries `proto`
   and CRC32. Unrecognized `proto` is logged once and dropped — never
   deserialized.
7. **Pipeline is best-effort, never fatal.** `wowaudit.py` never
   `sys.exit()`s on partial failure. Per-endpoint errors degrade to
   warnings in the generated Lua; a successful run with cached fallback
   is strictly better than no run.
8. **One source of truth per concern.** Palette in `UI/Theme.lua`.
   Score-to-colour mapping in `Theme.ScoreColor`. Component ordering
   in a shared `COMPONENT_ORDER` constant consumed by both
   `VotingFrame.lua` and `LootFrame.lua`.
9. **Schema-versioned persistence.** `BobleLootDB.profile.dbVersion`
   and `BobleLootSyncDB.schemaVersion` consulted by every migration.
   Additive schema changes are safe; removals go through a one-release
   deprecation window.
10. **RC coupling is explicit and detected.** Every field read from
    `RCLootCouncilLootDB` or RC session entries has a documented
    expected shape and a logged fallback. Silent nil returns are never
    acceptable.
11. **Follow addon-community conventions.** LibDBIcon for minimap,
    AceDB for persistence, AceComm for raid channel, lib-st for
    scrolling tables, `GameTooltip` with `AddDoubleLine` for tooltips,
    `BackdropTemplate` for frames.

### Collaboration

12. **Every item carries an ownership tag.** `[UI]`, `[Data]`, or
    `[Cross]`. `[Cross]` items have a wire/protocol contract agreed
    before either side ships — the contract lives in the item's
    implementation plan.
13. **Shared constants live in one module consumed by both sides.**
    `Scoring.lua` exposes `COMPONENT_ORDER`. `ns.Theme.ScoreColor`
    owns the score-to-colour mapping. `ns.Sync` owns protocol
    constants. Neither side duplicates.
14. **Non-goals are written down.** Listed above. They are not
    re-litigated in later sessions.

---

## Top 3 risks

1. **WoWAudit API drift** — highest probability. Historical-data
   endpoint shape changes silently zero out M+ scores. Mitigated by
   1.1 (schema validation + cached fallback) and 4.4 (retry/backoff).
2. **RCLootCouncil schema change** — medium probability, high impact.
   Silent history-component drop for every scorer. Mitigated by 3.7
   (schema-drift detection) and 4.8 (version-compat matrix).
3. **Addon-channel throttling as dataset grows** — medium probability
   as roster × sim-column count expands over multiple tiers. Mitigated
   by 2.8 (chunked protocol v2) and a `--prune-sims` flag on the
   Python tool to drop near-zero sim entries.

---

## Deliverables

### This document

`docs/superpowers/specs/2026-04-22-bobleloot-year-one-roadmap-design.md`
— the stable parent. Updated only when batch composition changes.

### Referenced

`docs/superpowers/specs/2026-04-22-ui-overhaul-design.md` — authoritative
detail for items 1.8 (minimap) and 1.9 (settings panel).

### To be written (one per batch, later sessions, via `writing-plans`)

- `docs/superpowers/plans/YYYY-MM-DD-batch-1-foundational-resilience-plan.md`
- `docs/superpowers/plans/YYYY-MM-DD-batch-2-ux-scoring-nuance-plan.md`
- `docs/superpowers/plans/YYYY-MM-DD-batch-3-council-differentiation-plan.md`
- `docs/superpowers/plans/YYYY-MM-DD-batch-4-platform-hardening-plan.md`

---

## Item index (45 items)

| Batch | Item | Tag | Title |
|---|---|---|---|
| 1 | 1.1 | Data | `wowaudit.py` hardening |
| 1 | 1.2 | Data | `Scoring:Compute` nil-vs-zero fix |
| 1 | 1.3 | Data | pytest harness for `wowaudit.py` |
| 1 | 1.4 | Data | `BobleLootSyncDB.schemaVersion` |
| 1 | 1.5 | Cross | Sync `proto` version + CRC32 |
| 1 | 1.6 | UI | Score cell missing-vs-zero + gradient + freshness |
| 1 | 1.7 | UI | Tooltip hierarchy overhaul |
| 1 | 1.8 | UI | Minimap button + LDB (see UI Overhaul) |
| 1 | 1.9 | UI | Custom settings panel (see UI Overhaul) |
| 2 | 2.1 | Data | Spec-aware sim selection |
| 2 | 2.2 | Data | Role field + per-role history weight |
| 2 | 2.3 | Data | Cross-tier `--tier` preset |
| 2 | 2.4 | Data | BOE + vault loot in history |
| 2 | 2.5 | Data | DATA sender-identity check |
| 2 | 2.6 | Data | `_leaderScores` invalidation on leader change |
| 2 | 2.7 | Data | DB migration framework + SyncDB prune |
| 2 | 2.8 | Cross | Chunked sync protocol v2 |
| 2 | 2.9 | UI | Pinnable "Why this score" panel |
| 2 | 2.10 | UI | Conflict indicator `~` prefix |
| 2 | 2.11 | UI | Transparency compact label + opt-out |
| 3 | 3.1 | Data | Per-character partial-success ingestion |
| 3 | 3.2 | Data | Versioned BiS directory |
| 3 | 3.3 | Data | `--bis-from-wishlist` |
| 3 | 3.4 | Data | GitHub Actions weekly refresh |
| 3 | 3.5 | Data | Wasted-loot flagging |
| 3 | 3.6 | Data | Bench-mode scoring data layer |
| 3 | 3.7 | Cross | RC schema-drift detection |
| 3 | 3.8 | Cross | Historical score-trend tracking |
| 3 | 3.9 | UI | Candidate comparison popout |
| 3 | 3.10 | UI | Ghost weights preview button |
| 3 | 3.11 | UI | Loot history viewer |
| 3 | 3.12 | UI | Toast notification system |
| 3 | 3.13 | UI | Bench-mode UI surface |
| 4 | 4.1 | Data | Multi-tier BiS management |
| 4 | 4.2 | Data | Tier-token + catalyst tracking |
| 4 | 4.3 | Data | Export/import for leader handoff |
| 4 | 4.4 | Data | Rate-limiting + backoff |
| 4 | 4.5 | Data | Character rename sidecar |
| 4 | 4.6 | Data | Scoring regression tests in CI |
| 4 | 4.7 | Data | `scoreOverrides` table in data file |
| 4 | 4.8 | Cross | RC version-compat matrix |
| 4 | 4.9 | Cross | Write score into RC Note field |
| 4 | 4.10 | UI | RC-not-detected warning banner |
| 4 | 4.11 | UI | Colorblind-safe palette |
| 4 | 4.12 | UI | Empty/error states audit |

**Totals:** Batch 1 = 9, Batch 2 = 11, Batch 3 = 13, Batch 4 = 12 → **45 items**.
