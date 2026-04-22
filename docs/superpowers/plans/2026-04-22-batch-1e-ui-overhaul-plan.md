# Plan 1E — UI Overhaul: Minimap Button + Custom Settings Panel

**Date:** 2026-04-22
**Target version:** 1.1.0
**Status:** Ready for execution
**Plan author:** Claude (Sonnet 4.6)

## Roadmap cross-reference

- **Item 1.8** `[UI]` Minimap button + LibDataBroker launcher —
  `docs/superpowers/specs/2026-04-22-bobleloot-year-one-roadmap-design.md`
  > "Full design already specified in `docs/superpowers/specs/2026-04-22-ui-overhaul-design.md`
  > — this roadmap entry exists only to acknowledge the v1.1 deliverable.
  > See that spec for icon, right-click menu, tooltip contents, persistence
  > shape, and the `/bl minimap` slash command."

- **Item 1.9** `[UI]` Custom settings panel (replaces `Config.lua`) —
  `docs/superpowers/specs/2026-04-22-bobleloot-year-one-roadmap-design.md`
  > "Full design already specified in
  > `docs/superpowers/specs/2026-04-22-ui-overhaul-design.md`. Horizontal
  > tabs (Weights / Tuning / Loot DB / Data / Test), dark-surface/cyan-accent
  > VoidstormGamba theme, Blizzard Settings API proxy, AceConfig removed.
  > When implementing the Weights tab, include a small live-updating example
  > score row."

**Authoritative design document:**
`docs/superpowers/specs/2026-04-22-ui-overhaul-design.md`

## Goal and architecture

Replace BobleLoot's AceConfig-based Blizzard Interface Options panel with a
custom in-game window that matches the VoidstormGamba visual language (dark
surfaces, cyan accent, horizontal tabs), and add a minimap button so users
reach the UI in one click. The new panel exposes exactly the same knobs as
the deleted `Config.lua` — no settings regress. A single `UI/Theme.lua`
module becomes the palette source of truth, intentionally landing in an early
task so that plan 1D (tooltip hierarchy, score gradient) can reference
`ns.Theme.ScoreColor` without waiting for the full panel work to finish.
Libraries are copied verbatim from VoidstormGamba's flat `Libs/` directory
and embedded via a new `Libs/Libs.xml`, replacing the stub `embeds.xml`.

## Cross-plan boundaries

- Do NOT touch `VotingFrame.lua`, `LootFrame.lua`, `Scoring.lua`, or the
  sync protocol wire format. Those belong to plans 1B / 1C / 1D.
- `UI/Theme.lua` (Task 2) is a **blocking dependency for plan 1D** — it must
  land and be committed before 1D work begins, enabling that plan to import
  `ns.Theme.ScoreColor` and `ns.Theme.accent`.
- `Config.lua` is deleted by this plan (Task 13). No other plan touches it.
- `Sync.lua` receives one additive call in Task 15; no protocol changes.

---

## File structure

Copied verbatim from the UI Overhaul spec so the executing engineer has
everything in one document.

### New files

```
Libs/
  LibStub.lua                               (copied from VoidstormGamba/Libs/)
  CallbackHandler-1.0.lua                   (copied from VoidstormGamba/Libs/)
  LibDataBroker-1.1.lua                     (copied from VoidstormGamba/Libs/)
  LibDBIcon-1.0.lua                         (copied from VoidstormGamba/Libs/)
  Libs.xml                                  (<Include> for each .lua above)

UI/
  Theme.lua         (~30 lines, color constants + helpers)
  SettingsPanel.lua (~600 lines, shell + 5 tab builders)
  MinimapButton.lua (~150 lines, LDB launcher + right-click menu)
```

### Deleted files

```
Config.lua      (superseded by UI/SettingsPanel.lua)
embeds.xml      (replaced by Libs/Libs.xml referenced directly in TOC)
```

### Final BobleLoot.toc load order

```
## Interface: 120005
## Title: Boble Loot
## Notes: Adds a 0-100 candidate score column to RCLootCouncil based on WoWAudit sims, BiS lists, attendance, M+ score and loot history.
## Author: <your-guild>
## Version: 1.1.0
## OptionalDeps: RCLootCouncil
## SavedVariables: BobleLootDB, BobleLootSyncDB
## X-Category: Raid
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

UI files load last because their initialization reads from modules that must
already be registered on `ns`. Note that `Config.lua` is absent (deleted) and
`embeds.xml` is absent (deleted). `Libs\Libs.xml` takes its place.

---

## Tasks

---

### Task 1 — Copy libraries; create `Libs/` and `Libs/Libs.xml`

**Files:**
- Create `Libs/LibStub.lua` (copy from `VoidstormGamba/Libs/LibStub.lua`)
- Create `Libs/CallbackHandler-1.0.lua` (copy from `VoidstormGamba/Libs/CallbackHandler-1.0.lua`)
- Create `Libs/LibDataBroker-1.1.lua` (copy from `VoidstormGamba/Libs/LibDataBroker-1.1.lua`)
- Create `Libs/LibDBIcon-1.0.lua` (copy from `VoidstormGamba/Libs/LibDBIcon-1.0.lua`)
- Create `Libs/Libs.xml`

**Context:** VoidstormGamba ships its LDB/LibDBIcon libraries as four flat
files directly inside `VoidstormGamba/Libs/` (no per-library subdirectories).
BobleLoot mirrors this flat layout. LibStub's version-wins protocol means if
another addon (e.g. RCLootCouncil's own embed) loads newer copies first, ours
are silently skipped — no conflict.

- [ ] Create the `Libs/` directory inside the BobleLoot addon folder:
  ```
  E:\Games\World of Warcraft\_retail_\Interface\AddOns\BobleLoot\Libs\
  ```

- [ ] Copy each file verbatim from VoidstormGamba:
  ```
  cp "E:/Games/World of Warcraft/_retail_/Interface/AddOns/VoidstormGamba/Libs/LibStub.lua" \
     "E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/Libs/LibStub.lua"

  cp "E:/Games/World of Warcraft/_retail_/Interface/AddOns/VoidstormGamba/Libs/CallbackHandler-1.0.lua" \
     "E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/Libs/CallbackHandler-1.0.lua"

  cp "E:/Games/World of Warcraft/_retail_/Interface/AddOns/VoidstormGamba/Libs/LibDataBroker-1.1.lua" \
     "E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/Libs/LibDataBroker-1.1.lua"

  cp "E:/Games/World of Warcraft/_retail_/Interface/AddOns/VoidstormGamba/Libs/LibDBIcon-1.0.lua" \
     "E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/Libs/LibDBIcon-1.0.lua"
  ```

- [ ] Create `Libs/Libs.xml` with the following content:
  ```xml
  <Ui xmlns="http://www.blizzard.com/wow/ui/"
      xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
      xsi:schemaLocation="http://www.blizzard.com/wow/ui/ ..\FrameXML\UI.xsd">
      <Script file="LibStub.lua"/>
      <Script file="CallbackHandler-1.0.lua"/>
      <Script file="LibDataBroker-1.1.lua"/>
      <Script file="LibDBIcon-1.0.lua"/>
  </Ui>
  ```
  The TOC will reference this file as `Libs\Libs.xml` (Task 3).

- [ ] **Do NOT update the TOC yet.** The TOC still points at `embeds.xml`.
  Task 3 rewires both at once so there is never a broken intermediate state.

- [ ] Commit:
  ```
  git add Libs/
  git commit -m "Add Libs/ with LibStub, CallbackHandler, LibDataBroker, LibDBIcon copied from VoidstormGamba"
  ```

**Verification (deferred to Task 3):** The libs do not load until the TOC
references `Libs\Libs.xml`. Verification happens after Task 3.

---

### Task 2 — Write `UI/Theme.lua`

**Files:**
- Create `UI/Theme.lua`

**Why first among the UI files:** `ns.Theme` is a dependency of plan 1D
(score gradient, `ScoreColor` usage in tooltips). Committing this file
immediately unblocks that parallel track. `UI/SettingsPanel.lua` and
`UI/MinimapButton.lua` also consume it but are written in later tasks.

- [ ] Create the `UI/` directory:
  ```
  E:\Games\World of Warcraft\_retail_\Interface\AddOns\BobleLoot\UI\
  ```

- [ ] Create `UI/Theme.lua` with the following content in full:

  ```lua
  --[[ UI/Theme.lua
       Single fixed palette for BobleLoot UI surfaces.
       Distilled from VoidstormGamba's "standard" palette.

       All colors are flat RGBA arrays { r, g, b, a } with values 0-1.
       Consumers read as:  ns.Theme.accent[1], etc.
       or unpack:          unpack(ns.Theme.accent)

       A future palette swap is a single-file table replacement.
  ]]

  local _, ns = ...
  local Theme = {}
  ns.Theme = Theme

  -- ── Accent / semantic ──────────────────────────────────────────────────
  Theme.accent      = { 0.20, 0.85, 0.95, 1.00 }  -- cyan  #33D9F2
  Theme.accentDim   = { 0.13, 0.55, 0.62, 1.00 }  -- dim cyan
  Theme.gold        = { 1.00, 0.82, 0.00, 1.00 }  -- #FFD100
  Theme.success     = { 0.10, 0.80, 0.30, 1.00 }  -- green  #19CC4D
  Theme.warning     = { 1.00, 0.65, 0.00, 1.00 }  -- amber  #FFA600
  Theme.danger      = { 0.90, 0.20, 0.20, 1.00 }  -- red    #E63333
  Theme.muted       = { 0.55, 0.55, 0.55, 1.00 }  -- grey
  Theme.white       = { 1.00, 1.00, 1.00, 1.00 }

  -- ── Surfaces ───────────────────────────────────────────────────────────
  Theme.bgBase      = { 0.08, 0.08, 0.10, 0.97 }  -- near-black
  Theme.bgSurface   = { 0.12, 0.12, 0.16, 1.00 }  -- card bg
  Theme.bgInput     = { 0.06, 0.06, 0.08, 1.00 }  -- edit box / slider track
  Theme.bgTitleBar  = { 0.05, 0.05, 0.07, 1.00 }  -- title bar fill
  Theme.bgTabActive = { 0.14, 0.14, 0.20, 1.00 }  -- active tab fill

  -- ── Borders ────────────────────────────────────────────────────────────
  Theme.borderNormal = { 0.20, 0.20, 0.25, 1.00 }
  Theme.borderAccent = { 0.20, 0.85, 0.95, 1.00 }  -- same as accent

  -- ── Fonts ──────────────────────────────────────────────────────────────
  Theme.fontTitle   = "Fonts\\FRIZQT__.TTF"
  Theme.fontBody    = "Fonts\\ARIALN.TTF"
  Theme.sizeTitle   = 14
  Theme.sizeHeading = 12
  Theme.sizeBody    = 11
  Theme.sizeSmall   = 10

  -- ── Helpers ────────────────────────────────────────────────────────────

  --- Apply a consistent backdrop to any frame via BackdropTemplateMixin.
  -- @param frame     Frame that has been created with "BackdropTemplate"
  -- @param bgKey     Key in ns.Theme for the background color (e.g. "bgBase")
  -- @param borderKey Key in ns.Theme for the border color (e.g. "borderNormal")
  function Theme.ApplyBackdrop(frame, bgKey, borderKey)
      local bg  = Theme[bgKey]     or Theme.bgBase
      local bdr = Theme[borderKey] or Theme.borderNormal
      frame:SetBackdrop({
          bgFile   = "Interface\\Buttons\\WHITE8X8",
          edgeFile = "Interface\\Buttons\\WHITE8X8",
          edgeSize = 1,
      })
      frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
      frame:SetBackdropBorderColor(bdr[1], bdr[2], bdr[3], bdr[4])
  end

  --- Map a 0-100 score to a color table from this Theme.
  -- Thresholds: >= 70 -> success (green), >= 40 -> warning (amber), else danger (red).
  -- Returns a reference to the color array (do not mutate the return value).
  -- @param score  number 0-100
  -- @return       color array { r, g, b, a }
  function Theme.ScoreColor(score)
      if score == nil then return Theme.muted end
      if score >= 70 then return Theme.success  end
      if score >= 40 then return Theme.warning  end
      return Theme.danger
  end

  --- Map a score to a color relative to the session's median and max.
  -- Used by plan 1D's raid-anchored gradient in the voting frame.
  -- Two-segment linear interpolation:
  --   * score >= max      -> success
  --   * median <= score   -> interpolate warning -> success as score goes from median -> max
  --   * score <  median   -> interpolate danger  -> warning as score goes from 0      -> median
  -- Fallbacks: if median/max are nil, missing, or equal, falls back to the
  -- absolute Theme.ScoreColor thresholds so the tooltip still shows a sensible color.
  -- Returns a new color array (safe to use directly in SetTextColor).
  -- @param score   number 0-100
  -- @param median  number or nil
  -- @param max     number or nil
  -- @return        color array { r, g, b, a }
  function Theme.ScoreColorRelative(score, median, max)
      if score == nil then return Theme.muted end
      if median == nil or max == nil or max <= median then
          return Theme.ScoreColor(score)
      end
      if score >= max then return { Theme.success[1], Theme.success[2], Theme.success[3], Theme.success[4] } end
      local function lerp(a, b, t) return a + (b - a) * t end
      local function mix(c1, c2, t)
          return {
              lerp(c1[1], c2[1], t),
              lerp(c1[2], c2[2], t),
              lerp(c1[3], c2[3], t),
              lerp(c1[4] or 1, c2[4] or 1, t),
          }
      end
      if score >= median then
          local t = (score - median) / (max - median)
          return mix(Theme.warning, Theme.success, t)
      else
          local t = (median > 0) and (score / median) or 0
          return mix(Theme.danger, Theme.warning, t)
      end
  end
  ```

- [ ] Commit:
  ```
  git add UI/Theme.lua
  git commit -m "Add UI/Theme.lua: palette, ApplyBackdrop, ScoreColor, ScoreColorRelative"
  ```

  This commit is the unblocking deliverable for plan 1D. After pushing/sharing,
  plan 1D can safely import `ns.Theme`.

**In-game verification (after Task 3 wires up the TOC):**
- `/dump ns.Theme.accent` → should return `{ 0.2, 0.85, 0.95, 1 }`
- `/dump ns.Theme.ScoreColor(80)` → should return the `success` table
- `/dump ns.Theme.ScoreColor(50)` → `warning`
- `/dump ns.Theme.ScoreColor(20)` → `danger`
- `/dump ns.Theme.ScoreColorRelative(80, 50, 90)` → blend between `warning` and `success` (t ≈ 0.75)
- `/dump ns.Theme.ScoreColorRelative(30, 50, 90)` → blend between `danger` and `warning` (t ≈ 0.60)
- `/dump ns.Theme.ScoreColorRelative(50, nil, nil)` → falls back to `warning` via `ScoreColor`

---

### Task 3 — Update `BobleLoot.toc`

**Files:**
- Modify `BobleLoot.toc` — rewrite entirely

**Context:** This is the first task that makes changes visible in-game.
It simultaneously: bumps `Version`, drops `embeds.xml` from the load order,
adds `Libs\Libs.xml`, removes `Config.lua`, and appends the three `UI\`
files. The old `embeds.xml` file is NOT deleted here (Task 14 deletes it)
to keep the diff focused; leaving it in place is harmless because the TOC
no longer references it.

- [ ] Replace `BobleLoot.toc` with the following:

  ```
  ## Interface: 120005
  ## Title: Boble Loot
  ## Notes: Adds a 0-100 candidate score column to RCLootCouncil based on WoWAudit sims, BiS lists, attendance, M+ score and loot history.
  ## Author: <your-guild>
  ## Version: 1.1.0
  ## OptionalDeps: RCLootCouncil
  ## SavedVariables: BobleLootDB, BobleLootSyncDB
  ## X-Category: Raid
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

  Key changes from the old TOC:
  - `embeds.xml` replaced by `Libs\Libs.xml`
  - `Config.lua` removed from load order
  - `UI\Theme.lua`, `UI\SettingsPanel.lua`, `UI\MinimapButton.lua` added at the bottom
  - `Version: 1.0.2` bumped to `1.1.0`

  Note: `UI\SettingsPanel.lua` and `UI\MinimapButton.lua` do not exist yet
  at this point. The TOC lists them so they can be loaded once created.
  WoW will log a TOC parse warning for missing files but will not crash;
  the existing functionality continues to work.

