# UI Overhaul — Minimap Button + Custom Settings Panel

**Date:** 2026-04-22
**Target version:** 1.1.0
**Status:** Design approved, pending implementation plan

## Objective

Replace BobleLoot's AceConfig-based Blizzard Interface Options panel with a
custom in-game window that matches the visual language of the sibling
VoidstormGamba addon (dark surfaces, cyan accent, horizontal tabs), and add a
minimap button so users can reach the UI from one click instead of `/bl` or
four levels of Esc menus.

## Scope decisions

| Decision | Choice | Rationale |
|---|---|---|
| Surfaces to add | Minimap button + custom settings panel | Replaces AceConfig; one settings surface reachable from three paths (minimap / slash / Esc menu) |
| Library source | Ship own `Libs/` copied from VSG | Standalone operation; RCLootCouncil does not bundle LDB/LibDBIcon |
| Panel layout | Horizontal tabs at top | 5 short tab contents; matches VSG MainFrame; no sidebar needed |
| Theme scope | Single fixed palette (VSG "standard") | Advisory addon, small surface; themes are ongoing maintenance tax |
| Architecture | Compact — single `UI/SettingsPanel.lua` | ~15 controls total doesn't justify a widget factory across files |
| AceConfig fate | Deleted entirely | Registering Blizz Settings proxy covers the Esc-menu use case |

## File layout

### New files

```
Libs/
  LibStub/LibStub.lua
  CallbackHandler-1.0/CallbackHandler-1.0.lua   # LDB dependency
  LibDataBroker-1.1/LibDataBroker-1.1.lua
  LibDBIcon-1.0/LibDBIcon-1.0.lua
  Libs.xml                                       # <Include>s each .lua

UI/
  Theme.lua                                      # ~30 lines, color constants + helpers
  SettingsPanel.lua                              # ~600 lines, shell + 5 tab builders
  MinimapButton.lua                              # ~150 lines, LDB launcher
```

Library files copied verbatim from `VoidstormGamba/Libs/` so we know the same
versions are in production use. LibStub's version-wins embedding protocol
means if another addon loads newer copies first, ours are skipped cleanly.

### Deleted files

```
Config.lua            # superseded by UI/SettingsPanel.lua
embeds.xml            # Libs.xml referenced directly in TOC
```

### BobleLoot.toc load order

```
## Interface: 120005
## Title: Boble Loot
## Version: 1.1.0
## OptionalDeps: RCLootCouncil
## SavedVariables: BobleLootDB, BobleLootSyncDB
## IconTexture: Interface\Icons\inv_misc_dice_01

Libs\Libs.xml

Data\BobleLoot_Data.lua

Core.lua
Scoring.lua
Sync.lua
VotingFrame.lua
LootFrame.lua
RaidReminder.lua
LootHistory.lua
TestRunner.lua

UI\Theme.lua
UI\SettingsPanel.lua
UI\MinimapButton.lua
```

UI loads last because its initialization reads from modules that must already
be registered on `ns`.

## Theme module (`UI/Theme.lua`)

A flat constants table with two small helpers. No registry, no theme
switcher, no parent/child merging. Distilled from VSG's `standard` palette.

Keys exposed on `ns.Theme`:

- Accent / semantic colors: `accent`, `accentDim`, `gold`, `success`,
  `warning`, `danger`, `muted`, `white`
- Surfaces: `bgBase`, `bgSurface` (section cards), `bgInput`, `bgTitleBar`,
  `bgTabActive`
- Borders: `borderNormal`, `borderAccent`
- Fonts: `fontTitle`, `fontBody`, `sizeTitle`, `sizeHeading`, `sizeBody`,
  `sizeSmall`

Helpers:

- `Theme.ApplyBackdrop(frame, bgKey, borderKey)` — applies a consistent
  backdrop on any frame via `BackdropTemplateMixin` (9.x+ safe).
- `Theme.ScoreColor(score)` — maps 0–100 to `success`/`warning`/`danger`
  boundaries 70/40, so the score tooltip and in-panel previews share one
  source of truth.

All consumers read colors as `ns.Theme.accent` (flat rgba array). A future
palette swap becomes a single-file table replacement.

## MinimapButton module (`UI/MinimapButton.lua`)

LDB launcher registered with LibDBIcon. Icon
`Interface\Icons\inv_misc_dice_01` to match the TOC's `IconTexture`.

### Interactions

- **Left-click** → `ns.SettingsPanel:Toggle()`
- **Right-click** → `EasyMenu` dropdown:
  - `Broadcast dataset` → `ns.Sync:BroadcastNow(addon)`
  - `Refresh loot history` → `ns.LootHistory:Apply(addon)` then chat
    confirmation using `ns.LootHistory.lastMatched/lastScanned`
  - `Run test session` → submenu with `3 items` / `5 items` / `10 items`
    calling `ns.TestRunner:Run(addon, N, true)`
  - `Transparency mode` — checkbox; `disabled = not UnitIsGroupLeader("player")`;
    click calls `addon:SetTransparencyEnabled(v, true)`
  - `---`
  - `Open settings` → `ns.SettingsPanel:Open()`
  - `Version 1.1.0` (disabled, info only)

