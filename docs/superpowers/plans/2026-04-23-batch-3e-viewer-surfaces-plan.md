# Batch 3E — Viewer Surfaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver three independent player-facing surfaces — a standalone loot history viewer, a single-frame toast notification system, and a bench-mode score command — that together make BobleLoot's data visible, legible, and actionable beyond the voting frame.

**Architecture:** Each surface is a self-contained module with no circular references between them. `UI/HistoryViewer.lua` is the largest piece: it reads the same `RCLootCouncilLootDB` data `ns.LootHistory` already processes, reuses `LH:CountItemsReceived` for per-player totals, and renders them via lib-st when available or degrades to a paginated `FontString` list. `UI/Toast.lua` is a single 280×40 frame permanently anchored top-centre of the screen; it exposes one function (`Toast:Show(msg, level)`) and registers as an AceEvent listener for all status events from Sync, Batch 2C, and Batch 3C — multiple rapid events update the single frame's text in place rather than stacking. The bench-mode surface in `Core.lua` is a slash command that calls `ns.Scoring:ComputeAll(itemID)` (defined in Batch 3B) and prints results to officer or party chat.

**Tech Stack:** Lua (WoW 10.x), lib-st (optional, via `LibStub("ScrollingTable", true)` lazy lookup — degrades gracefully), AceEvent-3.0 for toast producers and consumers, `BackdropTemplate` for frame chrome, `ns.Theme` palette throughout.

**Roadmap items covered:** 3.11, 3.12, 3.13

> **3.11 `[UI]` Loot history viewer**
>
> Standalone scrolling table UI via `/bl history` and the minimap
> right-click menu. Columns: Player / Item / Date / Response / Weight
> Credit. Filters: player dropdown, date-range slider mirroring the
> existing `lootHistoryDays` config. Total row per player at the bottom
> showing the weighted sum — exactly the number driving the history
> score component. Follows the lib-st pattern RC uses natively.

> **3.12 `[UI]` Toast notification system**
>
> Replace chat prints for status events (sync complete, dataset stale,
> transparency toggled, protocol warning from 1.5, chunk progress
> from 2.8). Anchored frame 280×40px top-centre of screen. Fade in 0.2s,
> hold 3s, fade 0.5s. One toast queued; subsequent events update the
> visible toast's text in place. Success = green, warning = yellow,
> error = red. Never uses `UIErrorsFrame`.

> **3.13 `[UI]` Bench-mode UI surface**
>
> `/bl benchscore` prints a sorted score table for the current item to
> the officer chat channel. Consumes `ns.Scoring:ComputeAll` from 3.6.
> Addresses the "is it worth benching X for Y on this boss?" decision.

**Dependencies:**
- Batch 1 (`release/v1.1.0`): `ns.LootHistory` (Apply, CountItemsReceived, lastMatched, lastScanned), `ns.Theme` (palette, ApplyBackdrop, ScoreColor), `ns.Sync:GetRecentWarnings()`, `ns.Scoring` (COMPONENT_ORDER, COMPONENT_LABEL, Compute).
- Batch 2B (Migrations.lua, `BobleLootDB.profile.dbVersion`): provides the migration baseline for the new `historyViewerPos` profile key.
- Batch 2C (Chunked sync): fires `BobleLoot_SyncProgress` and `BobleLoot_SyncTimedOut` AceEvents consumed by Toast.
- Batch 3B (scoring data layer): provides `ns.Scoring:ComputeAll(itemID)` and `ns.Scoring.scoreHistory` consumed by bench-mode and optional trend display.
- Batch 3C (RC schema-drift): fires `BobleLoot_SchemaDriftWarning` AceEvent consumed by Toast; viewer surfaces 3C's drift banner.

---

## File Structure

```
BobleLoot/
├── BobleLoot.toc              -- add UI/Toast.lua and UI/HistoryViewer.lua entries
├── Core.lua                   -- /bl history slash, /bl benchscore slash,
│                              --   DB_DEFAULTS.profile.historyViewerPos addition,
│                              --   Toast:Setup wiring in OnEnable,
│                              --   /bl benchscore item-id argument parsing
├── Sync.lua                   -- add addon:SendMessage("BobleLoot_SyncWarning", ...)
│                              --   call inside _recordWarning (cross-plan contract)
└── UI/
    ├── Toast.lua              -- NEW: single-frame toast surface (3.12)
    ├── HistoryViewer.lua      -- NEW: scrolling history table (3.11)
    └── MinimapButton.lua      -- add "Loot history" item to EasyMenu dropdown
```

### Load order in `BobleLoot.toc`

```
UI\Theme.lua
UI\Toast.lua          -- must load before HistoryViewer and Core reference it
UI\HistoryViewer.lua
UI\SettingsPanel.lua
UI\MinimapButton.lua
```

`Toast.lua` loads before `HistoryViewer.lua` because the viewer may eventually call `Toast:Show` on filter errors, but more importantly both must exist before `Core:OnEnable` wires them. Neither file depends on the other at module-definition time; the load order is defensive.

### lib-st availability decision

`LibStub("ScrollingTable", true)` returns `nil` on a BobleLoot-only install because BobleLoot's own `Libs/` folder ships only LibStub, CallbackHandler, LibDataBroker-1.1, and LibDBIcon-1.0. RCLootCouncil bundles lib-st internally but does not expose it via the shared `LibStub` registry in all RC versions — field testing shows the library registers itself as `"ScrollingTable"` in the LibStub registry when RC loads (RC uses `LibStub:NewLibrary` for it in its own `Libs/LibScrollingTable/`), but this is an implementation detail of the RC version installed, not a guarantee.

**Decision:** Attempt `LibStub("ScrollingTable", true)` at module load time. If non-nil, use lib-st. If nil, use the paginated `FontString` fallback. The fallback is not embarrassing — it is a clean, themed table rendered with `CreateFontString` rows inside a `ScrollFrame`. Document the chosen path in a module-level comment updated at load time so in-game debugging is possible via `/bl history` error output. Do not bundle lib-st in BobleLoot's `Libs/`; adding a second copy of a library RC already ships creates version-skew risk.

---

## Task 1 — Update `BobleLoot.toc`

**Files:** `BobleLoot.toc`

Add `UI/Toast.lua` and `UI/HistoryViewer.lua` in the correct load order. The `Libs\Libs.xml` line at the top ensures LibStub is available for the lib-st check.

- [ ] 1.1 Open `BobleLoot.toc`. Locate the `UI\Theme.lua` line. Insert two lines after it:

  ```
  UI\Toast.lua
  UI\HistoryViewer.lua
  ```

  Full updated `UI` block should read:

  ```
  UI\Theme.lua
  UI\Toast.lua
  UI\HistoryViewer.lua
  UI\SettingsPanel.lua
  UI\MinimapButton.lua
  ```