- [ ] Commit:
  ```
  git add BobleLoot.toc
  git commit -m "Update TOC to 1.1.0: wire Libs.xml, remove Config.lua, add UI/ load order"
  ```

**In-game verification:**
- `/reload`
- Enable script errors: `/console scriptErrors 1`
- Verify no red error box on login. A missing-file warning for
  `UI\SettingsPanel.lua` or `UI\MinimapButton.lua` in the TOC output is
  expected at this point and will resolve in later tasks.
- `/dump LibStub("LibDBIcon-1.0", true)` → should return non-nil (a table),
  confirming the new `Libs.xml` loads successfully.
- `/dump ns.Theme.accent` → `{ 0.2, 0.85, 0.95, 1 }` confirming `Theme.lua`
  loads from the new TOC position.

---

### Task 4 — Write `UI/MinimapButton.lua` shell (LDB + tooltip + left-click)

**Files:**
- Create `UI/MinimapButton.lua`

**Context:** This task creates the file and wires up the LDB launcher,
LibDBIcon registration, tooltip, and left-click. The right-click dropdown
menu is in Task 5 to keep each task's scope small. The `ns.SettingsPanel`
calls in this file will be safe stubs until Task 6 creates the panel.

- [ ] Create `UI/MinimapButton.lua` with the following content:

  ```lua
  --[[ UI/MinimapButton.lua
       LibDataBroker launcher for BobleLoot.
       Left-click  -> toggle the custom settings panel.
       Right-click -> EasyMenu quick-actions dropdown.
       Tooltip     -> live dataset/history/transparency summary.
  ]]

  local ADDON_NAME, ns = ...
  local MB = {}
  ns.MinimapButton = MB

  local addon  -- set in Setup

  -- ── LDB object ────────────────────────────────────────────────────────

  local LDB = LibStub("LibDataBroker-1.1")
  local DBIcon = LibStub("LibDBIcon-1.0")

  local ldbObj = LDB:NewDataObject("BobleLoot", {
      type  = "launcher",
      label = "Boble Loot",
      icon  = "Interface\\Icons\\inv_misc_dice_01",

      OnClick = function(_, button)
          if button == "LeftButton" then
              if ns.SettingsPanel and ns.SettingsPanel.Toggle then
                  ns.SettingsPanel:Toggle()
              end
          elseif button == "RightButton" then
              MB:ShowDropdown()
          end
      end,

      OnTooltipShow = function(tt)
          MB:BuildTooltip(tt)
      end,
  })

  -- ── Tooltip builder ───────────────────────────────────────────────────

  function MB:BuildTooltip(tt)
      local T = ns.Theme
      tt:AddLine("|cff" .. string.format("%02x%02x%02x",
          math.floor(T.accent[1] * 255),
          math.floor(T.accent[2] * 255),
          math.floor(T.accent[3] * 255)) .. "Boble Loot|r")

      local data = _G.BobleLoot_Data
      if not data then
          tt:AddLine("|cff" .. string.format("%02x%02x%02x",
              math.floor(T.muted[1] * 255),
              math.floor(T.muted[2] * 255),
              math.floor(T.muted[3] * 255))
              .. "Dataset: not loaded|r")
      else
          tt:AddDoubleLine("Dataset version:", data.generatedAt or "?",
              1, 1, 1,
              T.muted[1], T.muted[2], T.muted[3])

          local count = 0
          for _ in pairs(data.characters or {}) do count = count + 1 end
          tt:AddDoubleLine("Characters loaded:", tostring(count), 1, 1, 1, 1, 1, 1)
      end

      -- Loot history line
      local lh = ns.LootHistory
      if lh and lh.lastMatched then
          tt:AddDoubleLine(
              "Loot history:",
              string.format("%d/%d (source: %s)",
                  lh.lastMatched or 0,
                  lh.lastScanned or 0,
                  lh.lastSource  or "?"),
              1, 1, 1,
              T.muted[1], T.muted[2], T.muted[3])
      else
          tt:AddDoubleLine("Loot history:", "not yet applied",
              1, 1, 1,
              T.muted[1], T.muted[2], T.muted[3])
      end

      -- Transparency state
      if IsInGroup() or IsInRaid() then
          local on = addon and addon:IsTransparencyEnabled()
          local syncS = addon and addon:GetSyncedSettings()
          local leader = syncS and syncS.transparencyLeader or nil
          if on then
              local suffix = leader and (" (by " .. leader .. ")") or ""
              tt:AddDoubleLine("Transparency:", "ON" .. suffix,
                  1, 1, 1, T.success[1], T.success[2], T.success[3])
          else
              tt:AddDoubleLine("Transparency:", "OFF",
                  1, 1, 1, T.muted[1], T.muted[2], T.muted[3])
          end
      else
          tt:AddDoubleLine("Transparency:", "N/A (solo)",
              1, 1, 1,
              T.muted[1], T.muted[2], T.muted[3])
      end

      tt:AddLine(" ")
      tt:AddLine("|cff" .. string.format("%02x%02x%02x",
          math.floor(T.muted[1] * 255),
          math.floor(T.muted[2] * 255),
          math.floor(T.muted[3] * 255))
          .. "Left-click: open settings  |  Right-click: quick actions|r")
  end

  -- ── Right-click dropdown (body in Task 5) ─────────────────────────────

  function MB:ShowDropdown()
      -- Implemented in Task 5. Stub is intentional.
      -- EasyMenu wiring added there to keep task diffs small.
  end

  -- ── Public API ────────────────────────────────────────────────────────

  function MB:Setup(addonArg)
      addon = addonArg
      local db = addon.db.profile

      -- Ensure minimap sub-table exists with defaults.
      if not db.minimap then
          db.minimap = { hide = false, minimapPos = 220 }
      end

      -- Guard against double-register on /reload.
      if not DBIcon:IsRegistered("BobleLoot") then
          DBIcon:Register("BobleLoot", ldbObj, db.minimap)
      end
  end

  --- Toggle minimap icon visibility. Called by /bl minimap slash command.
  function MB:ToggleMinimapIcon(addonArg)
      local db = (addonArg or addon).db.profile
      db.minimap.hide = not db.minimap.hide
      if db.minimap.hide then
          DBIcon:Hide("BobleLoot")
      else
          DBIcon:Show("BobleLoot")
      end
  end
  ```

- [ ] Commit:
  ```
  git add UI/MinimapButton.lua
  git commit -m "Add UI/MinimapButton.lua: LDB launcher, tooltip, left-click toggle stub"
  ```

**In-game verification:**
- `/reload`
- Confirm minimap icon appears (dice icon, same as TOC `IconTexture`).
- Hover the icon — confirm the tooltip shows: "Boble Loot" in cyan, dataset
  version or "not loaded", loot history line, transparency state, and the
  hint line at the bottom.
- Left-click the icon — nothing visible happens yet (SettingsPanel not
  created until Task 6), but no Lua error should appear.

---

### Task 5 — Wire `UI/MinimapButton.lua` right-click dropdown

**Files:**
- Modify `UI/MinimapButton.lua` — replace the `MB:ShowDropdown()` stub
  with the full `EasyMenu` implementation

**Context:** `EasyMenu` is a Blizzard-provided function available in all
retail clients. It accepts a menu-definition table and a dropdown frame.
We create a dedicated `DropDownFrame` for the menu so it doesn't share
state with other addons' dropdowns.