### Tooltip (built on `OnTooltipShow`)

Lazy each hover, so it's always current without subscriptions:

- Title `Boble Loot` in cyan
- `Dataset version: <generatedAt>` (muted if `_G.BobleLoot_Data` missing)
- `Characters loaded: N`
- `Loot history: matched/scanned (source: <lastSource>)`
- `Transparency: ON (by <leader>)` / `OFF` / muted if solo
- Blank line
- Muted hint `Left-click: open settings | Right-click: quick actions`

### Persistence

`BobleLootDB.profile.minimap = { hide = false, minimapPos = 220 }` — the
standard shape LibDBIcon's `:Register` expects. `/bl minimap` flips `hide`
and calls `LibDBIcon:Show/Hide("BobleLoot")`.

Double-register guard: check `LibDBIcon:IsRegistered("BobleLoot")` before
register so `/reload` doesn't throw.

## SettingsPanel module (`UI/SettingsPanel.lua`)

### Shell

- Top-level `Frame` named `BobleLootSettingsFrame`, `UIParent`,
  `BackdropTemplate`. Size 560×420. Movable, draggable by title bar,
  `SetClampedToScreen(true)`, strata `HIGH`.
- **Title bar** (28px): `bgTitleBar` fill, cyan underline, label
  `"Boble Loot — Settings"` left, close X (danger-red on hover) right.
- **Tab bar** (32px): five tabs — `Weights` / `Tuning` / `Loot DB` / `Data`
  / `Test`. Active tab uses `bgTabActive` fill with 2px cyan bottom border.
- **Body**: `ScrollFrame` with child `Frame` per tab. Tabs are built once on
  first Open, shown/hidden on switch (state preserved). Scrolling activates
  only when a tab exceeds ~320px (Tuning and Loot DB will likely trigger).
- **Position**: saved to `BobleLootDB.profile.panelPos`. Default CENTER.
  Panel starts hidden on every load — opening is an explicit user action.

### Tab builders

Each `BuildXxxTab(parent)` is a single local function taking the body frame
as parent.

- **`BuildWeightsTab`** — one row per component (sim, bis, history,
  attendance, mplus): 110px label · toggle · slider · right-aligned percent
  readout. Slider setter calls existing `normalizeWeights()` logic (copied
  from Config.lua) then refreshes every slider's displayed value so live
  renormalization is visible. Enable-toggle logic identical to current
  Config.lua behavior.
- **`BuildTuningTab`** — partial-BiS slider, `Override caps` toggle, sim cap
  (hidden/dimmed when override off), M+ cap, soft floor (history cap),
  loot-history-days slider. Each `Apply` callback (history-days changes)
  re-runs `ns.LootHistory:Apply(addon)` the same way Config.lua does.
- **`BuildLootDBTab`** — four category sliders (bis, major, mainspec,
  minor), min-ilvl slider, plus a status line
  `"Last scan: M/N matched (source: ...)"` from `ns.LootHistory.last*`, and
  a `Refresh now` button calling `ns.LootHistory:Apply(addon)`.
- **`BuildDataTab`** — info panel with `generatedAt`, character count, caps;
  `Broadcast to raid` button → `ns.Sync:BroadcastNow`; leader-only
  `Transparency mode` toggle with explanatory hint line; `Open WoWAudit team
  page` button (hidden if `data.teamUrl` missing) — uses a StaticPopup with
  an edit box for ctrl-C copy, matching RaidReminder's pattern.
- **`BuildTestTab`** — item-count slider (1–20), `Use dataset items` toggle,
  `Run test session` button. Button disabled with tooltip when
  `UnitIsGroupLeader("player") == false` or RC not loaded.

### Local widget helpers

Not a cross-file factory — shortcut constructors kept local so tab builders
read top-to-bottom:

- `MakeSlider(parent, opts)` — wraps `OptionsSliderTemplate`, cyan track,
  value label to the right. `opts = { min, max, step, label, get, set, isPercent, width }`.
- `MakeToggle(parent, opts)` — checkbutton with cyan check texture.
- `MakeButton(parent, text, onClick, opts)` — `UIPanelButtonTemplate` +
  `Theme.ApplyBackdrop`; `opts.danger = true` applies red variant.
- `MakeSection(parent, title)` — returns a child `Frame` styled as a
  section card with heading FontString; returns both the card and the
  inner content region for widget placement.

### Public API

Consumed by `MinimapButton`, `Core.lua` slash handler, and `Sync.lua`:

```lua
ns.SettingsPanel:Setup(addon)          -- called in Core:OnInitialize
ns.SettingsPanel:Toggle()              -- open/close
ns.SettingsPanel:Open()                -- open + switch to last tab
ns.SettingsPanel:OpenTab(name)         -- "weights"|"tuning"|"lootdb"|"data"|"test"
ns.SettingsPanel:Refresh()             -- re-read db.profile + roster state
```

`Setup(addon)` does NOT build frames — shell and tabs are lazily built on
first `Open`/`Toggle` to keep `/reload` cost near zero for users who never
open the panel.