- [ ] 1.2 Verify that `Data\BobleLoot_Data.lua` still appears before `Core.lua`, and that `Core.lua` still appears before all `UI\` entries. The existing TOC structure already satisfies this; confirm nothing was displaced.

**Verification:** `/reload` in-game; `ns.Toast` and `ns.HistoryViewer` are non-nil in the Lua environment. No "module not found" errors in the system log.

**Commit:** `feat(toc): register UI/Toast.lua and UI/HistoryViewer.lua`

---

## Task 2 — Create `UI/Toast.lua`

**Files:** `UI/Toast.lua` (new file)

The toast system is a single 280×40 frame permanently attached to `UIParent`, always on top (strata `TOOLTIP`), anchored at top-centre of the screen 60px below the top edge (below the minimap row, above the player frame area). It is never destroyed; it is shown/hidden and alpha-animated via `UIFrameFadeOut` / `UIFrameFadeIn` (the WoW built-in fade helpers) combined with a `C_Timer`.

A simple queue of one is implemented by updating the visible toast's text when a new event fires while a toast is already visible rather than pushing a second frame. This prevents visual clutter during rapid event bursts (e.g., several `BobleLoot_SyncProgress` events firing 500ms apart during a chunked transfer).

```lua
--[[ UI/Toast.lua
     BobleLoot toast notification surface.
     Roadmap item 3.12.

     Public API:
       ns.Toast:Show(message, level)   -- "success"|"warning"|"error"
       ns.Toast:Setup(addonArg)        -- called from Core:OnEnable

     AceEvents consumed (registered in Setup):
       BobleLoot_SyncWarning           -- from Sync._recordWarning (this batch, Task 5)
       BobleLoot_SyncProgress          -- from Batch 2C chunked sync
       BobleLoot_SyncTimedOut          -- from Batch 2C chunked sync
       BobleLoot_SchemaDriftWarning    -- from Batch 3C schema-drift detection

     Design notes:
       * One frame only. Subsequent events update text in-place.
       * Fade in 0.2s, hold 3s, fade out 0.5s.
       * Never uses UIErrorsFrame.
       * Colors: success=Theme.success, warning=Theme.warning, error=Theme.danger.
       * Position is fixed (top-centre); not user-movable (toasts are ephemeral).
]]

local ADDON_NAME, ns = ...
local Toast = {}
ns.Toast = Toast

local T            -- set to ns.Theme in Setup; avoids forward-ref at file load
local frame        -- the single toast frame
local textLabel    -- FontString child of frame
local holdTimer    -- C_Timer handle for the 3-second hold phase
local addon        -- set in Setup

local FRAME_W   = 280
local FRAME_H   = 40
local FADE_IN   = 0.2
local HOLD_SECS = 3.0
local FADE_OUT  = 0.5

local LEVEL_COLOR = {
    success = function() return T.success end,
    warning = function() return T.warning end,
    error   = function() return T.danger  end,
}

-- ── Frame creation (lazy, once) ───────────────────────────────────────

local function BuildFrame()
    if frame then return end
    T = ns.Theme

    frame = CreateFrame("Frame", "BobleLootToastFrame", UIParent, "BackdropTemplate")
    frame:SetSize(FRAME_W, FRAME_H)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -60)
    frame:SetFrameStrata("TOOLTIP")
    frame:SetFrameLevel(200)

    T.ApplyBackdrop(frame, "bgTitleBar", "borderAccent")

    textLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    textLabel:SetFont(T.fontBody, T.sizeBody, "OUTLINE")
    textLabel:SetPoint("CENTER", frame, "CENTER", 0, 0)
    textLabel:SetJustifyH("CENTER")
    textLabel:SetWidth(FRAME_W - 16)

    -- Left-edge color stripe (3px wide, full height), tinted per level.
    local stripe = frame:CreateTexture(nil, "OVERLAY")
    stripe:SetSize(3, FRAME_H - 2)
    stripe:SetPoint("LEFT", frame, "LEFT", 1, 0)
    stripe:SetColorTexture(1, 1, 1, 1)
    frame._stripe = stripe

    frame:SetAlpha(0)
    frame:Hide()
end

-- ── Animation helpers ─────────────────────────────────────────────────

local function CancelHold()
    if holdTimer then
        holdTimer:Cancel()
        holdTimer = nil
    end
end

local function StartFadeOut()
    CancelHold()
    UIFrameFadeOut(frame, FADE_OUT, frame:GetAlpha(), 0)
    C_Timer.After(FADE_OUT, function()
        if frame then frame:Hide() end
    end)
end

local function StartHold()
    CancelHold()
    holdTimer = C_Timer.NewTimer(HOLD_SECS, StartFadeOut)
end

-- ── Public API ────────────────────────────────────────────────────────

--- Show (or update) the toast.
-- @param message  string — text to display (max ~50 chars for legibility)
-- @param level    string — "success"|"warning"|"error" (default "success")
function Toast:Show(message, level)
    BuildFrame()
    level = level or "success"
    local colorFn = LEVEL_COLOR[level] or LEVEL_COLOR.success
    local col = colorFn()

    textLabel:SetText(message)
    textLabel:SetTextColor(col[1], col[2], col[3], col[4] or 1)
    if frame._stripe then
        frame._stripe:SetColorTexture(col[1], col[2], col[3], col[4] or 1)
    end

    -- If already visible: update text in place; restart hold timer.
    if frame:IsShown() then
        CancelHold()
        -- Cancel any running fade-out by snapping alpha back to 1.
        frame:SetAlpha(1)
        StartHold()
        return
    end

    -- Fresh show: fade in then hold.
    frame:SetAlpha(0)
    frame:Show()
    UIFrameFadeIn(frame, FADE_IN, 0, 1)
    C_Timer.After(FADE_IN, StartHold)
end

-- ── AceEvent listeners ────────────────────────────────────────────────

--- Wire AceEvent listeners. Called once from Core:OnEnable after addon
-- has fully initialized its AceEvent mixin.
function Toast:Setup(addonArg)
    addon = addonArg
    T = ns.Theme

    -- Sync warning (fired by Sync._recordWarning, Task 5 of this plan).
    addon:RegisterMessage("BobleLoot_SyncWarning", function(_, sender, reason)
        local msg = string.format("[BL] Sync warning from %s: %s", sender, reason)
        Toast:Show(msg, "warning")
    end)

    -- Chunked sync progress (Batch 2C contract).
    -- Arguments: sender (string), received (number), total (number).
    addon:RegisterMessage("BobleLoot_SyncProgress", function(_, sender, received, total)
        local msg = string.format("[BL] Syncing from %s: %d/%d chunks", sender, received, total)
        Toast:Show(msg, "success")
    end)

    -- Chunked sync timeout (Batch 2C contract).
    -- Arguments: sender (string).
    addon:RegisterMessage("BobleLoot_SyncTimedOut", function(_, sender)
        local msg = string.format("[BL] Sync from %s timed out — using local data.", sender)
        Toast:Show(msg, "error")
    end)

    -- RC schema-drift warning (Batch 3C contract).
    -- Arguments: description (string).
    addon:RegisterMessage("BobleLoot_SchemaDriftWarning", function(_, description)
        local msg = "[BL] RC schema drift: " .. (description or "unknown")
        Toast:Show(msg, "warning")
    end)