- [ ] Add the following block to `UI/MinimapButton.lua`. Replace the existing
  `MB:ShowDropdown()` stub (the four comment lines and empty function body)
  with this complete implementation:

  ```lua
  -- ── Dropdown frame (created once, reused on each right-click) ─────────

  local dropdownFrame = CreateFrame("Frame", "BobleLootMinimapDropdown", UIParent,
      "UIDropDownMenuTemplate")

  -- ── Right-click dropdown ───────────────────────────────────────────────

  function MB:ShowDropdown()
      local isLeader = UnitIsGroupLeader("player")
      local lh       = ns.LootHistory
      local data     = _G.BobleLoot_Data
      local addonVer = addon and addon.version or "?"

      local menu = {
          -- Header (disabled title)
          { text = "Boble Loot", isTitle = true, notClickable = true, notCheckable = true },

          -- Broadcast dataset
          {
              text = "Broadcast dataset",
              notCheckable = true,
              disabled = not isLeader,
              func = function()
                  if ns.Sync and ns.Sync.BroadcastNow then
                      ns.Sync:BroadcastNow(addon)
                      addon:Print("announced dataset to raid.")
                  end
              end,
          },

          -- Refresh loot history
          {
              text = "Refresh loot history",
              notCheckable = true,
              func = function()
                  if ns.LootHistory and ns.LootHistory.Apply then
                      ns.LootHistory:Apply(addon)
                      local lh2 = ns.LootHistory
                      addon:Print(string.format(
                          "Loot history refreshed. matched=%d scanned=%d source=%s",
                          lh2.lastMatched or 0,
                          lh2.lastScanned or 0,
                          lh2.lastSource  or "?"))
                  end
              end,
          },

          -- Run test session (submenu)
          {
              text = "Run test session",
              notCheckable = true,
              hasArrow = true,
              menuList = {
                  {
                      text = "3 items", notCheckable = true,
                      func = function()
                          if ns.TestRunner then
                              ns.TestRunner:Run(addon, 3,
                                  addon.db.profile.testUseDatasetItems ~= false)
                          end
                      end,
                  },
                  {
                      text = "5 items", notCheckable = true,
                      func = function()
                          if ns.TestRunner then
                              ns.TestRunner:Run(addon, 5,
                                  addon.db.profile.testUseDatasetItems ~= false)
                          end
                      end,
                  },
                  {
                      text = "10 items", notCheckable = true,
                      func = function()
                          if ns.TestRunner then
                              ns.TestRunner:Run(addon, 10,
                                  addon.db.profile.testUseDatasetItems ~= false)
                          end
                      end,
                  },
              },
          },

          -- Transparency mode toggle (leader-only checkbox)
          {
              text = "Transparency mode",
              checked = addon and addon:IsTransparencyEnabled() or false,
              disabled = not isLeader,
              tooltipOnButton = true,
              tooltipTitle    = isLeader and nil or "Leader only",
              tooltipText     = isLeader and nil
                  or "Only the raid/group leader can toggle transparency mode.",
              func = function()
                  if not isLeader then return end
                  local v = not (addon and addon:IsTransparencyEnabled())
                  addon:SetTransparencyEnabled(v, true)
                  -- Refresh settings panel if open
                  if ns.SettingsPanel and ns.SettingsPanel.Refresh then
                      ns.SettingsPanel:Refresh()
                  end
              end,
          },

          -- Separator
          { text = "", disabled = true, notCheckable = true },

          -- Open settings
          {
              text = "Open settings",
              notCheckable = true,
              func = function()
                  if ns.SettingsPanel and ns.SettingsPanel.Open then
                      ns.SettingsPanel:Open()
                  end
              end,
          },

          -- Version info (disabled, read-only)
          {
              text = "Version " .. addonVer,
              notClickable = true,
              notCheckable = true,
              disabled = true,
          },
      }

      EasyMenu(menu, dropdownFrame, "cursor", 0, 0, "MENU")
  end
  ```

- [ ] Commit:
  ```
  git add UI/MinimapButton.lua
  git commit -m "Wire MinimapButton right-click EasyMenu dropdown with all quick actions"
  ```

**In-game verification:**
- `/reload`
- Right-click the minimap icon — the dropdown appears.
- Verify items visible: title bar, Broadcast dataset, Refresh loot history,
  Run test session (with arrow), Transparency mode (greyed if not leader),
  separator, Open settings, Version line.
- Click "Refresh loot history" — confirm a chat message prints with
  `matched=N scanned=N source=...`.
- Hover "Run test session" — submenu shows 3/5/10 items.
- Click "Open settings" — nothing visible yet (panel not created), but no
  Lua error.
- If in a group as leader: confirm "Transparency mode" is clickable and
  toggles correctly (chat message, re-hovering the minimap tooltip shows
  the updated state).

---

### Task 6 — Write `UI/SettingsPanel.lua` shell

**Files:**
- Create `UI/SettingsPanel.lua`

**Context:** This task creates the frame shell: the outermost frame, title
bar, tab bar, body scroll-frame, tab-switching logic, position persistence,
and the public API (`Setup`, `Toggle`, `Open`, `OpenTab`, `Refresh`).
Tab *content* is built in Tasks 7–11. The shell uses lazy initialization:
`BuildFrames()` runs only on first `Open()`/`Toggle()`, so `/reload` cost
stays near zero for users who never open the panel.