### Blizzard Settings API registration

A minimal proxy registered via the 10.x `Settings` API containing one
`CreateControl` button `Open Boble Loot`. ~15 lines. Handles the
`Settings`/`InterfaceOptionsFrame_OpenToCategory`/`AceConfigDialog:Open`
three-path fallback already present in `Config.lua:Open`, preserved intact.

## Core.lua integration

### Changes

- Delete `ns.Config:Setup(self)` call from `OnInitialize`.
- Add `ns.SettingsPanel:Setup(self)` in `OnInitialize`.
- Add `ns.MinimapButton:Setup(self)` in `OnEnable` after
  Sync + RaidReminder + LootHistory setup (tooltip reads from those).
- Rewire slash `/bl config` → `ns.SettingsPanel:Open()`.
- Add `/bl minimap` subcommand: flips `db.profile.minimap.hide` and calls
  `LibDBIcon:Show("BobleLoot")` / `:Hide(...)`.
- Update usage string at bottom of `OnSlashCommand` to include `minimap`.

### Profile schema additions (in `DB_DEFAULTS.profile`)

```lua
minimap  = { hide = false, minimapPos = 220 },
panelPos = { point = "CENTER", x = 0, y = 0 },
lastTab  = "weights",
```

Read via AceDB's default-merge. No migration script needed — existing 1.0.1
users get these on first 1.1.0 load.

## Sync.lua integration

`Sync:OnComm` already calls `ns.LootFrame:Refresh()` when SETTINGS messages
arrive. Add a matching `ns.SettingsPanel:Refresh()` call in the same branch
so non-leader raiders watching the Data tab see the transparency state
update in real time when the leader toggles it.

## Edge cases handled

1. **Settings API shape varies by patch** — the three-path fallback
   (`Settings.OpenToCategory` → `InterfaceOptionsFrame_OpenToCategory` →
   `AceConfigDialog:Open`) from Config.lua is preserved in
   `SettingsPanel:Open`.
2. **Frame strata HIGH** — panel sits above RCLootCouncil's voting frame so
   opening mid-raid doesn't cover the voting UI; user can drag aside.
3. **LibDBIcon double-register** — guard with `:IsRegistered("BobleLoot")`
   before `:Register` so `/reload` is safe.
4. **Leader-only transparency UI** — the Data tab's transparency toggle
   re-reads `UnitIsGroupLeader("player")` on every tab-show via an OnShow
   hook, because leadership can change while the panel stays open.
5. **Panel opened without data loaded** — Data tab shows
   `"|cffff5555No dataset loaded.|r"` instead of zeros; Test tab's button
   disables with reason.
6. **Backdrop template on old clients** — `BackdropTemplate` exists on 9.0+.
   BL's `Interface: 120005` (Retail 12.0) is well past that threshold; no
   compat shim needed.
7. **Collaboration with v1.0.1 debugchar** — new slash command
   `/bl debugchar <Name-Realm>` shipped by Kotoma92 stays as-is; not
   exposed in the GUI (developer tool).

## Manual verification plan

No Lua test framework in this addon — verification is in-game.

1. **Fresh load** — `/reload` with RC loaded. Verify no errors (via
   `/console scriptErrors 1`). Verify minimap icon appears. Verify
   `/bl config` opens the new panel.
2. **RC-absent load** — disable RCLootCouncil, `/reload`. Verify addon
   still loads, settings panel opens, Test tab's Run button is disabled
   with a reason.
3. **All five tabs** — visit each tab, change every control, `/reload`,
   reopen, verify values persisted via AceDB.
4. **Weight renormalization** — disable components, move sliders, verify
   the displayed percentages live-renormalize to 100% across enabled
   components.
5. **Minimap tooltip** — hover; verify dataset version, char count, loot
   history match, and transparency state reflect reality.
6. **Right-click quick actions** — Broadcast, Refresh, Run test, toggle
   transparency, Open settings — all functional.
7. **Transparency propagation** — in a party as leader, toggle on via
   minimap; confirm panel updates; confirm `/bl transparency on|off` still
   works and updates panel UI.
8. **`/bl minimap`** — hide icon, verify, `/bl minimap` again, verify it
   reappears at saved position.
9. **Esc → Options → AddOns → Boble Loot** — verify the proxy button
   opens the real panel, all three Settings-API fallback paths tolerated.
10. **Panel drag / position persistence** — drag panel, close, `/reload`,
    reopen, verify position restored.

## Explicitly out of scope

- No theme switcher, no multiple themes.
- No per-character settings (AceDB profile stays account-wide).
- No "reset to defaults" button (AceDB built-in profile management covers
  this; nobody has asked).
- No localization — BL has no `Locales/` yet and has not needed one.
- No GUI surface for `/bl debugchar` — it stays slash-only as a developer
  diagnostic.
- No changes to `Scoring.lua`, `VotingFrame.lua`, `LootFrame.lua`,
  `RaidReminder.lua`, `LootHistory.lua`, or `TestRunner.lua`. UI work only
  reads from those modules; it does not modify their logic.