end
```

- [ ] 2.1 Create `UI/Toast.lua` with the content above.

- [ ] 2.2 Verify the frame dims: `FRAME_W = 280`, `FRAME_H = 40`. Verify anchor: `"TOP", UIParent, "TOP", 0, -60`.

- [ ] 2.3 Verify all four `RegisterMessage` calls match the AceEvent names documented in their producing plans:
  - `BobleLoot_SyncWarning` — produced by Task 5 (this plan, `Sync._recordWarning`)
  - `BobleLoot_SyncProgress` — produced by Batch 2C `_onReceiveChunk`
  - `BobleLoot_SyncTimedOut` — produced by Batch 2C `_onChunkTimeout`
  - `BobleLoot_SchemaDriftWarning` — produced by Batch 3C `LH:DetectSchemaVersion` failure path

**Verification:**
- `/reload` → no Lua errors.
- In chat: `/run ns.Toast:Show("Dataset synced successfully.", "success")` → green toast appears top-centre, fades after 3s.
- `/run ns.Toast:Show("Sync warning test", "warning")` → yellow toast.
- `/run ns.Toast:Show("Error test", "error")` → red toast.
- Fire two rapid calls 100ms apart → second call updates the visible toast's text in place, does not stack a second frame.

**Commit:** `feat(ui): add Toast notification system (3.12)`

---

## Task 3 — Wire `Toast:Setup` in `Core.lua` (`OnEnable`)

**Files:** `Core.lua`

`Toast:Setup` must be called from `BobleLoot:OnEnable` because it calls `addon:RegisterMessage`, which requires the AceEvent mixin to be active. `OnInitialize` fires before the mixin is fully operational for message passing; `OnEnable` is the correct hook.

- [ ] 3.1 In `BobleLoot:OnEnable`, after the existing `ns.MinimapButton:Setup` call and before `TryHookRC`, add:

  ```lua
  if ns.Toast and ns.Toast.Setup then
      ns.Toast:Setup(self)
  end
  if ns.HistoryViewer and ns.HistoryViewer.Setup then
      ns.HistoryViewer:Setup(self)
  end
  ```

  Guard both with `if ns.X and ns.X.Setup then` for load-order safety, matching the pattern used for every other module in `OnEnable`.

- [ ] 3.2 Add `historyViewerPos` to `DB_DEFAULTS.profile`:

  ```lua
  historyViewerPos = { point = "CENTER", x = 0, y = 0 },
  ```

  Insert after the `panelPos` line. This follows the exact pattern of `panelPos` used by `SettingsPanel`.

**Verification:**
- `/reload` → `BobleLootDB.profile.historyViewerPos` exists in SavedVars.
- `/run print(ns.Toast ~= nil)` → `true`.
- `/run print(ns.HistoryViewer ~= nil)` → `true`.

**Commit:** `feat(core): wire Toast and HistoryViewer setup, add historyViewerPos DB default`

---

## Task 4 — Create `UI/HistoryViewer.lua`

**Files:** `UI/HistoryViewer.lua` (new file)

The history viewer is a movable, resizable-width frame (fixed height 460px, default width 620px). It replicates the chrome of `UI/SettingsPanel.lua` exactly: dark `bgBase` backdrop, cyan `borderAccent`, title bar with `bgTitleBar` fill and a 1px cyan underline, close button top-right. Position is saved to `BobleLootDB.profile.historyViewerPos` on `OnMouseUp` (after a drag) using the same pattern as `SettingsPanel`.

The table area uses lib-st if available; otherwise it uses the `FontString` fallback described in the architecture section.

```lua
--[[ UI/HistoryViewer.lua
     BobleLoot loot history viewer.
     Roadmap item 3.11.

     Public API:
       ns.HistoryViewer:Setup(addonArg)  -- called from Core:OnEnable
       ns.HistoryViewer:Open()           -- open (or focus) the viewer
       ns.HistoryViewer:Close()          -- close the viewer
       ns.HistoryViewer:Toggle()         -- open if closed, close if open
       ns.HistoryViewer:Refresh()        -- re-query and redraw the table

     Columns (left to right):
       Player      | 120px | player name (Name-Realm, truncated)
       Item        | 200px | item name; item link on GameTooltip hover
       Date        |  80px | "YYYY-MM-DD" or "MM/DD" from entry time
       Response    | 100px | "BiS", "Major", "Minor", "Mainspec"
       Weight Crd  |  80px | per-entry credit (e.g. 1.50 for BiS)

     Per-player total row at table bottom:
       Player name | colspan span | — | — | Weighted sum (bold)

     Filters:
       Player dropdown — "All players" or specific Name-Realm
       Date range slider — mirrors lootHistoryDays (7..90, step 1)

     lib-st path:   LibStub("ScrollingTable", true) non-nil → use lib-st.
     Fallback path: paginated FontString list, 20 rows per page with
                    Prev/Next buttons.

     Position persistence:
       Saved to BobleLootDB.profile.historyViewerPos on drag-stop.
       Restored in Open().
]]

local ADDON_NAME, ns = ...
local HV = {}
ns.HistoryViewer = HV

local addon
local frame
local built = false
local libST = LibStub("ScrollingTable", true)  -- nil if not available

-- Logged at load time for diagnostics (visible via /print ns.HistoryViewer._stMode).
HV._stMode = libST and "lib-st" or "fallback-fontstring"

local FRAME_W    = 620
local FRAME_H    = 460
local TITLEBAR_H = 28
local FILTER_H   = 42
local BODY_Y_OFF = TITLEBAR_H + FILTER_H
local TABLE_H    = FRAME_H - BODY_Y_OFF - 10

-- Column widths for lib-st path.
local COLS = {
    { name = "Player",     width = 120, align = "LEFT"  },
    { name = "Item",       width = 200, align = "LEFT"  },
    { name = "Date",       width =  80, align = "CENTER"},
    { name = "Response",   width = 100, align = "CENTER"},
    { name = "Wt Credit",  width =  80, align = "RIGHT" },
}

local FALLBACK_PAGE_SIZE = 20

-- State
local currentFilter = nil      -- nil = all players
local currentDays   = nil      -- nil = use db.profile.lootHistoryDays
local rawRows       = {}       -- { playerName, itemLink, date, response, credit }
local totalRows     = {}       -- { playerName, total } — one per player, sorted desc
local stTable       = nil      -- lib-st table object (lib-st path only)
local fbRows        = {}       -- FontString row frames (fallback path only)
local fbPage        = 1
local fbTotalPages  = 1

-- Dropdown state
local playerDropdown = nil
local playerList     = {}       -- ordered list of Name-Realm strings

-- ── Data loading ──────────────────────────────────────────────────────

local RESPONSE_LABEL = {
    bis      = "BiS",
    major    = "Major",
    minor    = "Minor",
    mainspec = "Mainspec",
}