- [ ] Create `UI/SettingsPanel.lua` with the following content:

  ```lua
  --[[ UI/SettingsPanel.lua
       Custom settings panel for BobleLoot.
       Shell: top-level frame, title bar, tab bar, scroll-frame body.
       Tab builders are appended below this shell section.

       Public API:
         ns.SettingsPanel:Setup(addon)     -- called in Core:OnInitialize
         ns.SettingsPanel:Toggle()         -- open or close
         ns.SettingsPanel:Open()           -- open, switch to last tab
         ns.SettingsPanel:OpenTab(name)    -- "weights"|"tuning"|"lootdb"|"data"|"test"
         ns.SettingsPanel:Refresh()        -- re-read db.profile, update all controls
  ]]

  local ADDON_NAME, ns = ...
  local SP = {}
  ns.SettingsPanel = SP

  local addon   -- set by Setup
  local frame   -- top-level Frame (nil until BuildFrames)
  local built   -- bool: have we called BuildFrames yet?

  local PANEL_W   = 560
  local PANEL_H   = 420
  local TITLEBAR_H = 28
  local TABBAR_H   = 32
  local BODY_H     = PANEL_H - TITLEBAR_H - TABBAR_H  -- 360

  local TAB_NAMES  = { "weights", "tuning", "lootdb", "data", "test" }
  local TAB_LABELS = { weights="Weights", tuning="Tuning",
                       lootdb="Loot DB", data="Data", test="Test" }

  local tabs       = {}  -- tab button frames keyed by name
  local tabBodies  = {}  -- content frames keyed by name
  local activeTab  = nil

  -- ── Local widget helpers ───────────────────────────────────────────────
  --
  -- These are intentionally local (not on ns) — the panel is compact enough
  -- that a cross-file widget factory adds no value.

  local function MakeSection(parent, title)
      local T = ns.Theme
      local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
      T.ApplyBackdrop(card, "bgSurface", "borderNormal")

      local heading = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      heading:SetFont(T.fontBody, T.sizeHeading, "OUTLINE")
      heading:SetTextColor(T.accent[1], T.accent[2], T.accent[3], T.accent[4])
      heading:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -6)
      heading:SetText(title)

      -- Inner content region starts below the heading.
      local inner = CreateFrame("Frame", nil, card)
      inner:SetPoint("TOPLEFT",     card, "TOPLEFT",  6, -22)
      inner:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -6, 6)

      return card, inner
  end

  local function MakeToggle(parent, opts)
      -- opts = { label, get, set, width, x, y }
      local T = ns.Theme
      local cb = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
      cb:SetPoint("TOPLEFT", parent, "TOPLEFT", opts.x or 0, opts.y or 0)

      -- The template creates a text child; relabel it.
      local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      lbl:SetFont(T.fontBody, T.sizeBody)
      lbl:SetTextColor(T.white[1], T.white[2], T.white[3])
      lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
      lbl:SetText(opts.label or "")

      cb:SetChecked(opts.get())
      cb:SetScript("OnClick", function(self)
          opts.set(self:GetChecked())
      end)

      -- Cyan check texture override.
      local ck = cb:GetCheckedTexture()
      if ck then ck:SetVertexColor(T.accent[1], T.accent[2], T.accent[3]) end

      cb._label = lbl
      return cb
  end

  local function MakeSlider(parent, opts)
      -- opts = { label, min, max, step, get, set, isPercent, width, x, y }
      local T = ns.Theme
      local w = opts.width or 260

      local s = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
      s:SetPoint("TOPLEFT", parent, "TOPLEFT", opts.x or 0, opts.y or 0)
      s:SetWidth(w)
      s:SetHeight(16)
      s:SetMinMaxValues(opts.min, opts.max)
      s:SetValueStep(opts.step or 1)
      s:SetValue(opts.get())
      s:SetObeyStepOnDrag(true)

      -- Suppress the default "Low" / "High" template text.
      local low  = s:GetRegions()  -- first region is Low text in template
      -- Safer: find named children.
      if _G[s:GetName() .. "Low"]  then _G[s:GetName() .. "Low"]:SetText("") end
      if _G[s:GetName() .. "High"] then _G[s:GetName() .. "High"]:SetText("") end
      if _G[s:GetName() .. "Text"] then _G[s:GetName() .. "Text"]:SetText("") end

      -- Cyan track tint.
      local thumb = s:GetThumbTexture()
      if thumb then
          thumb:SetVertexColor(T.accent[1], T.accent[2], T.accent[3])
      end

      -- Label to the left.
      local lbl = parent:CreateFontString(nil, "OVERLAY")
      lbl:SetFont(T.fontBody, T.sizeBody)
      lbl:SetTextColor(T.white[1], T.white[2], T.white[3])
      lbl:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 2)
      lbl:SetText(opts.label or "")

      -- Value readout to the right.
      local valLbl = parent:CreateFontString(nil, "OVERLAY")
      valLbl:SetFont(T.fontBody, T.sizeBody)
      valLbl:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
      valLbl:SetPoint("LEFT", s, "RIGHT", 6, 0)
      valLbl:SetWidth(46)

      local function updateVal(v)
          if opts.isPercent then
              valLbl:SetText(string.format("%.0f%%", v * 100))
          else
              valLbl:SetText(string.format("%.1f", v))
          end
      end
      updateVal(opts.get())

      s:SetScript("OnValueChanged", function(self, v)
          -- Snap to step boundary.
          if opts.step and opts.step > 0 then
              v = math.floor(v / opts.step + 0.5) * opts.step
          end
          opts.set(v)
          updateVal(v)
      end)

      s._label  = lbl
      s._valLbl = valLbl
      s._opts   = opts
      return s
  end

  local function MakeButton(parent, text, onClick, opts)
      local T = ns.Theme
      opts = opts or {}
      local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
      btn:SetText(text)
      btn:SetWidth(opts.width or 160)
      btn:SetHeight(opts.height or 22)
      btn:SetPoint("TOPLEFT", parent, "TOPLEFT", opts.x or 0, opts.y or 0)
      btn:SetScript("OnClick", onClick)
      if opts.danger then
          btn:GetNormalTexture():SetVertexColor(
              T.danger[1], T.danger[2], T.danger[3])
      end
      return btn
  end

  -- ── Tab switching ─────────────────────────────────────────────────────

  local function SwitchTab(name)
      if not tabs[name] then return end
      activeTab = name
      if addon then addon.db.profile.lastTab = name end

      local T = ns.Theme
      for _, n in ipairs(TAB_NAMES) do
          local tb = tabs[n]
          local body = tabBodies[n]
          if n == name then
              tb:SetBackdropColor(T.bgTabActive[1], T.bgTabActive[2],
                  T.bgTabActive[3], T.bgTabActive[4])
              tb._text:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
              if tb._underline then tb._underline:Show() end
              if body then body:Show() end
          else
              tb:SetBackdropColor(T.bgBase[1], T.bgBase[2],
                  T.bgBase[3], 0)
              tb._text:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
              if tb._underline then tb._underline:Hide() end
              if body then body:Hide() end
          end
      end

      -- Trigger OnShow for the active body (for leader re-check, etc.)
      local activeBody = tabBodies[name]
      if activeBody and activeBody:GetScript("OnShow") then
          activeBody:GetScript("OnShow")(activeBody)
      end
  end

  -- ── Frame construction (lazy) ─────────────────────────────────────────

  local function BuildFrames()
      if built then return end
      built = true

      local T = ns.Theme

      -- ── Outer frame ──────────────────────────────────────────────────
      frame = CreateFrame("Frame", "BobleLootSettingsFrame", UIParent, "BackdropTemplate")
      frame:SetSize(PANEL_W, PANEL_H)
      frame:SetFrameStrata("HIGH")
      frame:SetClampedToScreen(true)
      frame:SetMovable(true)
      frame:EnableMouse(true)
      frame:Hide()

      T.ApplyBackdrop(frame, "bgBase", "borderNormal")

      -- Restore saved position or default to CENTER.
      local pos = addon and addon.db.profile.panelPos
      if pos and pos.point then
          frame:SetPoint(pos.point, UIParent, pos.point, pos.x or 0, pos.y or 0)
      else
          frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
      end

      -- Save position on stop-moving.
      frame:SetScript("OnMouseDown", function(self, btn)
          if btn == "LeftButton" then self:StartMoving() end
      end)
      frame:SetScript("OnMouseUp", function(self)
          self:StopMovingOrSizing()
          -- Persist position.
          if addon then
              local point, _, _, x, y = self:GetPoint()
              addon.db.profile.panelPos = { point = point, x = x, y = y }
          end
      end)

      -- Close on Escape.
      frame:SetScript("OnKeyDown", function(self, key)
          if key == "ESCAPE" then self:Hide() end
      end)
      frame:SetPropagateKeyboardInput(true)

      -- ── Title bar ────────────────────────────────────────────────────
      local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
      titleBar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0,  0)
      titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0,  0)
      titleBar:SetHeight(TITLEBAR_H)
      T.ApplyBackdrop(titleBar, "bgTitleBar", "borderAccent")
      titleBar:EnableMouse(true)
      titleBar:SetScript("OnMouseDown", function(_, btn)
          if btn == "LeftButton" then frame:StartMoving() end
      end)
      titleBar:SetScript("OnMouseUp", function()
          frame:StopMovingOrSizing()
          if addon then
              local point, _, _, x, y = frame:GetPoint()
              addon.db.profile.panelPos = { point = point, x = x, y = y }
          end
      end)

      -- Cyan underline on title bar.
      local titleLine = titleBar:CreateTexture(nil, "OVERLAY")
      titleLine:SetPoint("BOTTOMLEFT",  titleBar, "BOTTOMLEFT",  0, 0)
      titleLine:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
      titleLine:SetHeight(2)
      titleLine:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], T.accent[4])

      local titleText = titleBar:CreateFontString(nil, "OVERLAY")
      titleText:SetFont(T.fontTitle, T.sizeTitle, "OUTLINE")
      titleText:SetTextColor(T.white[1], T.white[2], T.white[3])
      titleText:SetPoint("LEFT", titleBar, "LEFT", 10, 0)
      titleText:SetText("Boble Loot \226\128\148 Settings")  -- em-dash

      -- Close button (X).
      local closeBtn = CreateFrame("Button", nil, titleBar)
      closeBtn:SetSize(TITLEBAR_H, TITLEBAR_H)
      closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -2, 0)
      local closeTxt = closeBtn:CreateFontString(nil, "OVERLAY")
      closeTxt:SetFont(T.fontTitle, T.sizeTitle + 2, "OUTLINE")
      closeTxt:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
      closeTxt:SetAllPoints()
      closeTxt:SetText("x")
      closeBtn:SetScript("OnEnter", function()
          closeTxt:SetTextColor(T.danger[1], T.danger[2], T.danger[3])
      end)
      closeBtn:SetScript("OnLeave", function()
          closeTxt:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
      end)
      closeBtn:SetScript("OnClick", function() frame:Hide() end)

      -- ── Tab bar ──────────────────────────────────────────────────────
      local tabBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
      tabBar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0, -TITLEBAR_H)
      tabBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -TITLEBAR_H)
      tabBar:SetHeight(TABBAR_H)
      T.ApplyBackdrop(tabBar, "bgBase", "borderNormal")

      local tabW = PANEL_W / #TAB_NAMES  -- equal width tabs

      for i, name in ipairs(TAB_NAMES) do
          local tb = CreateFrame("Frame", nil, tabBar, "BackdropTemplate")
          tb:SetSize(tabW, TABBAR_H)
          tb:SetPoint("TOPLEFT", tabBar, "TOPLEFT", (i - 1) * tabW, 0)
          T.ApplyBackdrop(tb, "bgBase", "borderNormal")
          tb:EnableMouse(true)

          local txt = tb:CreateFontString(nil, "OVERLAY")
          txt:SetFont(T.fontBody, T.sizeBody, "OUTLINE")
          txt:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
          txt:SetAllPoints()
          txt:SetJustifyH("CENTER")
          txt:SetText(TAB_LABELS[name])
          tb._text = txt

          -- 2px cyan bottom border (active tab indicator).
          local underline = tb:CreateTexture(nil, "OVERLAY")
          underline:SetPoint("BOTTOMLEFT",  tb, "BOTTOMLEFT",  2, 0)
          underline:SetPoint("BOTTOMRIGHT", tb, "BOTTOMRIGHT", -2, 0)
          underline:SetHeight(2)
          underline:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], T.accent[4])
          underline:Hide()
          tb._underline = underline

          -- Hover tint.
          tb:SetScript("OnEnter", function()
              if activeTab ~= name then
                  txt:SetTextColor(T.white[1], T.white[2], T.white[3])
              end
          end)
          tb:SetScript("OnLeave", function()
              if activeTab ~= name then
                  txt:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
              end
          end)
          tb:SetScript("OnMouseDown", function(_, btn)
              if btn == "LeftButton" then SwitchTab(name) end
          end)

          tabs[name] = tb
      end

      -- ── Body scroll frame ────────────────────────────────────────────
      local bodyOffset = TITLEBAR_H + TABBAR_H

      local scrollFrame = CreateFrame("ScrollFrame", nil, frame,
          "UIPanelScrollFrameTemplate")
      scrollFrame:SetPoint("TOPLEFT",     frame, "TOPLEFT",     4, -(bodyOffset + 4))
      scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -22, 4)

      -- One content child per tab, all parented to the scrollFrame's child.
      local scrollChild = CreateFrame("Frame")
      scrollChild:SetSize(PANEL_W - 26, BODY_H)
      scrollFrame:SetScrollChild(scrollChild)

      -- Build all five tab bodies now (lazy per-tab build is added here
      -- if complexity grows in the future; for now all tabs build on first
      -- panel open to keep SwitchTab simple).
      BuildWeightsTab(scrollChild)
      BuildTuningTab(scrollChild)
      BuildLootDBTab(scrollChild)
      BuildDataTab(scrollChild)
      BuildTestTab(scrollChild)

      -- Start on the last-used tab (or "weights" default).
      local startTab = (addon and addon.db.profile.lastTab) or "weights"
      if not tabs[startTab] then startTab = "weights" end
      SwitchTab(startTab)
  end

  -- ── Public API ────────────────────────────────────────────────────────

  function SP:Setup(addonArg)
      addon = addonArg
      -- Do NOT build frames here. Lazy build on first Open/Toggle.

      -- Register Blizzard Settings API proxy (Task 12 fills this in fully;
      -- placeholder keeps Setup callable before that task lands).
  end

  function SP:Toggle()
      if not built then BuildFrames() end
      if frame:IsShown() then
          frame:Hide()
      else
          frame:Show()
      end
  end

  function SP:Open()
      if not built then BuildFrames() end
      frame:Show()
      frame:Raise()
      local tab = (addon and addon.db.profile.lastTab) or "weights"
      if not tabs[tab] then tab = "weights" end
      SwitchTab(tab)
  end

  function SP:OpenTab(name)
      if not built then BuildFrames() end
      frame:Show()
      frame:Raise()
      SwitchTab(name)
  end

  function SP:Refresh()
      if not built or not frame:IsShown() then return end
      -- Each tab body's OnShow handler re-reads db.profile.
      -- Trigger the active tab's handler to update all controls.
      if activeTab and tabBodies[activeTab] then
          local body = tabBodies[activeTab]
          if body:GetScript("OnShow") then
              body:GetScript("OnShow")(body)
          end
      end
  end

  -- ── Tab builder stubs (replaced by Tasks 7-11) ────────────────────────
  -- These stubs register empty tabBodies so SwitchTab doesn't error
  -- before each task's BuildXxxTab implementation lands.

  function BuildWeightsTab(parent)
      local body = CreateFrame("Frame", nil, parent)
      body:SetAllPoints(parent)
      body:Hide()
      tabBodies["weights"] = body
  end

  function BuildTuningTab(parent)
      local body = CreateFrame("Frame", nil, parent)
      body:SetAllPoints(parent)
      body:Hide()
      tabBodies["tuning"] = body
  end

  function BuildLootDBTab(parent)
      local body = CreateFrame("Frame", nil, parent)
      body:SetAllPoints(parent)
      body:Hide()
      tabBodies["lootdb"] = body
  end

  function BuildDataTab(parent)
      local body = CreateFrame("Frame", nil, parent)
      body:SetAllPoints(parent)
      body:Hide()
      tabBodies["data"] = body
  end

  function BuildTestTab(parent)
      local body = CreateFrame("Frame", nil, parent)
      body:SetAllPoints(parent)
      body:Hide()
      tabBodies["test"] = body
  end
  ```

- [ ] Commit:
  ```
  git add UI/SettingsPanel.lua
  git commit -m "Add UI/SettingsPanel.lua shell: frame, title bar, tab bar, scroll body, public API"
  ```

**In-game verification:**
- `/reload`
- Left-click the minimap icon → the 560×420 panel appears with title bar,
  five tabs, and empty body (stubs in place).
- Drag the panel by the title bar → it moves and stays clamped to screen.
- Close it with the X button → hidden.
- `/reload`, left-click again → panel reopens at the position from before
  the reload (position persisted via `panelPos`).
- Click each tab → active tab shows cyan label and underline; inactive tabs
  show muted label.
- `/bl config` → panel opens (wired in Task 13; not yet, but note for
  later cross-check).

---

### Task 7 — Implement `BuildWeightsTab`

**Files:**
- Modify `UI/SettingsPanel.lua` — replace the `BuildWeightsTab` stub

**Context:** Five component rows (sim, bis, history, attendance, mplus).
Each row has a 110px label, enable-toggle, slider (0-100%, isPercent),
and a right-aligned percent readout. Moving any slider calls
`normalizeWeights()` (lifted verbatim from `Config.lua`) then refreshes
every other slider's display so live renormalization is visible.
A small "example row" at the bottom shows a fixed hypothetical character
with the current weights applied, updating as sliders move.

- [ ] Replace the `BuildWeightsTab(parent)` stub function in `SettingsPanel.lua`
  with the full implementation below. The `normalizeWeights` and `countEnabled`
  helpers are defined as locals at the top of the function scope so they
  do not pollute the module level.

  ```lua
  function BuildWeightsTab(parent)
      local T = ns.Theme

      -- ── Re-export normalizeWeights from Config.lua logic ──────────────
      local WEIGHT_KEYS = { "sim", "bis", "history", "attendance", "mplus" }

      local function countEnabled(enabled)
          local n = 0
          for _, k in ipairs(WEIGHT_KEYS) do
              if enabled[k] then n = n + 1 end
          end
          return n
      end

      local function normalizeWeights(weights, enabled)
          for _, k in ipairs(WEIGHT_KEYS) do
              if not enabled[k] then weights[k] = 0 end
          end
          local sum = 0
          for _, k in ipairs(WEIGHT_KEYS) do sum = sum + (weights[k] or 0) end
          local n = countEnabled(enabled)
          if sum <= 0 then
              if n == 0 then return end
              for _, k in ipairs(WEIGHT_KEYS) do
                  weights[k] = enabled[k] and (1 / n) or 0
              end
              return
          end
          for _, k in ipairs(WEIGHT_KEYS) do
              weights[k] = enabled[k] and (weights[k] / sum) or 0
          end
      end

      -- ── Body frame ────────────────────────────────────────────────────
      local body = CreateFrame("Frame", nil, parent)
      body:SetAllPoints(parent)
      body:Hide()
      tabBodies["weights"] = body

      -- Section card.
      local card, inner = MakeSection(body,
          "Weights  (toggle on/off; sliders auto-normalize to 100%)")
      card:SetPoint("TOPLEFT",     body, "TOPLEFT",  6, -6)
      card:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6, 80)

      -- Component definitions: key, display label.
      local COMPONENTS = {
          { key = "sim",        label = "WoWAudit sim upgrade" },
          { key = "bis",        label = "BiS list" },
          { key = "history",    label = "Recent items received" },
          { key = "attendance", label = "Raid attendance" },
          { key = "mplus",      label = "Mythic+ dungeons (season)" },
      }

      -- References for cross-slider refresh.
      local sliders   = {}  -- keyed by component key
      local valLabels = {}  -- keyed by component key

      local ROW_H   = 28
      local COL_LBL = 0    -- label starts here
      local COL_TOG = 112  -- toggle
      local COL_SLD = 138  -- slider
      local SLD_W   = 270

      for i, comp in ipairs(COMPONENTS) do
          local yOff = -(i - 1) * ROW_H - 4

          -- Row label.
          local lbl = inner:CreateFontString(nil, "OVERLAY")
          lbl:SetFont(T.fontBody, T.sizeBody)
          lbl:SetTextColor(T.white[1], T.white[2], T.white[3])
          lbl:SetPoint("TOPLEFT", inner, "TOPLEFT", COL_LBL, yOff)
          lbl:SetWidth(110)
          lbl:SetText(comp.label)

          -- Enable toggle.
          local tog = MakeToggle(inner, {
              label = "",
              x = COL_TOG, y = yOff,
              get = function()
                  return addon and addon.db.profile.weightsEnabled[comp.key]
              end,
              set = function(v)
                  if not addon then return end
                  local p = addon.db.profile
                  p.weightsEnabled[comp.key] = v
                  if v then
                      -- Give the newly-enabled key an equal share before renorm.
                      local n = countEnabled(p.weightsEnabled)
                      p.weights[comp.key] = (n > 0) and (1 / n) or 1
                  end
                  normalizeWeights(p.weights, p.weightsEnabled)
                  -- Refresh all sliders so renorm is visible.
                  for _, k in ipairs(WEIGHT_KEYS) do
                      if sliders[k] then
                          local enabled = p.weightsEnabled[k]
                          sliders[k]:SetEnabled(enabled)
                          sliders[k]:SetValue(p.weights[k] or 0)
                          if valLabels[k] then
                              valLabels[k]:SetText(string.format(
                                  "%.0f%%", (p.weights[k] or 0) * 100))
                          end
                      end
                  end
              end,
          })

          -- Weight slider.
          local sld = MakeSlider(inner, {
              label = "",
              min = 0, max = 1, step = 0.01, isPercent = true,
              width = SLD_W,
              x = COL_SLD, y = yOff - 8,
              get = function()
                  return (addon and addon.db.profile.weights[comp.key]) or 0
              end,
              set = function(v)
                  if not addon then return end
                  local p = addon.db.profile
                  p.weights[comp.key] = v
                  normalizeWeights(p.weights, p.weightsEnabled)
                  -- Refresh sibling sliders.
                  for _, k in ipairs(WEIGHT_KEYS) do
                      if sliders[k] and k ~= comp.key then
                          sliders[k]:SetValue(p.weights[k] or 0)
                          if valLabels[k] then
                              valLabels[k]:SetText(string.format(
                                  "%.0f%%", (p.weights[k] or 0) * 100))
                          end
                      end
                  end
              end,
          })

          sliders[comp.key]   = sld
          valLabels[comp.key] = sld._valLbl

          -- Dim slider when component is disabled.
          local isEnabled = addon and addon.db.profile.weightsEnabled[comp.key]
          sld:SetEnabled(isEnabled ~= false)
      end

      -- ── Example score row ─────────────────────────────────────────────
      -- A synthetic character with fixed raw inputs so the user can see how
      -- weights shape a score as sliders move. Updates on every slider change
      -- via the OnShow refresh path.

      local exCard, exInner = MakeSection(body,
          "Example score (how current weights shape a result)")
      exCard:SetPoint("TOPLEFT",     body, "BOTTOMLEFT",  6,  74)
      exCard:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6,  6)

      -- Fixed raw component values for the example character.
      -- Values are 0-1 normalized inputs (same scale Scoring.lua uses).
      local EXAMPLE_RAW = {
          sim        = 0.72,
          bis        = 1.00,
          history    = 0.50,
          attendance = 0.80,
          mplus      = 0.60,
      }

      local exScoreLbl = exInner:CreateFontString(nil, "OVERLAY")
      exScoreLbl:SetFont(T.fontTitle, T.sizeTitle, "OUTLINE")
      exScoreLbl:SetPoint("TOPLEFT", exInner, "TOPLEFT", 4, -2)

      local exDetailLbl = exInner:CreateFontString(nil, "OVERLAY")
      exDetailLbl:SetFont(T.fontBody, T.sizeSmall)
      exDetailLbl:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
      exDetailLbl:SetPoint("TOPLEFT", exScoreLbl, "BOTTOMLEFT", 0, -2)
      exDetailLbl:SetWidth(500)

      local function refreshExampleRow()
          if not addon then return end
          local p = addon.db.profile
          local score = 0
          local parts = {}
          for _, k in ipairs(WEIGHT_KEYS) do
              local w = p.weights[k] or 0
              local r = EXAMPLE_RAW[k] or 0
              local contrib = w * r * 100
              score = score + contrib
              if w > 0 then
                  parts[#parts + 1] = string.format("%s=%.1f", k, contrib)
              end
          end
          local col = ns.Theme.ScoreColor(score)
          exScoreLbl:SetTextColor(col[1], col[2], col[3])
          exScoreLbl:SetText(string.format("%.0f", score))
          exDetailLbl:SetText(
              "(synthetic inputs: sim=72%%, bis=100%%, hist=50%%, att=80%%, m+=60%%)  "
              .. table.concat(parts, "  "))
      end

      -- Refresh on tab show.
      body:SetScript("OnShow", function()
          if not addon then return end
          local p = addon.db.profile
          for _, k in ipairs(WEIGHT_KEYS) do
              if sliders[k] then
                  local enabled = p.weightsEnabled[k]
                  sliders[k]:SetEnabled(enabled ~= false)
                  sliders[k]:SetValue(p.weights[k] or 0)
                  if valLabels[k] then
                      valLabels[k]:SetText(string.format(
                          "%.0f%%", (p.weights[k] or 0) * 100))
                  end
              end
          end
          refreshExampleRow()
      end)
  end
  ```

- [ ] Commit:
  ```
  git add UI/SettingsPanel.lua
  git commit -m "Implement BuildWeightsTab: five component rows with live renormalization and example score row"
  ```

**In-game verification:**
- `/reload`, open panel, click "Weights" tab.
- Uncheck "BiS list" toggle → BiS slider dims; all other sliders redistribute
  to fill 100% among enabled components.
- Move the "Sim upgrade" slider → all other enabled sliders adjust live.
- The example score row at the bottom updates as sliders move; score color
  changes from green/amber/red based on the computed value.
- `/reload`, reopen → slider values match what was set (AceDB persisted).

---

### Task 8 — Implement `BuildTuningTab`

**Files:**
- Modify `UI/SettingsPanel.lua` — replace the `BuildTuningTab` stub

- [ ] Replace the `BuildTuningTab(parent)` stub with:

  ```lua
  function BuildTuningTab(parent)
      local T = ns.Theme

      local body = CreateFrame("Frame", nil, parent)
      body:SetAllPoints(parent)
      body:Hide()
      tabBodies["tuning"] = body

      local card, inner = MakeSection(body, "Scoring tuning")
      card:SetPoint("TOPLEFT",     body, "TOPLEFT",  6, -6)
      card:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6, 6)

      -- Track control references for conditional show/hide.
      local simCapSld, mplusCapSld, histCapSld

      -- Partial-BiS slider.
      MakeSlider(inner, {
          label = "BiS partial credit (non-BiS items)",
          min = 0, max = 1, step = 0.05, isPercent = true,
          width = 280, x = 4, y = -4,
          get = function() return (addon and addon.db.profile.partialBiSValue) or 0.25 end,
          set = function(v)
              if addon then addon.db.profile.partialBiSValue = v end
          end,
      })

      -- Override caps toggle.
      local overrideTog = MakeToggle(inner, {
          label = "Override caps from data file",
          x = 4, y = -52,
          get = function() return (addon and addon.db.profile.overrideCaps) or false end,
          set = function(v)
              if addon then addon.db.profile.overrideCaps = v end
              -- Dim or enable the three cap sliders.
              if simCapSld  then simCapSld:SetEnabled(v)  end
              if mplusCapSld then mplusCapSld:SetEnabled(v) end
              if histCapSld  then histCapSld:SetEnabled(v)  end
          end,
      })

      -- Sim cap slider.
      simCapSld = MakeSlider(inner, {
          label = "Sim upgrade cap (% -> 100)",
          min = 0.5, max = 20, step = 0.5, isPercent = false,
          width = 280, x = 4, y = -82,
          get = function() return (addon and addon.db.profile.simCap) or 5.0 end,
          set = function(v)
              if addon then addon.db.profile.simCap = v end
          end,
      })

      -- M+ cap slider.
      mplusCapSld = MakeSlider(inner, {
          label = "M+ dungeons cap (count -> 100)",
          min = 5, max = 200, step = 1, isPercent = false,
          width = 280, x = 4, y = -128,
          get = function() return (addon and addon.db.profile.mplusCap) or 40 end,
          set = function(v)
              if addon then addon.db.profile.mplusCap = v end
          end,
      })

      -- History soft-floor slider.
      histCapSld = MakeSlider(inner, {
          label = "Loot equity soft floor",
          min = 1, max = 20, step = 1, isPercent = false,
          width = 280, x = 4, y = -174,
          get = function() return (addon and addon.db.profile.historyCap) or 5 end,
          set = function(v)
              if addon then addon.db.profile.historyCap = v end
          end,
      })

      -- Loot history window slider.
      MakeSlider(inner, {
          label = "Loot history window (days, 0 = all time)",
          min = 0, max = 180, step = 1, isPercent = false,
          width = 280, x = 4, y = -220,
          get = function() return (addon and addon.db.profile.lootHistoryDays) or 28 end,
          set = function(v)
              if addon then
                  addon.db.profile.lootHistoryDays = v
                  -- Mirror Config.lua behavior: re-run loot history on change.
                  if ns.LootHistory and ns.LootHistory.Apply then
                      ns.LootHistory:Apply(addon)
                  end
              end
          end,
      })

      -- Refresh state on tab show.
      body:SetScript("OnShow", function()
          if not addon then return end
          local oc = addon.db.profile.overrideCaps
          if simCapSld  then simCapSld:SetEnabled(oc)  end
          if mplusCapSld then mplusCapSld:SetEnabled(oc) end
          if histCapSld  then histCapSld:SetEnabled(oc)  end
      end)
  end
  ```

- [ ] Commit:
  ```
  git add UI/SettingsPanel.lua
  git commit -m "Implement BuildTuningTab: BiS partial credit, override caps, sim/M+/history sliders"
  ```

**In-game verification:**
- Open panel → "Tuning" tab.
- All five sliders present. Sim cap, M+ cap, soft floor are greyed out
  when "Override caps" is unchecked.
- Check "Override caps" → three sliders become active.
- Move "Loot history window" slider → observe chat message from LootHistory
  re-apply (it prints matched/scanned counts).
- `/reload`, reopen Tuning → values persisted.

---

### Task 9 — Implement `BuildLootDBTab`

**Files:**
- Modify `UI/SettingsPanel.lua` — replace the `BuildLootDBTab` stub