-- Rebuild rawRows and totalRows from the RC loot database.
-- Applies currentFilter (player name) and currentDays (date window).
local function LoadRows()
    rawRows   = {}
    totalRows = {}

    local RC = LibStub and LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil", true)
    -- Reuse LootHistory's internal getRCLootDB by delegating to Apply then reading back.
    -- We don't have direct access to LootHistory's local getRCLootDB, so we call
    -- CountItemsReceived on the raw database obtained via the same path LH uses.
    -- To iterate raw entries (for the Item and Date columns) we access the merged DB
    -- the same way LootHistory does: prefer RCLootCouncilLootDB.factionrealm.
    local db
    if _G.RCLootCouncilLootDB and _G.RCLootCouncilLootDB.factionrealm then
        -- Merge all faction-realms (mirrors LootHistory.lua:mergeFactionRealms).
        db = {}
        for _, perRealm in pairs(_G.RCLootCouncilLootDB.factionrealm) do
            if type(perRealm) == "table" then
                for charName, entries in pairs(perRealm) do
                    if type(entries) == "table" then
                        local dst = db[charName] or {}
                        for _, e in ipairs(entries) do dst[#dst + 1] = e end
                        db[charName] = dst
                    end
                end
            end
        end
    elseif RC and RC.lootDB and type(RC.lootDB) == "table" then
        db = RC.lootDB
    end

    if not db then return end

    local profile = addon and addon.db and addon.db.profile
    local days    = currentDays or (profile and profile.lootHistoryDays) or 28
    local weights = (profile and profile.lootWeights)
                    or { bis = 1.5, major = 1.0, mainspec = 1.0, minor = 0.5 }
    local minIlvl = (profile and profile.lootMinIlvl) or 0
    local cutoff  = (days > 0) and (time() - days * 24 * 3600) or nil

    -- Collect per-player totals via LootHistory:CountItemsReceived if available.
    local playerTotals = {}
    if ns.LootHistory and ns.LootHistory.CountItemsReceived then
        playerTotals = ns.LootHistory:CountItemsReceived(db, days, weights, minIlvl)
    end

    -- Build raw rows for the table body.
    local function entryTime(e)
        local t = e.time or e.date or e.timestamp
        if type(t) == "number" then return t end
        if type(t) == "string" then return tonumber(t:match("(%d+)")) end
        return nil
    end
    local function entryIlvl(e)
        local v = e.ilvl or e.itemLevel or e.iLvl or e.lvl
        if type(v) == "number" and v > 0 then return v end
        return nil
    end
    local function classify(e)
        local r = e.response or e.responseID
        if type(r) ~= "string" then return nil end
        local lower = r:lower()
        -- Exclusions first
        for _, pat in ipairs({ "transmog","off%-spec","offspec","greed",
                                "disenchant","sharded?","pass","autopass","pvp",
                                "free%s*roll","fun" }) do
            if lower:find(pat) then return nil end
        end
        if lower:find("^bis$") or lower:find("best in slot") or lower:find("%(bis%)") then
            return "bis"
        end
        if lower:find("major") then return "major" end
        if lower:find("minor") or lower:find("small upgrade") then return "minor" end
        if lower:find("mainspec") or lower:find("main%-spec") or
           lower:find("need") or lower:find("upgrade") then return "mainspec" end
        return nil
    end

    local playerSet = {}
    for charName, entries in pairs(db) do
        if (not currentFilter or currentFilter == charName)
           and type(entries) == "table" then
            playerSet[charName] = true
            for _, e in ipairs(entries) do
                if type(e) == "table" then
                    local cat = classify(e)
                    if cat then
                        local t = entryTime(e)
                        local timeOk = (not cutoff) or (not t) or t >= cutoff
                        local ilvl = entryIlvl(e)
                        local ilvlOk = (minIlvl <= 0) or (ilvl == nil) or (ilvl >= minIlvl)
                        if timeOk and ilvlOk then
                            local link = e.lootWon or e.link or e.itemLink or e.string or "?"
                            local dateStr = t and date("%Y-%m-%d", t) or "?"
                            local credit = weights[cat] or 0
                            rawRows[#rawRows + 1] = {
                                playerName = charName,
                                itemLink   = link,
                                dateStr    = dateStr,
                                dateTime   = t or 0,
                                response   = RESPONSE_LABEL[cat] or cat,
                                credit     = credit,
                            }
                        end
                    end
                end
            end
        end
    end

    -- Sort raw rows: date descending (newest first) — spec 3.11 default.
    table.sort(rawRows, function(a, b)
        return (a.dateTime or 0) > (b.dateTime or 0)
    end)

    -- Build total rows from playerTotals, sorted descending by total.
    local totList = {}
    for name, row in pairs(playerTotals) do
        if not currentFilter or currentFilter == name then
            totList[#totList + 1] = { name = name, total = row.total or 0 }
        end
    end
    table.sort(totList, function(a, b) return a.total > b.total end)
    totalRows = totList

    -- Build sorted player list for the dropdown.
    playerList = {}
    for name in pairs(playerSet) do
        playerList[#playerList + 1] = name
    end
    table.sort(playerList)
end

-- ── Frame chrome (shared with SettingsPanel style) ────────────────────

local function BuildFrame()
    if built then return end
    built = true
    local T = ns.Theme

    frame = CreateFrame("Frame", "BobleLootHistoryViewer", UIParent, "BackdropTemplate")
    frame:SetSize(FRAME_W, FRAME_H)
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)

    T.ApplyBackdrop(frame, "bgBase", "borderAccent")

    -- ── Title bar ──────────────────────────────────────────────────────
    local titleBar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    titleBar:SetHeight(TITLEBAR_H)
    T.ApplyBackdrop(titleBar, "bgTitleBar", "borderNormal")

    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetFont(T.fontTitle, T.sizeTitle, "OUTLINE")
    titleText:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
    titleText:SetPoint("LEFT", titleBar, "LEFT", 10, 0)
    titleText:SetText("Loot History")

    -- Cyan 1px underline beneath the title bar (matching SettingsPanel).
    local underline = frame:CreateTexture(nil, "OVERLAY")
    underline:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 0.8)
    underline:SetHeight(1)
    underline:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0, -TITLEBAR_H)
    underline:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -TITLEBAR_H)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
    closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -2, 0)
    closeBtn:SetScript("OnClick", function() HV:Close() end)

    -- Drag handling + position save
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if addon and addon.db then
            local p = addon.db.profile.historyViewerPos
            p.point, _, _, p.x, p.y = self:GetPoint()
        end
    end)

    -- ── Filter bar ────────────────────────────────────────────────────
    local filterY = -TITLEBAR_H - 8

    -- Player dropdown label
    local playerLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    playerLabel:SetFont(T.fontBody, T.sizeBody)
    playerLabel:SetTextColor(T.white[1], T.white[2], T.white[3])
    playerLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, filterY)
    playerLabel:SetText("Player:")

    -- Player dropdown (UIDropDownMenuTemplate)
    local dropFrame = CreateFrame("Frame", "BobleLootHistoryPlayerDrop", frame,
        "UIDropDownMenuTemplate")
    dropFrame:SetPoint("LEFT", playerLabel, "RIGHT", 4, 0)
    UIDropDownMenu_SetWidth(dropFrame, 140)
    playerDropdown = dropFrame

    local function RefreshDropdown()
        UIDropDownMenu_Initialize(playerDropdown, function(self, level)
            local info = UIDropDownMenu_CreateInfo()
            -- "All" entry
            info.text = "All players"
            info.value = nil
            info.checked = (currentFilter == nil)
            info.func = function()
                currentFilter = nil
                UIDropDownMenu_SetText(playerDropdown, "All players")
                HV:Refresh()
            end
            UIDropDownMenu_AddButton(info, level)
            -- Per-player entries
            for _, name in ipairs(playerList) do
                info = UIDropDownMenu_CreateInfo()
                info.text = name
                info.value = name
                info.checked = (currentFilter == name)
                info.func = function()
                    currentFilter = name
                    UIDropDownMenu_SetText(playerDropdown, name)
                    HV:Refresh()
                end
                UIDropDownMenu_AddButton(info, level)
            end
        end)
        local displayText = currentFilter or "All players"
        UIDropDownMenu_SetText(playerDropdown, displayText)
    end
    frame._refreshDropdown = RefreshDropdown

    -- Date-range slider (mirrors lootHistoryDays, range 7..90)
    local daysLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    daysLabel:SetFont(T.fontBody, T.sizeBody)
    daysLabel:SetTextColor(T.white[1], T.white[2], T.white[3])
    daysLabel:SetPoint("LEFT", dropFrame, "RIGHT", 24, 0)
    daysLabel:SetText("Days:")

    local sliderName = "BobleLootHistoryDaysSlider"
    local slider = CreateFrame("Slider", sliderName, frame, "OptionsSliderTemplate")
    slider:SetPoint("LEFT", daysLabel, "RIGHT", 8, 0)
    slider:SetMinMaxValues(7, 90)
    slider:SetValueStep(1)
    slider:SetWidth(120)
    slider:SetHeight(16)
    _G[sliderName .. "Low"]:SetText("7d")
    _G[sliderName .. "High"]:SetText("90d")

    local sliderValLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sliderValLabel:SetFont(T.fontBody, T.sizeSmall)
    sliderValLabel:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
    sliderValLabel:SetPoint("LEFT", slider, "RIGHT", 6, 0)

    slider:SetScript("OnValueChanged", function(self, val)
        val = math.floor(val + 0.5)
        currentDays = val
        sliderValLabel:SetText(val .. "d")
        HV:Refresh()
    end)
    frame._slider = slider
    frame._sliderValLabel = sliderValLabel

    -- ── Table area ────────────────────────────────────────────────────
    local tableY = -(TITLEBAR_H + FILTER_H + 4)

    if libST then
        -- lib-st path
        stTable = libST:CreateST(COLS, math.floor(TABLE_H / 16), 16,
            { ["r"] = 0.10, ["g"] = 0.10, ["b"] = 0.12, ["a"] = 1.0 }, frame)
        stTable.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, tableY)
        stTable.frame:SetWidth(FRAME_W - 16)
        stTable:SetWidth(FRAME_W - 16)
        -- Default sort: column 3 (Date), descending.
        stTable:SortData()
    else
        -- Fallback: ScrollFrame with FontString rows.
        local sf = CreateFrame("ScrollFrame", "BobleLootHistorySF", frame)
        sf:SetPoint("TOPLEFT",  frame, "TOPLEFT",  8, tableY)
        sf:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 30)
        local content = CreateFrame("Frame", nil, sf)
        content:SetSize(FRAME_W - 16, TABLE_H)
        sf:SetScrollChild(content)
        frame._sfContent = content
        frame._sf        = sf

        -- Prev / Next page buttons for fallback mode.
        local prevBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        prevBtn:SetSize(60, 20)
        prevBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 6)
        prevBtn:SetText("< Prev")
        prevBtn:SetScript("OnClick", function()
            if fbPage > 1 then fbPage = fbPage - 1; HV:_DrawFallback() end
        end)
        local nextBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        nextBtn:SetSize(60, 20)
        nextBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 6)
        nextBtn:SetText("Next >")
        nextBtn:SetScript("OnClick", function()
            if fbPage < fbTotalPages then fbPage = fbPage + 1; HV:_DrawFallback() end
        end)
        local pageLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        pageLabel:SetFont(T.fontBody, T.sizeSmall)
        pageLabel:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
        pageLabel:SetPoint("BOTTOM", frame, "BOTTOM", 0, 8)
        frame._pageLabel = pageLabel
    end