- [ ] Replace the `BuildLootDBTab(parent)` stub with:

  ```lua
  function BuildLootDBTab(parent)
      local T = ns.Theme

      local body = CreateFrame("Frame", nil, parent)
      body:SetAllPoints(parent)
      body:Hide()
      tabBodies["lootdb"] = body

      local card, inner = MakeSection(body,
          "Loot category weights (for 'items received')")
      card:SetPoint("TOPLEFT",     body, "TOPLEFT",  6, -6)
      card:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6, 110)

      -- Category sliders.
      local CAT_ROWS = {
          { key = "bis",      label = "BiS",                         y = -4   },
          { key = "major",    label = "Major upgrade",               y = -50  },
          { key = "mainspec", label = "Mainspec / Need",             y = -96  },
          { key = "minor",    label = "Minor upgrade",               y = -142 },
      }

      for _, row in ipairs(CAT_ROWS) do
          MakeSlider(inner, {
              label = row.label,
              min = 0, max = 5, step = 0.1, isPercent = false,
              width = 280, x = 4, y = row.y,
              get = function()
                  return (addon and addon.db.profile.lootWeights[row.key]) or 1.0
              end,
              set = function(v)
                  if not addon then return end
                  addon.db.profile.lootWeights[row.key] = v
                  if ns.LootHistory and ns.LootHistory.Apply then
                      ns.LootHistory:Apply(addon)
                  end
              end,
          })
      end

      -- Min ilvl slider.
      MakeSlider(inner, {
          label = "Minimum item level (0 = all tracks)",
          min = 0, max = 800, step = 5, isPercent = false,
          width = 280, x = 4, y = -188,
          get = function() return (addon and addon.db.profile.lootMinIlvl) or 0 end,
          set = function(v)
              if not addon then return end
              addon.db.profile.lootMinIlvl = v
              if ns.LootHistory and ns.LootHistory.Apply then
                  ns.LootHistory:Apply(addon)
              end
          end,
      })

      -- Status line.
      local statusCard, statusInner = MakeSection(body, "Loot history status")
      statusCard:SetPoint("TOPLEFT",     body, "BOTTOMLEFT",  6, 104)
      statusCard:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6, 6)

      local statusLbl = statusInner:CreateFontString(nil, "OVERLAY")
      statusLbl:SetFont(T.fontBody, T.sizeBody)
      statusLbl:SetTextColor(T.white[1], T.white[2], T.white[3])
      statusLbl:SetPoint("TOPLEFT", statusInner, "TOPLEFT", 4, -2)
      statusLbl:SetWidth(380)

      local refreshBtn = MakeButton(statusInner, "Refresh now",
          function()
              if ns.LootHistory and ns.LootHistory.Apply then
                  ns.LootHistory:Apply(addon)
                  -- Update the status line immediately.
                  local lh = ns.LootHistory
                  statusLbl:SetText(string.format(
                      "Last scan: %d/%d matched  (source: %s)",
                      lh.lastMatched or 0,
                      lh.lastScanned or 0,
                      lh.lastSource  or "?"))
              end
          end, { width = 120, height = 20, x = 390, y = -2 })

      local function updateStatus()
          local lh = ns.LootHistory
          if lh and lh.lastMatched then
              statusLbl:SetText(string.format(
                  "Last scan: %d/%d matched  (source: %s)",
                  lh.lastMatched or 0,
                  lh.lastScanned or 0,
                  lh.lastSource  or "?"))
          else
              statusLbl:SetText("|cffaaaaaaLoot history not yet applied.|r")
          end
      end

      body:SetScript("OnShow", function()
          updateStatus()
      end)
  end
  ```

- [ ] Commit:
  ```
  git add UI/SettingsPanel.lua
  git commit -m "Implement BuildLootDBTab: category/ilvl sliders, status line, Refresh Now button"
  ```

**In-game verification:**
- Open panel → "Loot DB" tab.
- Four category sliders (BiS=1.5, Major=1.0, Mainspec=1.0, Minor=0.5 defaults)
  and one min-ilvl slider (0 default).
- Status line shows current matched/scanned from `LootHistory`.
- Click "Refresh now" → status line updates with fresh counts.
- Move any category slider → LootHistory re-applies immediately (if in-game
  RC DB present, matched count may change).
- `/reload`, reopen → values persisted.

---

### Task 10 — Implement `BuildDataTab`

**Files:**
- Modify `UI/SettingsPanel.lua` — replace the `BuildDataTab` stub

- [ ] Replace the `BuildDataTab(parent)` stub with:

  ```lua
  function BuildDataTab(parent)
      local T = ns.Theme
      local POPUP_TEAM_URL = "BOBLELOOT_SETTINGS_TEAM_URL"

      local body = CreateFrame("Frame", nil, parent)
      body:SetAllPoints(parent)
      body:Hide()
      tabBodies["data"] = body

      -- ── Dataset info card ─────────────────────────────────────────────
      local infoCard, infoInner = MakeSection(body, "Dataset info")
      infoCard:SetPoint("TOPLEFT",     body, "TOPLEFT",  6, -6)
      infoCard:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6, 240)

      local infoLbl = infoInner:CreateFontString(nil, "OVERLAY")
      infoLbl:SetFont(T.fontBody, T.sizeBody)
      infoLbl:SetTextColor(T.white[1], T.white[2], T.white[3])
      infoLbl:SetPoint("TOPLEFT", infoInner, "TOPLEFT", 4, -2)
      infoLbl:SetWidth(500)

      local function updateInfoLabel()
          local d = _G.BobleLoot_Data
          if not d then
              infoLbl:SetTextColor(T.danger[1], T.danger[2], T.danger[3])
              infoLbl:SetText("|cffff5555No dataset loaded.|r")
              return
          end
          infoLbl:SetTextColor(T.white[1], T.white[2], T.white[3])
          local count = 0
          for _ in pairs(d.characters or {}) do count = count + 1 end
          infoLbl:SetText(string.format(
              "Generated: %s\nCharacters loaded: %d\n"
              .. "Caps (data file):  M+ dungeons = %d  |  History soft floor = %d\n"
              .. "|cff888888(Sim is uncapped by design)|r",
              d.generatedAt or "?",
              count,
              d.mplusCap   or 0,
              d.historyCap or 0))
      end

      -- ── Actions card ──────────────────────────────────────────────────
      local actCard, actInner = MakeSection(body, "Actions")
      actCard:SetPoint("TOPLEFT",     body, "BOTTOMLEFT",  6,  234)
      actCard:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6, 130)

      -- Broadcast button.
      MakeButton(actInner, "Broadcast to raid",
          function()
              if ns.Sync and ns.Sync.BroadcastNow then
                  ns.Sync:BroadcastNow(addon)
                  addon:Print("announced dataset to raid.")
              end
          end, { width = 150, height = 22, x = 4, y = -4 })

      -- WoWAudit team page button (hidden if teamUrl absent).
      local teamBtn = MakeButton(actInner, "Open WoWAudit team page",
          function()
              -- StaticPopup with edit box for ctrl-C copy (mirrors RaidReminder pattern).
              if not StaticPopupDialogs[POPUP_TEAM_URL] then
                  StaticPopupDialogs[POPUP_TEAM_URL] = {
                      text         = "Open this URL in your browser (Ctrl+C to copy):",
                      button1      = OKAY,
                      hasEditBox   = true,
                      editBoxWidth = 340,
                      OnShow = function(self)
                          local data = _G.BobleLoot_Data
                          local url  = (data and data.teamUrl) or "https://wowaudit.com"
                          local eb = self.editBox or self.EditBox
                          if not eb then return end
                          eb:SetText(url)
                          eb:SetFocus()
                          eb:HighlightText()
                      end,
                      EditBoxOnEnterPressed  = function(self) self:GetParent():Hide() end,
                      EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
                      timeout      = 0,
                      whileDead    = true,
                      hideOnEscape = true,
                      preferredIndex = 3,
                  }
              end
              StaticPopup_Show(POPUP_TEAM_URL)
          end, { width = 190, height = 22, x = 162, y = -4 })
      teamBtn:Hide()  -- shown conditionally in OnShow

      -- ── Transparency card ─────────────────────────────────────────────
      local transCard, transInner = MakeSection(body, "Transparency mode")
      transCard:SetPoint("TOPLEFT",     body, "BOTTOMLEFT",  6, 124)
      transCard:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6, 6)

      local transTog -- toggled in OnShow

      local transHintLbl = transInner:CreateFontString(nil, "OVERLAY")
      transHintLbl:SetFont(T.fontBody, T.sizeSmall)
      transHintLbl:SetPoint("TOPLEFT", transInner, "TOPLEFT", 4, -28)
      transHintLbl:SetWidth(500)

      transTog = MakeToggle(transInner, {
          label = "Enabled (raid leader only)",
          x = 4, y = -4,
          get = function()
              return addon and addon:IsTransparencyEnabled() or false
          end,
          set = function(v)
              if not addon then return end
              if not UnitIsGroupLeader("player") then return end
              addon:SetTransparencyEnabled(v, true)
          end,
      })

      -- OnShow re-reads leader state (leadership can change while panel is open).
      body:SetScript("OnShow", function()
          updateInfoLabel()

          -- Show/hide team URL button.
          local d = _G.BobleLoot_Data
          if d and d.teamUrl then teamBtn:Show() else teamBtn:Hide() end

          -- Transparency toggle enable/hint.
          local isLeader = UnitIsGroupLeader("player")
          transTog:SetEnabled(isLeader)
          transTog:SetChecked(addon and addon:IsTransparencyEnabled() or false)
          if isLeader then
              transHintLbl:SetTextColor(T.accentDim[1], T.accentDim[2], T.accentDim[3])
              transHintLbl:SetText(
                  "You are the group leader. Toggling broadcasts the setting to all "
                  .. "raid members who have Boble Loot installed.")
          else
              transHintLbl:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
              transHintLbl:SetText(
                  "Only the raid/group leader can change this. Current state is synced "
                  .. "from the leader automatically.")
          end
      end)
  end
  ```

- [ ] Commit:
  ```
  git add UI/SettingsPanel.lua
  git commit -m "Implement BuildDataTab: dataset info, broadcast button, team URL popup, transparency toggle"
  ```

**In-game verification:**
- Open panel → "Data" tab.
- If `BobleLoot_Data` is loaded: info label shows `generatedAt`, character
  count, and caps. If not loaded: red "No dataset loaded." text.
- "Broadcast to raid" button — if in a raid, verify chat announcement.
- If `data.teamUrl` is set in the data file: "Open WoWAudit team page"
  button is visible and opens a StaticPopup with the URL selectable.
- Transparency toggle: if not leader it is greyed out with the muted hint.
  If leader it is active; toggling broadcasts and updates the tooltip.
- Reopen tab after changing leadership (testing via `/run PrintPartyLeader()`)
  — toggle enabled state refreshes correctly because `OnShow` re-reads
  `UnitIsGroupLeader("player")`.

---

### Task 11 — Implement `BuildTestTab`

**Files:**
- Modify `UI/SettingsPanel.lua` — replace the `BuildTestTab` stub

- [ ] Replace the `BuildTestTab(parent)` stub with:

  ```lua
  function BuildTestTab(parent)
      local T = ns.Theme

      local body = CreateFrame("Frame", nil, parent)
      body:SetAllPoints(parent)
      body:Hide()
      tabBodies["test"] = body

      local card, inner = MakeSection(body, "Test session")
      card:SetPoint("TOPLEFT",     body, "TOPLEFT",  6, -6)
      card:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6, 6)

      local descLbl = inner:CreateFontString(nil, "OVERLAY")
      descLbl:SetFont(T.fontBody, T.sizeSmall)
      descLbl:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
      descLbl:SetPoint("TOPLEFT", inner, "TOPLEFT", 4, -2)
      descLbl:SetWidth(500)
      descLbl:SetText(
          "Opens an RCLootCouncil test session so you can verify the Boble Loot score "
          .. "column live. Requires RCLootCouncil and group leader (or solo).")

      -- Item count slider.
      MakeSlider(inner, {
          label = "Number of items",
          min = 1, max = 20, step = 1, isPercent = false,
          width = 260, x = 4, y = -30,
          get = function() return (addon and addon.db.profile.testItemCount) or 5 end,
          set = function(v)
              if addon then addon.db.profile.testItemCount = math.floor(v) end
          end,
      })

      -- Use dataset items toggle.
      MakeToggle(inner, {
          label = "Use items from BobleLoot dataset (when available)",
          x = 4, y = -76,
          get = function()
              return (addon and addon.db.profile.testUseDatasetItems) ~= false
          end,
          set = function(v)
              if addon then addon.db.profile.testUseDatasetItems = v and true or false end
          end,
      })

      -- Reason label (shown when button is disabled).
      local reasonLbl = inner:CreateFontString(nil, "OVERLAY")
      reasonLbl:SetFont(T.fontBody, T.sizeSmall)
      reasonLbl:SetTextColor(T.warning[1], T.warning[2], T.warning[3])
      reasonLbl:SetPoint("TOPLEFT", inner, "TOPLEFT", 4, -108)
      reasonLbl:SetWidth(460)
      reasonLbl:SetText("")

      -- Run button.
      local runBtn = MakeButton(inner, "Run test session",
          function()
              if not (ns.TestRunner and ns.TestRunner.Run) then return end
              ns.TestRunner:Run(addon,
                  (addon.db.profile.testItemCount or 5),
                  (addon.db.profile.testUseDatasetItems ~= false))
          end, { width = 150, height = 24, x = 4, y = -120 })

      local function checkRunnable()
          -- Determine disable reason, if any.
          local RCAceAddon = LibStub and LibStub("AceAddon-3.0", true)
          local RC
          if RCAceAddon then
              local ok, r = pcall(function()
                  return RCAceAddon:GetAddon("RCLootCouncil", true)
              end)
              RC = ok and r or nil
          end

          local reason = nil
          if not RC then
              reason = "RCLootCouncil is not loaded. The test session requires RC."
          elseif IsInGroup() and not UnitIsGroupLeader("player") then
              reason = "You must be the group leader (or solo) to start a test session."
          end

          if reason then
              runBtn:SetEnabled(false)
              reasonLbl:SetText(reason)
          else
              runBtn:SetEnabled(true)
              reasonLbl:SetText("")
          end
      end

      body:SetScript("OnShow", function()
          checkRunnable()
      end)
  end
  ```

- [ ] Commit:
  ```
  git add UI/SettingsPanel.lua
  git commit -m "Implement BuildTestTab: item-count slider, dataset toggle, Run button with disable guard"
  ```

**In-game verification:**
- Open panel → "Test" tab.
- If RC not loaded (disable RCLootCouncil, `/reload`): "Run test session"
  button is grey; amber warning text explains RC is not loaded.
- If RC loaded but player is not leader: button disabled with leader reason.
- If RC loaded and leader (or solo): button enabled; clicking it starts a
  test session and the RC voting frame opens.
- Item count slider (1–20) and "Use dataset items" toggle both persist on
  `/reload`.

---

### Task 12 — Register Blizzard Settings API proxy

**Files:**
- Modify `UI/SettingsPanel.lua` — fill in the `SP:Setup` function's proxy
  registration block

**Context:** The proxy registers a category in Esc → Game Menu → Options →
AddOns → Boble Loot. When the user clicks the button there, it opens the
real custom panel. This preserves the three-path fallback originally in
`Config.lua:Open()`, adapted to open `ns.SettingsPanel` instead of an
AceConfig dialog.

- [ ] In `UI/SettingsPanel.lua`, find the `SP:Setup(addonArg)` function and
  replace the placeholder comment with the full proxy registration. The
  complete `SP:Setup` function should read:

  ```lua
  function SP:Setup(addonArg)
      addon = addonArg
      -- Do NOT build frames here. Lazy build on first Open/Toggle.

      -- ── Blizzard Settings API proxy ───────────────────────────────────
      -- Registers a minimal entry in Esc -> Options -> AddOns so users who
      -- navigate menus rather than clicking the minimap icon can reach the panel.
      -- Handles three API shapes present across retail patches.

      local categoryName = "Boble Loot"

      -- 10.x Settings API (preferred).
      if Settings and Settings.RegisterCanvasLayoutCategory then
          -- Create a proxy category with a single "Open Boble Loot" button.
          local proxyFrame = CreateFrame("Frame")
          proxyFrame.name = categoryName

          local openBtn = CreateFrame("Button", nil, proxyFrame,
              "UIPanelButtonTemplate")
          openBtn:SetText("Open Boble Loot settings")
          openBtn:SetWidth(200)
          openBtn:SetHeight(24)
          openBtn:SetPoint("TOPLEFT", proxyFrame, "TOPLEFT", 16, -16)
          openBtn:SetScript("OnClick", function()
              SP:Open()
              -- Close the Blizzard Options frame so it doesn't sit on top.
              if SettingsPanel and SettingsPanel:IsShown() then
                  HideUIPanel(SettingsPanel)
              end
          end)

          local category = Settings.RegisterCanvasLayoutCategory(
              proxyFrame, categoryName)
          Settings.RegisterAddOnCategory(category)
          self._blizzCategory = category

      elseif InterfaceOptions_AddCategory then
          -- Legacy pre-10.x path.
          local proxyFrame = CreateFrame("Frame")
          proxyFrame.name  = categoryName
          InterfaceOptions_AddCategory(proxyFrame)
          self._blizzProxyFrame = proxyFrame
      end
      -- If neither API is available the proxy simply doesn't register.
      -- The minimap button and /bl config slash command still work.
  end
  ```

- [ ] Also update the `SP:Open()` function to include the three-path fallback
  (preserving the `Config.lua:Open` pattern). Replace the existing `SP:Open`:

  ```lua
  function SP:Open()
      if not built then BuildFrames() end
      frame:Show()
      frame:Raise()
      local tab = (addon and addon.db.profile.lastTab) or "weights"
      if not tabs[tab] then tab = "weights" end
      SwitchTab(tab)
  end
  ```

  The frame-based open is sufficient; the Blizzard Settings API "Open"
  path only matters for the proxy button registered above. The three-path
  fallback from `Config.lua:Open` (`Settings.OpenToCategory` /
  `InterfaceOptionsFrame_OpenToCategory` / `AceConfigDialog:Open`) was
  needed to navigate to an AceConfig frame — our custom frame opens itself
  directly, so the three-path pattern lives only in the proxy registration
  above, not in `SP:Open()`. Keep `SP:Open()` as-is (it opens the frame
  directly and is the authoritative entry point).

- [ ] Commit:
  ```
  git add UI/SettingsPanel.lua
  git commit -m "Register Blizzard Settings API proxy in SettingsPanel:Setup for Esc > Options integration"
  ```

**In-game verification:**
- `/reload`
- Open Game Menu → Options → AddOns → "Boble Loot" (or navigate via
  Esc → Interface → AddOns list depending on patch version).
- "Open Boble Loot settings" button is present.
- Clicking it opens the custom panel and dismisses the Options frame.

---

### Task 13 — Update `Core.lua`: delete Config references, add SettingsPanel + MinimapButton

**Files:**
- Modify `Core.lua` — multiple targeted changes

**Context:** This is the wiring task. After it, `Config.lua`'s setup path
is removed, the new panel and minimap button are initialized, and the slash
command is updated. `Config.lua` itself is still on disk (deleted in Task 14)
but is no longer referenced anywhere in the load order after Task 3's TOC
update — this task completes the Core.lua side of the transition.

- [ ] In `Core.lua`, update the version constant:
  ```lua
  -- Old:
  BobleLoot.version = "1.0.2"
  -- New:
  BobleLoot.version = "1.1.0"
  ```

- [ ] In `DB_DEFAULTS.profile`, add the three new profile keys after the
  existing `historyCap` line:
  ```lua
  -- Add after:
  --   historyCap   = 5,
  minimap  = { hide = false, minimapPos = 220 },
  panelPos = { point = "CENTER", x = 0, y = 0 },
  lastTab  = "weights",
  ```

- [ ] In `BobleLoot:OnInitialize`, replace:
  ```lua
  if ns.Config and ns.Config.Setup then
      ns.Config:Setup(self)
  end
  ```
  with:
  ```lua
  if ns.SettingsPanel and ns.SettingsPanel.Setup then
      ns.SettingsPanel:Setup(self)
  end
  ```

- [ ] In `BobleLoot:OnEnable`, add the MinimapButton setup call after the
  LootHistory setup block (after `ns.LootHistory:Setup(self)`):
  ```lua
  if ns.MinimapButton and ns.MinimapButton.Setup then
      ns.MinimapButton:Setup(self)
  end
  ```

- [ ] In `BobleLoot:OnSlashCommand`, replace the `config`/`options` branch:
  ```lua
  -- Old:
  if input == "" or input == "config" or input == "options" then
      if ns.Config and ns.Config.Open then
          ns.Config:Open()
      else
          self:Print("Config module not loaded.")
      end
  ```
  with:
  ```lua
  if input == "" or input == "config" or input == "options" then
      if ns.SettingsPanel and ns.SettingsPanel.Open then
          ns.SettingsPanel:Open()
      else
          self:Print("Settings panel not loaded.")
      end
  ```

- [ ] In `BobleLoot:OnSlashCommand`, add the `/bl minimap` subcommand branch.
  Insert it after the `elseif input == "version" then` block and before
  the `elseif input == "broadcast"` block:
  ```lua
  elseif input == "minimap" then
      if ns.MinimapButton and ns.MinimapButton.ToggleMinimapIcon then
          ns.MinimapButton:ToggleMinimapIcon(self)
          local hidden = self.db.profile.minimap.hide
          self:Print("minimap icon " .. (hidden and "hidden." or "shown."))
      end
  ```

- [ ] Update the usage string at the bottom of `OnSlashCommand`:
  ```lua
  -- Old:
  self:Print("Commands: /bl config | /bl version | /bl broadcast | /bl transparency on|off | /bl checkdata | /bl lootdb | /bl debugchar <Name-Realm> | /bl test [N] | /bl score <itemID> <Name-Realm>")
  -- New:
  self:Print("Commands: /bl config | /bl minimap | /bl version | /bl broadcast | /bl transparency on|off | /bl checkdata | /bl lootdb | /bl debugchar <Name-Realm> | /bl test [N] | /bl score <itemID> <Name-Realm>")
  ```

- [ ] Commit:
  ```
  git add Core.lua
  git commit -m "Core.lua: wire SettingsPanel+MinimapButton, add profile defaults, add /bl minimap slash"
  ```

**In-game verification:**
- `/reload`
- `/bl config` → custom panel opens.
- `/bl` (empty) → custom panel opens.
- `/bl minimap` → minimap icon disappears, chat prints "minimap icon hidden."
- `/bl minimap` again → icon reappears, chat prints "minimap icon shown."
- `/dump BobleLoot.version` → `"1.1.0"`
- `/dump BobleLoot.db.profile.minimap` → table with `{ hide = false, minimapPos = 220 }`

---

### Task 14 — Delete `Config.lua` and `embeds.xml`

**Files:**
- Delete `Config.lua`
- Delete `embeds.xml`

**Context:** Both files are now completely unreferenced. `Config.lua` was
removed from the TOC in Task 3. `embeds.xml` was replaced by `Libs\Libs.xml`
in Task 3. Deleting them prevents future confusion and keeps the repo clean.

- [ ] Delete both files:
  ```bash
  git rm Config.lua
  git rm embeds.xml
  ```

- [ ] Commit:
  ```
  git commit -m "Delete Config.lua and embeds.xml: superseded by UI/SettingsPanel.lua and Libs/Libs.xml"
  ```

**In-game verification:**
- `/reload`
- Confirm no Lua errors referencing `Config.lua`.
- `/dump ns.Config` → `nil` (the module no longer exists).
- Panel still opens via `/bl config` and minimap icon still appears.

---

### Task 15 — Wire `Sync.lua:OnComm` SETTINGS branch to `SettingsPanel:Refresh`

**Files:**
- Modify `Sync.lua` — one additive call in the SETTINGS branch of `OnComm`