end

-- ── lib-st data population ────────────────────────────────────────────

local function PopulateLibST()
    if not stTable then return end
    local data = {}
    for _, row in ipairs(rawRows) do
        data[#data + 1] = {
            [1] = row.playerName,
            [2] = row.itemLink,
            [3] = row.dateStr,
            [4] = row.response,
            [5] = string.format("%.2f", row.credit),
            -- Store raw dateTime for sorting.
            _dateTime = row.dateTime,
        }
    end
    -- Append per-player total rows (shown after all regular rows).
    for _, tot in ipairs(totalRows) do
        data[#data + 1] = {
            [1] = "|cff" .. string.format("%02x%02x%02x",
                  math.floor(ns.Theme.accent[1]*255),
                  math.floor(ns.Theme.accent[2]*255),
                  math.floor(ns.Theme.accent[3]*255))
                  .. tot.name .. " TOTAL|r",
            [2] = "",
            [3] = "",
            [4] = "",
            [5] = string.format("%.2f", tot.total),
            _dateTime = math.huge,  -- sort totals to the very bottom
        }
    end
    stTable:SetData(data, true)
end

-- ── Fallback FontString renderer ──────────────────────────────────────

function HV:_DrawFallback()
    if not frame or not frame._sfContent then return end
    local T = ns.Theme
    local content = frame._sfContent
    -- Clear existing rows.
    for _, r in ipairs(fbRows) do r:Hide() end
    fbRows = {}

    -- Header row
    local colWidths = { 120, 200, 80, 100, 80 }
    local colNames  = { "Player", "Item", "Date", "Response", "Wt Cr" }
    local hdrY = 0
    local x = 0
    for i, w in ipairs(colWidths) do
        local fs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetFont(T.fontBody, T.sizeSmall, "OUTLINE")
        fs:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
        fs:SetSize(w, 16)
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", x, hdrY)
        fs:SetJustifyH(i >= 5 and "RIGHT" or (i == 3 and "CENTER" or "LEFT"))
        fs:SetText(colNames[i])
        fbRows[#fbRows + 1] = fs
        x = x + w
    end

    -- Data rows (paginated)
    local all = rawRows
    local pageStart = (fbPage - 1) * FALLBACK_PAGE_SIZE + 1
    local pageEnd   = math.min(fbPage * FALLBACK_PAGE_SIZE, #all)
    fbTotalPages    = math.max(1, math.ceil(#all / FALLBACK_PAGE_SIZE))
    if frame._pageLabel then
        frame._pageLabel:SetText(string.format("Page %d / %d", fbPage, fbTotalPages))
    end

    for idx = pageStart, pageEnd do
        local row = all[idx]
        local rowY = hdrY - (idx - pageStart + 1) * 16
        x = 0
        local rowData = {
            row.playerName,
            row.itemLink,
            row.dateStr,
            row.response,
            string.format("%.2f", row.credit),
        }
        for i, w in ipairs(colWidths) do
            local fs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            fs:SetFont(T.fontBody, T.sizeSmall)
            fs:SetTextColor(T.white[1], T.white[2], T.white[3])
            fs:SetSize(w, 16)
            fs:SetPoint("TOPLEFT", content, "TOPLEFT", x, rowY)
            fs:SetJustifyH(i >= 5 and "RIGHT" or (i == 3 and "CENTER" or "LEFT"))
            fs:SetText(rowData[i] or "")
            fbRows[#fbRows + 1] = fs
            x = x + w
        end
    end

    -- Total rows at the bottom of the page.
    local totalY = hdrY - (pageEnd - pageStart + 2) * 16 - 8
    for _, tot in ipairs(totalRows) do
        local fs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetFont(T.fontBody, T.sizeSmall, "OUTLINE")
        fs:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
        fs:SetSize(FRAME_W - 24, 16)
        fs:SetPoint("TOPLEFT", content, "TOPLEFT", 0, totalY)
        fs:SetJustifyH("LEFT")
        fs:SetText(string.format("%s  |  Weighted total: %.2f", tot.name, tot.total))
        fbRows[#fbRows + 1] = fs
        totalY = totalY - 16
    end
end

-- ── Public API ────────────────────────────────────────────────────────

function HV:Setup(addonArg)
    addon = addonArg
end

function HV:Open()
    BuildFrame()
    -- Restore saved position.
    if addon and addon.db then
        local p = addon.db.profile.historyViewerPos
        if p and p.point then
            frame:ClearAllPoints()
            frame:SetPoint(p.point, UIParent, p.point, p.x or 0, p.y or 0)
        end
        -- Sync slider to current profile value.
        local days = addon.db.profile.lootHistoryDays or 28
        currentDays = days
        if frame._slider then
            frame._slider:SetValue(days)
        end
        if frame._sliderValLabel then
            frame._sliderValLabel:SetText(days .. "d")
        end
    end
    frame:Show()
    self:Refresh()
end

function HV:Close()
    if frame then frame:Hide() end
end

function HV:Toggle()
    if frame and frame:IsShown() then
        self:Close()
    else
        self:Open()
    end
end

function HV:Refresh()
    if not frame or not frame:IsShown() then return end
    LoadRows()
    if frame._refreshDropdown then frame._refreshDropdown() end
    if libST then
        PopulateLibST()
    else
        fbPage = 1
        self:_DrawFallback()
    end
end
```

- [ ] 4.1 Create `UI/HistoryViewer.lua` with the content above.

- [ ] 4.2 Verify the classify logic in `LoadRows` matches the patterns in `LootHistory.lua` exactly (same exclusion patterns, same category patterns). The viewer duplicates this local function intentionally — importing LootHistory's private `classify` is not possible without making it a module API.

- [ ] 4.3 Verify `HV:Refresh()` guards with `if not frame or not frame:IsShown() then return end` — calling Refresh before Open has no effect.

- [ ] 4.4 Verify the libST nil-check at file load writes `HV._stMode` as either `"lib-st"` or `"fallback-fontstring"`.

**Verification:**
- `/reload` → no errors.
- `/run ns.HistoryViewer:Open()` → viewer frame appears at centre of screen with title "Loot History".
- With RC loot history populated: rows appear in the table sorted date descending.
- Player dropdown filters to a single player → table repopulates.
- Drag the viewer to a new position, `/reload`, re-open → position persists.
- `/run print(ns.HistoryViewer._stMode)` → prints either `"lib-st"` or `"fallback-fontstring"`.

**Commit:** `feat(ui): add HistoryViewer scrolling table (3.11)`

---

## Task 5 — Wire `Sync:_recordWarning` to fire `BobleLoot_SyncWarning` AceEvent

**Files:** `Sync.lua`

This is the cross-plan contract that makes sync warnings visible in the toast system. `Sync._recordWarning` currently only writes to the `_warnings` ring buffer. Adding a `SendMessage` call here ensures any active toast listener sees the warning without polling.

The `SendMessage` call requires a reference to the addon object. `Sync._addonRef` is already set by Batch 2C's `Task 2.3` (`Sync._addonRef = addon` at the top of `Sync:Setup`). If Batch 2C has not shipped yet, `Sync._addonRef` will be nil; guard with a nil-check so this change is safe regardless of Batch 2C's merge status.

- [ ] 5.1 Open `Sync.lua`. Locate `function Sync:_recordWarning(sender, reason)`. After the `table.remove` loop that trims the ring buffer to `WARNINGS_MAX`, add:

  ```lua
  -- Notify the toast system (plan 3.12) if the addon reference is set.
  -- Sync._addonRef is set by Sync:Setup (plan 2C contract) or by this
  -- plan's Task 3 via Core:OnEnable ordering. Guard for nil safety.
  if self._addonRef and self._addonRef.SendMessage then
      self._addonRef:SendMessage("BobleLoot_SyncWarning", sender, reason)
  end
  ```

- [ ] 5.2 Verify that `Sync:Setup` sets `self._addonRef = addon` (this line comes from Batch 2C; if not yet present, add it at the very top of `Sync:Setup`):

  ```lua
  function Sync:Setup(addon)
      Sync._addonRef = addon   -- required by plan 3.12 toast wiring
      -- ... remainder unchanged
  ```

**Verification:**
- Trigger a proto-mismatch warning by temporarily setting `MIN_PROTO_VERSION = 99` in a test copy, or use the existing `/bl syncwarnings` path to confirm the ring buffer is still populated.
- With Toast loaded: a yellow toast `"[BL] Sync warning from <name>: <reason>"` should appear whenever `_recordWarning` fires.

**Commit:** `feat(sync): fire BobleLoot_SyncWarning AceEvent from _recordWarning (3.12 contract)`

---

## Task 6 — Add `/bl history` slash subcommand to `Core.lua`

**Files:** `Core.lua`

- [ ] 6.1 In `BobleLoot:OnSlashCommand`, after the existing `elseif input == "lootdb" or input == "loothistory"` branch, add a new branch:

  ```lua
  elseif input == "history" then
      if ns.HistoryViewer then
          ns.HistoryViewer:Toggle()
      else
          self:Print("History viewer not loaded.")
      end
  ```

- [ ] 6.2 Add the `benchscore` branch in the same function. This handles both `/bl benchscore` (uses voting frame's current item if available) and `/bl benchscore <itemID>`:

  ```lua
  elseif input == "benchscore" or input:match("^benchscore%s+%d+$") then
      local itemID = tonumber(input:match("^benchscore%s+(%d+)$"))
      -- Fall back to current voting frame item if no ID provided.
      if not itemID and ns.VotingFrame and ns.VotingFrame.currentItemID then
          itemID = ns.VotingFrame.currentItemID
      end
      if not itemID then
          self:Print("Usage: /bl benchscore <itemID>  (or run during a vote session)")
          return
      end
      if not (ns.Scoring and ns.Scoring.ComputeAll) then
          self:Print("Bench scoring not available (Scoring:ComputeAll missing — requires Batch 3B).")
          return
      end
      local results = ns.Scoring:ComputeAll(itemID, self.db.profile, self:GetData())
      if not results or #results == 0 then
          self:Print("No scores computed. Ensure the dataset is loaded (/bl checkdata).")
          return
      end
      -- Build the formatted output string.
      local parts = {}
      for _, entry in ipairs(results) do
          parts[#parts + 1] = string.format("%s=%d", entry.name, entry.score)
      end
      -- Truncate to first 10 players if roster is very large.
      local MAX_SHOWN = 10
      local suffix = (#results > MAX_SHOWN)
          and string.format(" ... (%d more)", #results - MAX_SHOWN)
          or ""
      local top = {}
      for i = 1, math.min(MAX_SHOWN, #results) do top[#top + 1] = parts[i] end
      local itemLink = select(2, GetItemInfo(itemID)) or tostring(itemID)
      local output = string.format("[BL Bench] %s: %s%s",
          itemLink, table.concat(top, ", "), suffix)
      -- Send to officer channel if available, otherwise party.
      local sent = false
      for i = 1, GetNumChatWindows() do end  -- no-op; channel check below
      if IsInRaid() or IsInGroup() then
          -- Attempt officer channel first.
          local chanList = { GetChannelList() }
          -- GetChannelList returns alternating index, name pairs.
          local officerChanNum = nil
          for i = 1, #chanList, 2 do
              local name = chanList[i + 1]
              if name and name:lower():find("officer") then
                  officerChanNum = chanList[i]
                  break
              end
          end
          -- Prefer SendChatMessage to "OFFICER" channel type (always available to officers).
          local ok = pcall(function()
              SendChatMessage(output, "OFFICER")
          end)
          if ok then
              sent = true
          end
      end
      if not sent then
          if IsInGroup() then
              SendChatMessage(output, "PARTY")
          else
              self:Print(output)
          end
      end
  ```

- [ ] 6.3 Note: `SendChatMessage(output, "OFFICER")` silently fails (generates an error frame message) if the player is not an officer. The `pcall` wrapper above captures this and falls back to PARTY. Document this behaviour in a comment.

**Verification:**
- `/bl history` → viewer opens.
- `/bl history` again → viewer closes.
- `/bl benchscore 12345` with no data → "No scores computed" message.
- With Scoring:ComputeAll available and dataset loaded: sorted score list appears in officer or party chat.

**Commit:** `feat(core): add /bl history and /bl benchscore slash subcommands (3.11, 3.13)`

---

## Task 7 — Add "Loot history" to `UI/MinimapButton.lua` EasyMenu

**Files:** `UI/MinimapButton.lua`

The minimap button's EasyMenu already has entries for Broadcast, Refresh history, Run test, Transparency mode, (separator), and Open settings. The spec requires "Loot history" to appear above "Open settings".

- [ ] 7.1 In `MB:ShowDropdown()`, locate the separator entry:

  ```lua
  -- Separator
  { text = "", disabled = true, notCheckable = true },
  ```

  Insert a new entry immediately before the separator:

  ```lua
  -- Loot history viewer
  {
      text = "Loot history",
      notCheckable = true,
      func = function()
          if ns.HistoryViewer and ns.HistoryViewer.Toggle then
              ns.HistoryViewer:Toggle()
          end
      end,
  },
  ```

  The final order in the `menu` table should be:
  1. Header title
  2. Broadcast dataset
  3. Refresh loot history
  4. Run test session (submenu)
  5. Transparency mode
  6. **Loot history** (new)
  7. Separator
  8. Open settings
  9. Version info

**Verification:**
- Right-click the minimap button → "Loot history" appears in the dropdown above the separator.
- Click "Loot history" → viewer opens.

**Commit:** `feat(minimap): add Loot history entry to right-click dropdown (3.11)`

---

## Task 8 — Bench-mode: `Scoring:ComputeAll` interface contract (Batch 3B cross-contract)

**Files:** No new file. This task documents the API contract that Batch 3B must satisfy for Task 6's bench command to function. If implementing this plan before Batch 3B ships, the slash handler already guards with `if not (ns.Scoring and ns.Scoring.ComputeAll)` and prints a clear fallback message.

**Expected contract from Batch 3B:**

```lua
-- ns.Scoring:ComputeAll(itemID, profile, data) -> sorted list
-- Returns a table of entries, sorted by score descending:
--   { { name = "Name-Realm", score = number }, ... }
-- Includes all characters in data.characters for whom Compute returns non-nil.
-- Characters for whom Compute returns nil (missing sim data) are omitted.
-- Roadmap item 3.6 (Data): "Compute scores for all roster members.
--   Expose ns.Scoring:ComputeAll(itemID) returning a sorted list."
```

- [ ] 8.1 Add a comment block to `Core.lua` near the `benchscore` handler that quotes the expected contract (verbatim from the roadmap), to serve as the integration-point documentation for whoever implements Batch 3B.

- [ ] 8.2 If Batch 3B is already merged when this plan runs, verify the actual signature matches. The roadmap specifies `ComputeAll(itemID)` but this plan passes `(itemID, profile, data)` to avoid re-reading globals. Batch 3B should accept these arguments; if it only reads `addon.db.profile` internally, update the call in Task 6 to match.

**Verification:** With Batch 3B merged — `/bl benchscore <realItemID>` produces a sorted list with at least 2 players.

---

## Task 9 — Toast: handle transparency toggle events from `Core.lua`

**Files:** `Core.lua`

When the leader toggles transparency mode, the current code calls `addon:Print(...)` to confirm the change. After this plan ships, that print should be augmented (not replaced — the print provides transcript value) with a toast.

- [ ] 9.1 In `BobleLoot:SetTransparencyEnabled`, after the existing `addon:Print` in the `SETTINGS` handler inside `Sync:OnComm`, add:

  ```lua
  if ns.Toast and ns.Toast.Show then
      local state = s.transparency and "enabled" or "disabled"
      ns.Toast:Show(
          string.format("Transparency %s by %s", state, sender),
          s.transparency and "success" or "warning"
      )
  end
  ```

  This fires on the receiving client when a SETTINGS message arrives. The leader's own screen gets a toast from the direct `SetTransparencyEnabled` call; add the same pattern there:

  In the `elseif input == "transparency on"` / `"transparency off"` branches of `OnSlashCommand`, after `self:Print(...)`:

  ```lua
  if ns.Toast and ns.Toast.Show then
      ns.Toast:Show(
          "Transparency mode " .. (self:IsTransparencyEnabled() and "ENABLED" or "DISABLED"),
          self:IsTransparencyEnabled() and "success" or "warning"
      )
  end
  ```

- [ ] 9.2 Verify these additions do not break the existing transparency print behaviour — both the print and the toast should fire.

**Verification:**
- As leader: `/bl transparency on` → chat print + green toast `"Transparency mode ENABLED"`.
- As non-leader receiving SETTINGS: toast `"Transparency enabled by <leader>"` appears.

**Commit:** `feat(core): fire toast on transparency toggle (3.12 integration)`

---

## Task 10 — Toast: handle dataset staleness warning

**Files:** `Core.lua` (RaidReminder hook) or `RaidReminder.lua`

The roadmap spec for 3.12 mentions "dataset stale" as a toast producer. `RaidReminder.lua` currently handles staleness checks. The correct approach for this plan is to have `RaidReminder` fire an AceEvent that Toast listens to, keeping RaidReminder unaware of Toast.

- [ ] 10.1 In `RaidReminder.lua` (or wherever the stale-data check fires the existing chat message), identify the stale-dataset warning path. After the existing `addon:Print` for staleness:

  ```lua
  if addon.SendMessage then
      addon:SendMessage("BobleLoot_DataStale", hoursOld)
  end
  ```

- [ ] 10.2 In `Toast:Setup`, add a listener:

  ```lua
  addon:RegisterMessage("BobleLoot_DataStale", function(_, hoursOld)
      local msg = string.format("[BL] Dataset is %dh old — run wowaudit.py", hoursOld)
      Toast:Show(msg, "warning")
  end)
  ```

- [ ] 10.3 If `RaidReminder.lua` does not currently compute `hoursOld`, compute it at the call site:

  ```lua
  local generatedAt = _G.BobleLoot_Data and _G.BobleLoot_Data.generatedAt
  local hoursOld = generatedAt and
      math.floor((time() - (tonumber(generatedAt) or 0)) / 3600) or 0
  ```

**Verification:**
- Temporarily set `_G.BobleLoot_Data.generatedAt` to a timestamp 73 hours ago.
- Trigger `RaidReminder:ForceCheck(addon)` via `/bl checkdata`.
- Confirm yellow toast `"[BL] Dataset is 73h old — run wowaudit.py"` appears.

**Commit:** `feat(raidreminder): fire BobleLoot_DataStale AceEvent for toast integration (3.12)`

---

## Task 11 — Batch 3C drift banner cross-contract (documentation task)

**Files:** `UI/Toast.lua` (already handles `BobleLoot_SchemaDriftWarning` — see Task 2)

This task documents the cross-contract with Batch 3C so both implementors agree on the interface.

**Cross-contract with Batch 3C (`LH:DetectSchemaVersion`):**

Batch 3C's `LH:DetectSchemaVersion(db)` must fire `BobleLoot_SchemaDriftWarning` via `addon:SendMessage` when detection fails or when the detected schema version differs from the expected version. The argument is a short description string (max 60 chars), for example `"factionrealm key absent"` or `"rcSchemaDetected=0 (unknown shape)"`.

Toast's listener (registered in Task 2) handles this event with:
```lua
addon:RegisterMessage("BobleLoot_SchemaDriftWarning", function(_, description)
    local msg = "[BL] RC schema drift: " .. (description or "unknown")
    Toast:Show(msg, "warning")
end)
```

Batch 3C's implementor must ensure:
1. `addon:SendMessage` is called (not `addon:Print` alone).
2. The event name is exactly `"BobleLoot_SchemaDriftWarning"` (no variation).
3. The description argument is a non-nil string.

- [ ] 11.1 Add a `--[[ CROSS-CONTRACT: Batch 3C ]]` comment block at the `BobleLoot_SchemaDriftWarning` `RegisterMessage` call in `Toast:Setup` that quotes the contract above.

**Commit:** (No separate commit; included in Task 2's commit or a follow-up documentation commit if Batch 3C is written concurrently.)

---

## Task 12 — Manual smoke-test pass and cleanup

**Files:** All modified files (review pass only, no new code unless bugs are found).

- [ ] 12.1 Open the viewer via both `/bl history` and the minimap dropdown. Verify both paths work.

- [ ] 12.2 Apply a date filter via the slider (drag from 28 to 14 days). Verify row count decreases or stays the same (never increases when narrowing the window).

- [ ] 12.3 Filter by a player who has 3+ loot entries. Verify the total row at the bottom shows the correct weighted sum: sum the individual "Wt Credit" column values manually and compare.

- [ ] 12.4 Close the viewer. Move UIParent scale or change screen resolution. `/reload`. Reopen. Verify position is restored to the saved point, not the default centre.

- [ ] 12.5 Fire three rapid toasts in 200ms intervals via the Lua console:
  ```lua
  ns.Toast:Show("First", "success")
  C_Timer.After(0.1, function() ns.Toast:Show("Second", "warning") end)
  C_Timer.After(0.2, function() ns.Toast:Show("Third", "error") end)
  ```
  Verify: only one toast frame is visible; its text reads "Third"; colour is red.

- [ ] 12.6 `/bl benchscore <validItemIDFromDataset>` in a party or raid. Verify output format matches `[BL Bench] <Item>: Boble=88, Sprinty=84, ...`.

- [ ] 12.7 `/bl benchscore <validItemID>` outside a group. Verify the output is printed to the local chat frame (not sent to any channel).

**Commit:** `fix(viewer-surfaces): smoke-test followup fixes (if any)`

---

## Manual Verification Checklist

### 3.11 Loot history viewer

- [ ] `/bl history` opens the viewer frame.
- [ ] Minimap right-click → "Loot history" → viewer opens.
- [ ] Pressing the same path again closes the viewer (toggle behaviour).
- [ ] With RC loot history present: rows appear with correct columns (Player, Item, Date, Response, Wt Credit).
- [ ] Default sort is date descending (newest row first).
- [ ] Player dropdown "All players" shows all entries; selecting a player shows only their entries.
- [ ] Date-range slider at 7 days shows fewer rows than 90 days (assuming entries span >7 days).
- [ ] Per-player total row appears at the bottom with the correct weighted sum.
- [ ] With lib-st: table headers are rendered; rows are scrollable; column widths match COLS spec.
- [ ] With fallback mode (`LibStub("ScrollingTable", true)` returning nil): Prev/Next buttons appear; page label shows "Page 1 / N".
- [ ] Drag viewer to a new position. `/reload`. Reopen. Position persists.
- [ ] `BobleLootDB.profile.historyViewerPos` contains the saved point/x/y after a drag.
- [ ] Viewer Escape-key closes the frame (frame is registered with UIPanelCloseButton, which Esc handles automatically).
- [ ] `/run print(ns.HistoryViewer._stMode)` prints the active rendering mode.

### 3.12 Toast notification system

- [ ] `/run ns.Toast:Show("Test", "success")` → green toast appears top-centre.
- [ ] `/run ns.Toast:Show("Test", "warning")` → yellow toast.
- [ ] `/run ns.Toast:Show("Test", "error")` → red toast.
- [ ] Toast appears at `"TOP", UIParent, "TOP", 0, -60` (below minimap row).
- [ ] Toast fades in over 0.2s, holds for 3s, fades out over 0.5s.
- [ ] Three rapid calls in 200ms → one toast visible, text shows the last message.
- [ ] `UIErrorsFrame` is not used at any point (verify by searching for `UIErrorsFrame` in `Toast.lua` — must be absent).
- [ ] Trigger a sync warning via temporarily breaking proto version → yellow toast `"[BL] Sync warning from …"` appears.
- [ ] `RaidReminder:ForceCheck` with stale data → yellow toast `"[BL] Dataset is Xh old …"`.
- [ ] If Batch 2C is merged: trigger a chunked sync → progress toasts update in-place.
- [ ] If Batch 3C is merged: trigger `addon:SendMessage("BobleLoot_SchemaDriftWarning", "test")` → warning toast.
- [ ] Transparency toggle as leader → toast `"Transparency mode ENABLED/DISABLED"`.

### 3.13 Bench-mode UI surface

- [ ] `/bl benchscore 12345` (invalid ID, no data) → `"No scores computed"` message.
- [ ] `/bl benchscore <validItemID>` with dataset loaded and Batch 3B merged → sorted score list.
- [ ] Output format: `[BL Bench] <itemLink>: Name1=88, Name2=84, ...`.
- [ ] As an officer in a raid: output goes to officer chat.
- [ ] As a non-officer (or `pcall` fails for officer send): output goes to party chat.
- [ ] Outside any group: output goes to local chat frame (`addon:Print`).
- [ ] With >10 scoreable players: list is truncated to 10 with `... (N more)` suffix.
- [ ] `/bl benchscore` with no item ID during a vote session (`VotingFrame.currentItemID` set) → uses the current vote item automatically.

---

## Design Notes

### Why a single-queued toast rather than a stack

Stacked toasts require vertical layout management, z-ordering, and individual dismissal. More critically, the primary use-cases for BobleLoot toasts are high-frequency events: chunked sync fires a progress event for every received chunk (potentially 5-20 events per transfer), and a stacking model would produce a column of 20 overlapping toasts during a 7-chunk transfer. The single-frame update-in-place model converts that burst into a smoothly updating progress indicator — exactly the right UX for a progress event. For the lower-frequency events (sync complete, drift warning, transparency toggle) there is at most one event per action, so the single-frame model loses nothing.

The hold timer restart on each update-in-place means the toast always remains visible for 3 seconds after the last event in a burst, ensuring the final message (e.g., "sync complete" or "timed out") is readable.

### Why lib-st is preferred over a custom scroll list

lib-st is the established WoW addon community scrolling-table library. It handles column headers, sorting, row selection, and scroll-wheel support — all of which a custom `FontString` list must reimplement. Critically, RC itself uses lib-st natively (the voting frame's candidate list is a lib-st table), so a BobleLoot viewer built on lib-st is visually consistent with the RC surface it sits alongside.

The degradation path (paginated FontString fallback) exists not because lib-st is unreliable but because its presence in the `LibStub` registry depends on RC having already loaded — an ordering we cannot guarantee in all install configurations. The fallback is fully functional, just less polished.

No copy of lib-st is bundled in BobleLoot's `Libs/` because bundling a second copy of a library RC already ships creates a version-skew vector: the two copies could have different API surface or different `LibStub` version numbers, causing `LibStub` to silently prefer one over the other in unpredictable ways.

### Why bench output goes to officer chat rather than raid or general

The bench command answers the question "is it worth benching X for Y on this boss?" — a council-internal deliberation, not a player-facing announcement. Printing numerical scores for every roster member into raid chat would expose council scoring to players who opted out of transparency mode, which directly contradicts the opt-out purpose (roadmap item 2.11). Officer chat is the correct scope: visible only to players the game already gates as officers, auditable in the officer log, and consistent with how every other BobleLoot council action is discussed. The party fallback is used only when officer chat is unavailable (outside a group structure) or when the sending player lacks officer permissions, preventing silent drops.

---

## Coordination Notes

### Batch 3B — `ComputeAll` dependency

The bench-mode slash command (`/bl benchscore`) guards its core with `if not (ns.Scoring and ns.Scoring.ComputeAll)` and prints a clear "requires Batch 3B" message. This plan and Batch 3B can ship independently; once both are merged the feature activates automatically. The expected call signature is `ns.Scoring:ComputeAll(itemID, profile, data)` returning `{ { name, score }, ... }` sorted descending — Batch 3B's implementor should confirm or adjust the Task 6 call site if the actual signature differs.

The history viewer optionally surfaces `scoreHistory` (per-night score trends, roadmap item 3.8 cross-contract) but does not depend on it. If Batch 3B exposes `ns.Scoring.scoreHistory`, a future follow-up plan can add a trend delta column to the viewer without changing the module's public API.

### Batch 3C — drift banner cross-contract

Batch 3C's `LH:DetectSchemaVersion` is responsible for firing `BobleLoot_SchemaDriftWarning` via `addon:SendMessage`. This plan's Toast listener is the sole consumer. The event name, argument shape (single description string), and severity level (always "warning") are defined in Task 11 of this plan and must not deviate in Batch 3C's implementation. If Batch 3C ships first, `Toast:Setup` will silently receive the event into a void listener until this plan merges — no error on either side.

Additionally, Batch 3C surfaces a drift warning banner in `SettingsPanel`'s Data tab. That surface is owned entirely by Batch 3C; this plan does not touch `SettingsPanel.lua`. The toast is a complementary ephemeral signal; the settings banner is the persistent one.

### Batch 3D — ghost weights toggle toast (optional stretch)

Batch 3D (compare popout, ghost weights) could fire `ns.Toast:Show("Preview mode active", "warning")` when the ghost-weights toggle is enabled, and `ns.Toast:Show("Preview mode off", "success")` when disabled. This is not a hard dependency — Batch 3D can call `ns.Toast:Show` directly if `ns.Toast` is non-nil, with no changes required to this plan. The stretch goal is noted here for the Batch 3D implementor.

### Batch 2B — migration baseline for `historyViewerPos`

Batch 2B established `BobleLootDB.profile.dbVersion` and the `Migrations.lua` framework. The `historyViewerPos` key added in Task 3 of this plan is a new additive profile key covered by AceDB's built-in default merging — when the schema default is present and the SavedVar key is absent (fresh install or pre-3E install), AceDB initialises it to `{ point = "CENTER", x = 0, y = 0 }` automatically. No explicit migration entry in `Migrations.lua` is needed for an additive key addition. If Batch 2B's migration runner is present, the key will be visible from session 1 after the update.

### Batch 2C — `BobleLoot_SyncProgress` / `BobleLoot_SyncTimedOut` producer order

Batch 2C fires these AceEvents into the void until Batch 3E (this plan) provides listeners. The two plans are decoupled: Batch 2C can ship without Toast loaded (events fire harmlessly), and Batch 3E can ship without Batch 2C loaded (the `RegisterMessage` calls register listeners that will simply never fire). No ordering constraint between the two batches.