**Context:** When a leader broadcasts a SETTINGS message (e.g. toggling
transparency), non-leader raiders receive it and `SetTransparencyEnabled`
is called. Adding `SettingsPanel:Refresh()` ensures that if a raider has
the Data tab open, the transparency toggle control updates in real time
without needing to close and reopen the panel.

- [ ] In `Sync.lua`, find the SETTINGS branch inside `Sync:OnComm`. The
  current tail of that branch is:
  ```lua
  if prev ~= s.transparency then
      addon:Print(string.format("transparency mode %s by %s.",
          s.transparency and "ENABLED" or "DISABLED", sender))
      if ns.LootFrame and ns.LootFrame.Refresh then
          ns.LootFrame:Refresh()
      end
  end
  ```
  Add the SettingsPanel refresh call so it reads:
  ```lua
  if prev ~= s.transparency then
      addon:Print(string.format("transparency mode %s by %s.",
          s.transparency and "ENABLED" or "DISABLED", sender))
      if ns.LootFrame and ns.LootFrame.Refresh then
          ns.LootFrame:Refresh()
      end
      if ns.SettingsPanel and ns.SettingsPanel.Refresh then
          ns.SettingsPanel:Refresh()
      end
  end
  ```

- [ ] Commit:
  ```
  git add Sync.lua
  git commit -m "Sync.lua: call SettingsPanel:Refresh on SETTINGS message so Data tab updates live"
  ```

**In-game verification:**
- As a non-leader in a party, open the settings panel to the Data tab.
- Have the leader toggle transparency (via `/bl transparency on` or their
  own minimap menu).
- Confirm the transparency toggle in your Data tab updates without closing
  and reopening the panel.

---

### Task 16 — Verify profile schema in `DB_DEFAULTS`

**Files:**
- Review `Core.lua` `DB_DEFAULTS` (read-only verification step)

**Context:** Task 13 added the three new profile keys. This task is a
dedicated verification pass to confirm AceDB's default-merge works
correctly for existing 1.0.x installs upgrading to 1.1.0.

- [ ] Confirm `DB_DEFAULTS.profile` in `Core.lua` now contains:
  ```lua
  minimap  = { hide = false, minimapPos = 220 },
  panelPos = { point = "CENTER", x = 0, y = 0 },
  lastTab  = "weights",
  ```
  These keys sit alongside the existing `enabled`, `showColumn`, `weights`,
  etc. No migration script is needed — AceDB merges new keys from defaults
  on first load for any profile that doesn't already have them.

- [ ] Test upgrade path in-game:
  - If you have an existing `BobleLootDB` SavedVariable from 1.0.x, simply
    `/reload`. The new keys appear with their defaults.
  - `/dump BobleLoot.db.profile.minimap` → `{ hide = false, minimapPos = 220 }`
  - `/dump BobleLoot.db.profile.panelPos` → `{ point = "CENTER", x = 0, y = 0 }`
  - `/dump BobleLoot.db.profile.lastTab` → `"weights"`

- [ ] Confirm that if `BobleLootDB` is cleared (`/run BobleLootDB = nil`) and
  the game is reloaded, defaults are applied correctly:
  - `/run BobleLootDB = nil; ReloadUI()`
  - `/dump BobleLoot.db.profile` → all expected keys present.

- [ ] Commit: none (this is a verification-only task; if a correction is
  needed, commit it as a fix under Task 13's scope).

---

### Task 17 — Full manual verification pass

**Files:** None (in-game testing only)

Run all ten scenarios from the UI Overhaul spec. Any failure — stop,
fix the root cause, re-commit the fix, then restart verification from
scenario 1.

See the "Full manual-verification plan" section at the end of this document
for the complete scenario list.

- [ ] Scenario 1: Fresh load with RC.
- [ ] Scenario 2: RC-absent load.
- [ ] Scenario 3: All five tabs, all controls, persist check.
- [ ] Scenario 4: Weight renormalization.
- [ ] Scenario 5: Minimap tooltip accuracy.
- [ ] Scenario 6: Right-click quick actions.
- [ ] Scenario 7: Transparency propagation.
- [ ] Scenario 8: `/bl minimap` toggle.
- [ ] Scenario 9: Esc → Options proxy.
- [ ] Scenario 10: Panel drag / position persistence.

- [ ] Once all 10 scenarios pass, commit:
  ```
  git add -A
  git commit -m "All manual verification scenarios pass for v1.1.0 UI overhaul"
  ```

---

## Full manual-verification plan

Transcribed verbatim from
`docs/superpowers/specs/2026-04-22-ui-overhaul-design.md`, section
"Manual verification plan". No Lua test framework — verification is in-game.

### Scenario 1 — Fresh load with RC

Steps:
1. Ensure RCLootCouncil is enabled.
2. `/reload`
3. Enable error display: `/console scriptErrors 1`
4. Verify no red Lua error box appears.
5. Verify the minimap icon (dice) is visible.
6. `/bl config` → the custom 560×420 panel opens.
7. Verify the panel title reads "Boble Loot — Settings" and all five tabs
   are present.

Expected: clean load, icon, panel accessible.

### Scenario 2 — RC-absent load

Steps:
1. Disable RCLootCouncil in the addon list.
2. `/reload`
3. Verify no Lua errors.
4. Click the minimap icon → panel opens.
5. Navigate to the "Test" tab.
6. Verify the "Run test session" button is greyed out and shows a reason
   explaining RC is not loaded.
7. Re-enable RCLootCouncil before continuing.

Expected: addon loads cleanly; Test tab gracefully handles missing RC.

### Scenario 3 — All five tabs, all controls, persist check

Steps:
1. Open the panel. Visit each tab in turn.
2. On Weights tab: change two sliders and toggle one component off.
3. On Tuning tab: check "Override caps", move each slider.
4. On Loot DB tab: move BiS slider to 2.0, adjust min ilvl.
5. On Data tab: observe dataset info.
6. On Test tab: set count to 8.
7. `/reload`
8. Reopen the panel. Visit each tab and verify every changed value persisted.

Expected: AceDB profile correctly persists all control values.

### Scenario 4 — Weight renormalization

Steps:
1. Open panel → Weights tab.
2. Note current percentages (should sum to 100% across enabled components).
3. Uncheck "Attendance" toggle → remaining four percentages redistribute and
   still sum to 100%.
4. Move the "Sim upgrade" slider → all other enabled sliders adjust live.
5. The example score row at the bottom updates with each change.
6. Re-enable "Attendance" → five sliders rebalance.

Expected: displayed percentages always sum to 100% across enabled components;
example row updates in real time.

### Scenario 5 — Minimap tooltip accuracy

Steps:
1. Make sure a dataset is loaded (BobleLoot_Data present).
2. Hover the minimap icon.
3. Verify: title "Boble Loot" in cyan.
4. Verify: "Dataset version:" shows `generatedAt` from the data file.
5. Verify: "Characters loaded:" matches `#data.characters`.
6. Verify: "Loot history:" shows matched/scanned from `ns.LootHistory`.
7. Verify: transparency state matches `addon:IsTransparencyEnabled()`.
8. Verify: hint line at bottom is muted grey.

Expected: all tooltip fields reflect live in-game state.

### Scenario 6 — Right-click quick actions

Steps:
1. Right-click the minimap icon.
2. Click "Broadcast dataset" (if in a group) → confirm chat message.
3. Click "Refresh loot history" → confirm chat message with matched/scanned.
4. Hover "Run test session" → submenu shows 3/5/10 items entries.
5. Click "3 items" → RC test session opens (if leader or solo).
6. Right-click again; click "Open settings" → panel opens.
7. If leader: click "Transparency mode" → toggles; confirm state in panel
   Data tab and in `addon:IsTransparencyEnabled()`.

Expected: all menu items trigger their handlers without error.

### Scenario 7 — Transparency propagation

Steps:
1. In a party, as the leader.
2. Open the panel → Data tab. Note current transparency state.
3. Toggle transparency via the minimap right-click menu.
4. Confirm the Data tab's toggle updates in the open panel (no reopen needed).
5. `/bl transparency off` (slash command) → confirm panel Data tab updates.
6. `/bl transparency on` → confirm again.

Expected: transparency changes propagate to the open panel in real time,
and slash command still works independently.

### Scenario 8 — `/bl minimap` toggle

Steps:
1. Verify minimap icon is visible.
2. `/bl minimap` → icon disappears. Chat prints "minimap icon hidden."
3. Verify `BobleLoot.db.profile.minimap.hide` is `true`.
4. `/bl minimap` → icon reappears at the same angular position.
5. Verify `BobleLoot.db.profile.minimap.hide` is `false`.
6. `/reload` → icon remains visible (persisted hide = false).

Expected: toggle works bidirectionally; position is preserved by LibDBIcon.

### Scenario 9 — Esc → Options proxy

Steps:
1. Open Game Menu → Options (or press Escape).
2. Navigate to AddOns category → find "Boble Loot".
3. Click "Open Boble Loot settings".
4. Confirm the custom panel opens.
5. Confirm the Options frame closes (or is moved behind the panel).

Expected: Blizzard Settings proxy button opens the real panel on all
supported retail versions.

### Scenario 10 — Panel drag / position persistence

Steps:
1. Open the panel (centered by default on a fresh profile).
2. Drag it to the upper-left corner of the screen.
3. Close the panel (X button or Escape).
4. `/reload`
5. Open the panel again.
6. Verify it appears in the upper-left position from before the reload.

Expected: `BobleLootDB.profile.panelPos` is saved on mouse-up and restored
in `BuildFrames`.

---

## Release checklist — v1.1.0

- [ ] `BobleLoot.toc` `## Version:` is `1.1.0` (done in Task 3).
- [ ] `BobleLoot.version = "1.1.0"` in `Core.lua` (done in Task 13).
- [ ] All 17 tasks committed (verify with `git log --oneline`).
- [ ] All 10 manual verification scenarios pass (Task 17).
- [ ] README updated if any slash command changed:
  - New: `/bl minimap` — toggle minimap icon visibility.
  - Changed: `/bl config` now opens the custom panel (not AceConfig).
  - Update the commands table in README accordingly.
- [ ] Tag the release:
  ```bash
  git tag v1.1.0
  git push origin v1.1.0
  ```

---

## Dependencies and cross-plan notes

### Unblocks plan 1D (immediately after Task 2 commit)

`UI/Theme.lua` exposes `ns.Theme.ScoreColor` and `ns.Theme.accent`. Plan 1D's
tooltip hierarchy and score-gradient work reference these. Task 2 is committed
independently so 1D can start without waiting for the full panel.

### Unblocks future Batch 3 items

`Libs/LibDBIcon-1.0.lua` being bundled means future minimap-adjacent features
(item 3.11 loot history viewer launcher via right-click menu, item 3.12 toast
notification anchor) can be added as new entries in `MB:ShowDropdown()` without
library changes. The `tabBodies` map and `SwitchTab` function in SettingsPanel
accept new tab additions cleanly in Batch 3/4 if the tab list grows.

### Conservative choices made (ambiguities resolved)

1. **VoidstormGamba lib layout is flat** (no subdirectories). `Libs/Libs.xml`
   includes each file directly rather than using `<Include file="SubDir/SubDir.xml"/>`.
   This matches VSG's own layout exactly.

2. **`BackdropTemplate` on all frames.** Retail 12.0 (Interface 120005) is
   well past the 9.0 introduction of `BackdropTemplateMixin`. No compat shim
   is needed.

3. **EasyMenu for the right-click dropdown.** `EasyMenu` is the Blizzard-provided
   dropdown utility used by virtually all addon dropdowns in retail. It is
   available on 120005 and matches the VSG pattern. A UIDropDownMenuTemplate
   frame is created once and reused.

4. **`SettingsPanel:Refresh` is a no-op when the panel is not shown.** This
   prevents unnecessary work during sync events when the player has never
   opened the panel or has it closed.

5. **`SP:Setup` does not build frames.** All frame construction is deferred to
   the first `Open()`/`Toggle()` call. This keeps the `/reload` path fast for
   users who never open the panel during a session.
