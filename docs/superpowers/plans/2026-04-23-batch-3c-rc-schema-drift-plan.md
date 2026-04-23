# Batch 3C — RCLootCouncil Schema-Drift Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect when `RCLootCouncilLootDB` no longer matches the shape BobleLoot expects, log the mismatch with a version counter, and surface a visible warning to the raid leader so silent history-component failures become actionable.

**Architecture:** `LH:DetectSchemaVersion(db)` in `LootHistory.lua` walks a declarative expected-shape dictionary against the live `_G.RCLootCouncilLootDB` global and classifies the result as `ok`, `degraded` (some expected fields missing but enough to continue), or `unknown` (top-level shape unrecognisable). The detection result is persisted to `BobleLootDB.profile.rcSchemaDetected` alongside a counter and timestamp; this record is the single source of truth consumed by both `Core.lua` (slash output, first-session-load chat warning) and `UI/SettingsPanel.lua` (Data tab warning banner with copyable-popup drill-down). Neither side caches its own copy of the verdict.

**Tech Stack:** Lua (WoW 10.x)

**Roadmap items covered:** 3.7

> **3.7 `[Cross]` RCLootCouncil schema-drift detection**
>
> `LootHistory.lua` falls back across multiple field names for ilvl and
> time. Add `LH:DetectSchemaVersion(db)` that checks for `factionrealm`
> and other expected keys, logs the detected shape, and increments
> `BobleLootDB.profile.rcSchemaDetected` counter visible in
> `/bl lootdb` output. Prominent warning if detection fails.
>
> Cross contract: data side detects; UI side shows a warning banner in
> the Settings panel's Data tab when detection fails.

**Dependencies:**
- Batch 1 fully merged to `release/v1.1.0` — `LootHistory.lua` `Diagnose`/`DiagnoseChar`, `UI/Theme.lua` (`ns.Theme.warning`, `ns.Theme.danger`), `UI/SettingsPanel.lua` `BuildDataTab` + `MakeSection` + `StaticPopup` pattern.
- Batch 2B migration framework (`BobleLootDB.profile.dbVersion`) — `rcSchemaDetected` is added as an adjacent profile key; no new migration step is required because it is additive.

---

## File Structure

```
BobleLoot/
├── LootHistory.lua          -- DetectSchemaVersion(), schema shape constants,
│                            --   detection call in Setup() and Apply(), first-
│                            --   session-load flag (LH._driftWarnedThisSession)
├── Core.lua                 -- extend /bl lootdb branch: print schema verdict
│                            --   + per-field detail; emit first-load chat
│                            --   warning via PLAYER_ENTERING_WORLD handler
└── UI/
    └── SettingsPanel.lua    -- prepend RC schema warning banner to BuildDataTab;
                             --   banner visible only when drift detected;
                             --   click opens copyable StaticPopup with /bl lootdb
                             --   detail text
```

No new files. No TOC changes. All additions are purely additive inside
existing functions/modules.

---

## Cross-Plan Contract (Data side → UI side)

The following is the agreed contract for this `[Cross]` item. Both sides
read from the same persistence key; neither duplicates detection logic.

**Persistence shape** (written by `LootHistory.lua`, read by `SettingsPanel.lua`)

```lua
BobleLootDB.profile.rcSchemaDetected = {
    status        = "ok" | "degraded" | "unknown",
    -- "ok"       -> all expected top-level and per-entry fields confirmed present
    -- "degraded" -> factionrealm exists but one or more per-entry fields missing;
    --               fallback resolvers are firing
    -- "unknown"  -> factionrealm key absent or entire SavedVar missing
    version       = <number>,   -- monotonically incrementing detection counter
                                -- (bumped every time DetectSchemaVersion runs)
    checkedAt     = <number>,   -- time() of last detection pass
    missingFields = { <string>, ... },  -- human-readable list; empty on "ok"
    rcVersion     = <string>,   -- _G.RCLootCouncil.version or "?" if RC not loaded
    sourceUsed    = <string>,   -- matches LH.lastSource ("RCLootCouncilLootDB.factionrealm{...}")
}
```

**UI reads the contract as:**
- `status ~= "ok"` → show warning banner
- `status == "unknown"` → use `ns.Theme.danger` colour
- `status == "degraded"` → use `ns.Theme.warning` colour
- Banner text: `"RCLootCouncil schema mismatch — history may be incomplete. Run /bl lootdb for details."`
- Banner click → opens copyable `StaticPopup` whose edit-box text is the `/bl lootdb` schema section

---

## Task 1 — Schema shape dictionary + `LH:DetectSchemaVersion`

**File:** `LootHistory.lua`

Add a module-level expected-shape table and the detection function
immediately after the existing `getRCLootDB` helper (around line 140 in
the v1.1.0 file). The function must not raise errors; wrap risky
traversals in `pcall`.

- [ ] 1.1 Insert the shape constants above `LH:CountItemsReceived`:

```lua
-- ── RC schema-drift detection ─────────────────────────────────────────
--
-- Observed RC SavedVar shapes (all read-only; we never write to RC's SV):
--
--   Shape A (RC <= 2.x, current as of 2026-04):
--     RCLootCouncilLootDB = {
--       factionrealm = {
--         ["Horde - Draenor"] = {
--           ["Player-Realm"] = {
--             [1] = { date, time, lootWon, response, responseID, id, ... }
--           }
--         }
--       }
--     }
--
--   Shape B (hypothetical RC 3.x, per-spec or per-character flattening):
--     RCLootCouncilLootDB = {
--       ["Player-Realm"] = { ... }   -- factionrealm key gone
--     }
--
--   Shape C (hypothetical encrypted/opaque storage):
--     RCLootCouncilLootDB = { payload = "<base64>", version = 3 }
--
-- EXPECTED_ENTRY_FIELDS lists field-name groups. For each group, at least
-- one name must be present on a sample entry; if none are, that group is
-- flagged as missing.

local EXPECTED_ENTRY_FIELDS = {
    { group = "id",       names = { "id", "itemID" } },
    { group = "item",     names = { "lootWon", "link", "itemLink" } },
    { group = "response", names = { "response", "responseID" } },
    { group = "time",     names = { "time", "timestamp", "date" } },
    { group = "ilvl",     names = { "ilvl", "itemLevel", "iLvl", "lvl" } },
}
```

- [ ] 1.2 Add `LH:DetectSchemaVersion(db)` immediately after the constants:

```lua
-- Inspect `_G.RCLootCouncilLootDB` (or a passed-in substitute for
-- offline testing) and return a shape-verdict table matching the
-- cross-plan contract above. Also writes to BobleLootDB.profile if
-- `addon` is provided.
--
-- `db`    -- the raw RCLootCouncilLootDB table (or nil to use the live global)
-- `addon` -- the BobleLoot addon object (may be nil for unit testing)
-- Returns: verdict table (same shape as rcSchemaDetected)
function LH:DetectSchemaVersion(db, addon)
    db = db or _G.RCLootCouncilLootDB

    local verdict = {
        status        = "unknown",
        version       = 0,
        checkedAt     = time(),
        missingFields = {},
        rcVersion     = "?",
        sourceUsed    = "?",
    }

    -- Preserve existing counter across calls.
    local profile = addon and addon.db and addon.db.profile
    local prev = profile and profile.rcSchemaDetected
    verdict.version = (prev and type(prev.version) == "number")
                       and (prev.version + 1) or 1

    -- RC version string (purely informational).
    local ok, rc = pcall(function()
        return LibStub and LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil", true)
    end)
    if ok and rc and rc.version then
        verdict.rcVersion = tostring(rc.version)
    end

    -- ── Layer 1: top-level factionrealm key ───────────────────────────
    if type(db) ~= "table" then
        -- SavedVar entirely missing or wrong type.
        verdict.status = "unknown"
        verdict.missingFields = { "RCLootCouncilLootDB (top-level missing)" }
        if profile then profile.rcSchemaDetected = verdict end
        return verdict
    end

    local fr = db.factionrealm
    if type(fr) ~= "table" then
        verdict.status = "unknown"
        verdict.missingFields = { "RCLootCouncilLootDB.factionrealm" }
        if profile then profile.rcSchemaDetected = verdict end
        return verdict
    end

    -- ── Layer 2: factionrealm is table-of-tables ──────────────────────
    -- At least one factionrealm key must be a table of character entries.
    local frKey, frVal
    for k, v in pairs(fr) do
        if type(k) == "string" and type(v) == "table" then
            frKey, frVal = k, v
            break
        end
    end
    if not frKey then
        verdict.status = "unknown"
        verdict.missingFields = { "factionrealm sub-tables (no string->table entries)" }
        if profile then profile.rcSchemaDetected = verdict end
        return verdict
    end

    -- Confirm at least one character key maps to an array of tables.
    local charKey, charEntries
    for k, v in pairs(frVal) do
        if type(k) == "string" and type(v) == "table" and #v > 0
           and type(v[1]) == "table" then
            charKey, charEntries = k, v
            break
        end
    end
    if not charKey then
        -- factionrealm structure exists but contains no recognisable
        -- character arrays — could be an empty raid night or degraded.
        -- Treat as "degraded" rather than "unknown" because factionrealm
        -- is present; further entry-field checks are skipped (nothing to sample).
        verdict.status    = "degraded"
        verdict.sourceUsed = "RCLootCouncilLootDB.factionrealm{" .. frKey .. "}"
        verdict.missingFields = { "no character entry arrays found (empty history?)" }
        if profile then profile.rcSchemaDetected = verdict end
        return verdict
    end

    verdict.sourceUsed = "RCLootCouncilLootDB.factionrealm{" .. frKey .. "}[" .. charKey .. "]"

    -- ── Layer 3: per-entry field groups ───────────────────────────────
    -- Sample up to the first 3 entries to reduce false positives on
    -- partially-populated early entries.
    local sampleSize = math.min(3, #charEntries)
    local missingGroups = {}

    for _, fieldGroup in ipairs(EXPECTED_ENTRY_FIELDS) do
        local found = false
        for i = 1, sampleSize do
            local entry = charEntries[i]
            if type(entry) == "table" then
                for _, fieldName in ipairs(fieldGroup.names) do
                    if entry[fieldName] ~= nil then
                        found = true
                        break
                    end
                end
            end
            if found then break end
        end
        if not found then
            missingGroups[#missingGroups + 1] = fieldGroup.group
                .. " (tried: " .. table.concat(fieldGroup.names, "/") .. ")"
        end
    end

    verdict.missingFields = missingGroups

    -- "ilvl" is the only field group we already have fallback resolvers
    -- for that we tolerate silently; everything else is a real concern.
    -- "degraded" = ilvl missing (we can limp along) OR any one other
    -- group missing. "unknown" reserved for missing factionrealm only
    -- (handled above). Here all remaining cases are ok or degraded.
    if #missingGroups == 0 then
        verdict.status = "ok"
    else
        verdict.status = "degraded"
    end

    if profile then profile.rcSchemaDetected = verdict end
    return verdict
end
```

**Verification:**
- `/reload` in-game → no Lua errors in chat.
- `/run print(BobleLootDB.profile.rcSchemaDetected and BobleLootDB.profile.rcSchemaDetected.status)` → prints `ok` with a healthy RC install.

---

## Task 2 — Call detection in `Setup` and `Apply`

**File:** `LootHistory.lua`

The detection must run once per session on first load (in `Setup`) and re-run on every `Apply` so that the stored verdict stays current. A separate session flag prevents the first-load chat warning from repeating on subsequent `Apply` calls.

- [ ] 2.1 Add a module-level session flag above `LH:Setup`:

```lua
-- Set to true after the first-session drift warning has been emitted.
-- Reset to false by Setup() on each addon load.
LH._driftWarnedThisSession = false
```

- [ ] 2.2 Inside `LH:Setup`, after the existing `C_Timer.After(5, ...)` call but before the event frame registration, add the initial detection call:

```lua
    -- Initial schema detection. Runs after the C_Timer.After(5) fires so
    -- RC's SavedVariables are fully loaded. We schedule it at +6 seconds
    -- (one second after Apply) so the first Apply result is already written
    -- and DetectSchemaVersion can read a populated db.
    C_Timer.After(6, function()
        local verdict = self:DetectSchemaVersion(nil, addon)
        -- First-session chat warning (throttled to one per session load).
        if verdict.status ~= "ok" and not self._driftWarnedThisSession then
            self._driftWarnedThisSession = true
            addon:Print(string.format(
                "|cffFFA600[BobleLoot] RCLootCouncil schema mismatch detected "
                .. "(status: %s). Loot history may be incomplete. "
                .. "Run |cffffffff/bl lootdb|r|cffFFA600 for details.|r",
                verdict.status))
        end
    end)
```

- [ ] 2.3 At the top of `LH:Apply`, before the existing `getRCLootDB` call, add a detection refresh (silent — no chat warning here, only persistence update):

```lua
    -- Refresh schema detection on every Apply so the stored verdict
    -- reflects the current RC SavedVar state. No chat warning here;
    -- the first-session warning is throttled in Setup.
    self:DetectSchemaVersion(nil, addon)
```

**Verification:**
- `/run print(ns.LootHistory._driftWarnedThisSession)` → `false` before Setup fires, `true` after first-session warning emitted (if drift detected).
- With a healthy RC install: no chat warning on login; `BobleLootDB.profile.rcSchemaDetected.version` increments each `/reload`.

---

## Task 3 — Extend `/bl lootdb` slash output

**File:** `Core.lua`

The existing `elseif input == "lootdb"` branch already calls `LH:Diagnose(self)` then prints match counts. Extend it to print the schema detection verdict immediately after `Diagnose`.

- [ ] 3.1 In `Core.lua`, in `OnSlashCommand`, locate the `elseif input == "lootdb" or input == "loothistory"` block. After the existing `ns.LootHistory:Diagnose(self)` call but before `ns.LootHistory:Apply(self)`, insert:

```lua
            -- Schema detection output.
            local verdict = ns.LootHistory.lastVerdictForDiag
                         or (ns.LootHistory.DetectSchemaVersion
                             and ns.LootHistory:DetectSchemaVersion(nil, self))
            if verdict then
                local colour = (verdict.status == "ok")
                    and "|cff19CC4D"   -- green
                    or  (verdict.status == "degraded" and "|cffFFA600" or "|cffE63333")
                self:Print(string.format(
                    "RC schema status: %s%s|r  (check #%d, RC v%s, at %s)",
                    colour,
                    verdict.status,
                    verdict.version,
                    verdict.rcVersion,
                    date("%H:%M:%S", verdict.checkedAt)))
                self:Print("  Source: " .. (verdict.sourceUsed or "?"))
                if #verdict.missingFields > 0 then
                    self:Print("  Missing field groups: "
                        .. table.concat(verdict.missingFields, "; "))
                else
                    self:Print("  All expected field groups present.")
                end
            end
```

- [ ] 3.2 To make the last verdict available without a re-detection, add a line to `LH:DetectSchemaVersion` just before the `return verdict` statements:

```lua
    -- Cache for /bl lootdb readout without re-running detection.
    LH.lastVerdictForDiag = verdict
```

  This line must be added to all three `return` paths in `DetectSchemaVersion`. Implement by setting it once at the very end of the function — restructure the existing early returns to store via a local variable and fall through to a single return at the bottom. (Alternatively, add `LH.lastVerdictForDiag = verdict` immediately before each `return verdict` line — four locations.)

- [ ] 3.3 Update the help text in the final `else` branch of `OnSlashCommand` to document the schema output:

  No change required — `lootdb` is already listed. Schema output is additive; no new command word.

**Verification:**
- `/bl lootdb` prints three new lines: `RC schema status:`, `Source:`, and either `Missing field groups:` or `All expected field groups present.`
- With a healthy RC install the status line is green.

---

## Task 4 — Data tab warning banner in `SettingsPanel.lua`

**File:** `UI/SettingsPanel.lua`

Add a dismissable warning banner at the very top of the Data tab body, visible only when `rcSchemaDetected.status ~= "ok"`. The banner is a `MakeSection` card whose inner region contains a `FontString` and a small button that opens a `StaticPopup` edit box with the full schema detail text (same content as `/bl lootdb` schema section, pre-formatted).

This is the UI side of the cross-plan contract. It reads `BobleLootDB.profile.rcSchemaDetected` — it does not re-run detection.

- [ ] 4.1 In `BuildDataTab`, insert the following block immediately after `local body = CreateFrame("Frame", nil, parent)` and before the existing `infoCard` creation. The banner section is positioned at the very top and occupies 52px height; shift the existing `infoCard` and subsequent cards down by 60px when the banner is visible.

```lua
    -- ── RC schema warning banner ──────────────────────────────────────
    -- Visible only when rcSchemaDetected.status ~= "ok".
    -- Reads the stored verdict written by LootHistory:DetectSchemaVersion.

    local POPUP_SCHEMA_DETAIL = "BOBLELOOT_SCHEMA_DRIFT_DETAIL"

    local schemaCard, schemaInner = MakeSection(body, "RCLootCouncil compatibility")
    schemaCard:SetPoint("TOPLEFT",     body, "TOPLEFT",  6, -6)
    schemaCard:SetPoint("TOPRIGHT",    body, "TOPRIGHT", -6, -6)
    schemaCard:SetHeight(52)
    schemaCard:Hide()  -- shown conditionally in OnShow

    local schemaLbl = schemaInner:CreateFontString(nil, "OVERLAY")
    schemaLbl:SetFont(T.fontBody, T.sizeBody)
    schemaLbl:SetPoint("TOPLEFT", schemaInner, "TOPLEFT", 4, -2)
    schemaLbl:SetWidth(380)
    schemaLbl:SetText(
        "RCLootCouncil schema mismatch \xe2\x80\x94 history may be incomplete. "
        .. "Run |cffffffff/bl lootdb|r for details.")

    local schemaDetailBtn = MakeButton(schemaInner, "View details",
        function()
            -- Build detail text from stored verdict.
            local verdict = addon and addon.db
                            and addon.db.profile
                            and addon.db.profile.rcSchemaDetected
            local lines = {}
            if verdict then
                lines[#lines+1] = string.format(
                    "Status: %s  |  Check #%d  |  RC v%s",
                    verdict.status, verdict.version or 0, verdict.rcVersion or "?")
                lines[#lines+1] = string.format(
                    "Checked: %s",
                    verdict.checkedAt and date("%Y-%m-%d %H:%M:%S", verdict.checkedAt) or "?")
                lines[#lines+1] = "Source: " .. (verdict.sourceUsed or "?")
                if verdict.missingFields and #verdict.missingFields > 0 then
                    lines[#lines+1] = "Missing field groups:"
                    for _, f in ipairs(verdict.missingFields) do
                        lines[#lines+1] = "  - " .. f
                    end
                else
                    lines[#lines+1] = "All expected field groups confirmed present."
                end
            else
                lines[#lines+1] = "No detection result stored. Run /bl lootdb."
            end
            local detailText = table.concat(lines, "\n")

            if not StaticPopupDialogs[POPUP_SCHEMA_DETAIL] then
                StaticPopupDialogs[POPUP_SCHEMA_DETAIL] = {
                    text         = "RC schema drift detail (Ctrl+C to copy):",
                    button1      = OKAY,
                    hasEditBox   = true,
                    editBoxWidth = 420,
                    OnShow = function(self)
                        -- detailText is captured by closure; re-read on each show.
                        local v2 = addon and addon.db
                                   and addon.db.profile
                                   and addon.db.profile.rcSchemaDetected
                        local l2 = {}
                        if v2 then
                            l2[#l2+1] = string.format(
                                "Status: %s  |  Check #%d  |  RC v%s",
                                v2.status, v2.version or 0, v2.rcVersion or "?")
                            l2[#l2+1] = string.format(
                                "Checked: %s",
                                v2.checkedAt and date("%Y-%m-%d %H:%M:%S", v2.checkedAt) or "?")
                            l2[#l2+1] = "Source: " .. (v2.sourceUsed or "?")
                            if v2.missingFields and #v2.missingFields > 0 then
                                l2[#l2+1] = "Missing field groups:"
                                for _, f in ipairs(v2.missingFields) do
                                    l2[#l2+1] = "  - " .. f end
                            else
                                l2[#l2+1] = "All expected field groups confirmed present."
                            end
                        else
                            l2[#l2+1] = "No detection result stored. Run /bl lootdb."
                        end
                        local eb = self.editBox or self.EditBox
                        if eb then
                            eb:SetText(table.concat(l2, "\n"))
                            eb:SetFocus()
                            eb:HighlightText()
                        end
                    end,
                    EditBoxOnEnterPressed  = function(self) self:GetParent():Hide() end,
                    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
                    timeout      = 0,
                    whileDead    = true,
                    hideOnEscape = true,
                    preferredIndex = 3,
                }
            end
            StaticPopup_Show(POPUP_SCHEMA_DETAIL)
        end, { width = 100, height = 20, x = 388, y = -4 })
```

- [ ] 4.2 In the existing `body:SetScript("OnShow", ...)` at the bottom of `BuildDataTab`, add a schema-banner refresh block as the first statement inside the callback:

```lua
        -- RC schema banner visibility.
        local verdict = addon and addon.db
                         and addon.db.profile
                         and addon.db.profile.rcSchemaDetected
        if verdict and verdict.status ~= "ok" then
            local T2 = ns.Theme
            local col = (verdict.status == "degraded") and T2.warning or T2.danger
            schemaLbl:SetTextColor(col[1], col[2], col[3])
            schemaCard:Show()
            -- Push existing cards down by 60px when banner is visible.
            infoCard:SetPoint("TOPLEFT",  body, "TOPLEFT",  6, -64)
        else
            schemaCard:Hide()
            -- Restore default infoCard position.
            infoCard:SetPoint("TOPLEFT",  body, "TOPLEFT",  6, -6)
        end
```

  Note: `infoCard`'s `BOTTOMRIGHT` anchor is unchanged; only `TOPLEFT` is repositioned. The `SetPoint` call clears and replaces the existing TOPLEFT anchor because `SetPoint` with the same anchor name on the same frame replaces the previous anchor of that point.

**Verification:**
- With healthy RC install: open Settings > Data → banner section is hidden; info card sits at default position.
- With simulated drift (Task 6 scenario): banner is amber (`degraded`) or red (`unknown`), text visible, "View details" button opens popup with the verdict lines.

---

## Task 5 — First-session-load chat warning wiring in `Core.lua`

**File:** `Core.lua`

The chat warning is already emitted by `LootHistory.lua` Task 2.2 via a `C_Timer.After(6)` callback. Core.lua does not need additional wiring for the basic warning. However, the warning must survive the case where `LootHistory` is loaded but `Setup` fires before `PLAYER_ENTERING_WORLD` (i.e., the addon is loaded mid-session via `/reload`). The C_Timer approach handles this correctly since it runs on the next frame after 6 seconds regardless of event order.

No code change is required in `Core.lua` for the chat warning itself.

- [ ] 5.1 Confirm `Core.lua` `OnSlashCommand` schema-verdict output is complete (Task 3.1 already done). This task is a verification-only checkpoint.

**Verification:**
- `/reload` mid-session → 6 seconds later, if drift is detected, warning appears in chat exactly once.
- `/reload` again → `_driftWarnedThisSession` is reset by `Setup`; warning fires again if drift persists. (This is correct — "per session" means per addon load cycle, not "never again".)
- With healthy RC: no chat message.

---

## Task 6 — Manual drift simulation procedure (documentation)

**No code change.** This task documents the test procedure for simulating schema drift.

### Simulating schema drift for testing

1. Before the test, in-game: `/run BobleLootDB.profile.rcSchemaDetected = nil` to clear any cached verdict.

2. **Simulate `unknown` status (factionrealm key absent):**
   At the WoW console (or via a temp SavedVariables edit before login):
   ```lua
   -- In-game test shim (paste into a macro or /run):
   local orig = _G.RCLootCouncilLootDB
   _G.RCLootCouncilLootDB = { version = 99 }  -- factionrealm key missing
   local v = ns.LootHistory:DetectSchemaVersion(nil, BobleLoot)
   print("status:", v.status, "missing:", table.concat(v.missingFields, "; "))
   _G.RCLootCouncilLootDB = orig  -- restore
   ```
   Expected: `status: unknown   missing: RCLootCouncilLootDB.factionrealm`

3. **Simulate `degraded` status (per-entry field group missing):**
   ```lua
   local orig = _G.RCLootCouncilLootDB
   -- Build a minimal factionrealm with entries missing the "response" group
   _G.RCLootCouncilLootDB = {
       factionrealm = {
           ["Horde - Draenor"] = {
               ["TestChar-Realm"] = {
                   { date="22/04/26", lootWon="|cff...|Hsome item|h|r",
                     ilvl=639, id=12345 }
                   -- no "response" or "responseID" field
               }
           }
       }
   }
   local v = ns.LootHistory:DetectSchemaVersion(nil, BobleLoot)
   print("status:", v.status, "missing:", table.concat(v.missingFields, "; "))
   _G.RCLootCouncilLootDB = orig
   ```
   Expected: `status: degraded   missing: response (tried: response/responseID)`

4. After simulating drift, open Settings > Data tab → confirm banner appears in correct colour.
5. Run `/bl lootdb` → confirm schema verdict lines are printed.
6. Restore `_G.RCLootCouncilLootDB = orig` and `/reload` → confirm no banner, no chat warning.

---

## Manual Verification Checklist

### Happy path (healthy RC install)

- [ ] H1: `/reload` with a populated `RCLootCouncilLootDB.factionrealm` → no schema drift chat warning after 6 seconds.
- [ ] H2: `/bl lootdb` → prints `RC schema status: [green]ok[/green]`, correct source string, `All expected field groups present.`
- [ ] H3: Settings > Data tab → schema warning banner is hidden; info card at default position.
- [ ] H4: `/run print(BobleLootDB.profile.rcSchemaDetected.status)` → `ok`; `version` is a positive integer; `checkedAt` is within the last 60 seconds.
- [ ] H5: Second `/reload` → `version` is one higher than before (detection counter increments).

### Drift path (simulated via Task 6 procedure)

- [ ] D1: Inject `unknown` shim → `ns.LootHistory:DetectSchemaVersion` returns `status = "unknown"`.
- [ ] D2: With `unknown` status persisted, open Settings > Data tab → banner appears in red (`ns.Theme.danger`), text reads "RCLootCouncil schema mismatch — history may be incomplete."
- [ ] D3: Click "View details" → `StaticPopup` opens with status, check counter, RC version, source, and missing fields pre-filled; text is selectable.
- [ ] D4: Inject `degraded` shim → banner appears in amber (`ns.Theme.warning`).
- [ ] D5: With drift persisted, `/reload` → chat warning fires once, approximately 6 seconds after load.
- [ ] D6: Second `/reload` (drift still present) → chat warning fires again (one per session load — correct).
- [ ] D7: Restore healthy RC install, `/reload` → no banner, no chat warning.
- [ ] D8: `/bl lootdb` with `unknown` verdict → prints red status line, lists missing field groups.

### Edge cases

- [ ] E1: RC not installed at all (`_G.RCLootCouncilLootDB` is nil) → status = `unknown`, missing = `RCLootCouncilLootDB (top-level missing)`, chat warning fires; `/bl lootdb` prints correctly.
- [ ] E2: RC installed but history is genuinely empty (no entries) → status = `degraded`, missing = `no character entry arrays found (empty history?)`. Banner shows amber. This is expected and documented — an empty history on raid night one produces a degraded verdict.
- [ ] E3: `BobleLootDB.profile.rcSchemaDetected` is nil (first ever load) → `DetectSchemaVersion` handles `prev = nil` correctly; `version` starts at 1.
- [ ] E4: Settings > Data tab opened before 6-second timer fires → banner uses whatever the last stored verdict is (possibly nil → banner hidden). This is correct; a nil verdict means no detection has run yet.

---

## Schema Drift Taxonomy

### Shapes observed from RC over time

| Shape ID | RC version era | Description | BobleLoot impact |
|----------|---------------|-------------|-----------------|
| A (current) | RC 2.x, as of 2026-04 | `RCLootCouncilLootDB.factionrealm["Faction - Realm"]["Name-Realm"][N]` | Fully supported. All five field groups present. |
| A-partial | RC 2.x (older installs) | Shape A but some entries use `responseID` (number) instead of `response` (string) | Handled by `classify()` numeric fallback. Detection: `ok` because `responseID` is in the `response` group names list. |
| A-ilvl-missing | RC 2.x (early beta entries) | Shape A but per-entry `ilvl` field absent | Handled by `entryItemLevel()` fallback chain (link parsing). Detection: `degraded` (ilvl group missing). Loot history still functions; filter `lootMinIlvl > 0` skips unknown-ilvl items. |

### Future drift scenarios anticipated

| Drift type | Trigger | Expected status | Impact |
|------------|---------|----------------|--------|
| `factionrealm` key renamed | RC 3.x restructuring, per-spec storage | `unknown` | Full history drop. All players show nil history component. |
| Per-character key format change (e.g. `"Name"` without realm) | RC cross-realm update | `degraded` | Name-matching in `LH:Apply` fails silently; `matched = 0`. `/bl lootdb` will show 0 matched characters, which is a second signal. |
| Entry array replaced by hash/dict | RC storage optimisation | `degraded` (ipairs returns 0 entries) | `CountItemsReceived` silent zero. Detection will flag it if `#charEntries == 0` at sample time. |
| Entire SavedVar encrypted/opaque | (hypothetical RC 4.x) | `unknown` | Full history drop. Covered by Batch 4.8 version-compat matrix. |
| `lootWon` field renamed to `itemLink` | Already observed in some RC forks | `ok` (both in `item` group names list) | No impact — fallback resolver already covers this. |

### Relationship to Batch 4.8

Batch 4.8 (`[Cross]` RC version-compatibility matrix) will extend this foundation by adding a `KNOWN_RC_SHAPES` table keyed by `rcVersion` string, with field-path resolvers per version. At that point `DetectSchemaVersion` can cross-reference the detected RC version against the known-shapes table and produce a richer verdict (`tested_ok`, `tested_degraded`, `newer_than_tested`, `unsupported`). The `rcVersion` field stored by this plan's verdict is the hook that makes that upgrade straightforward.

---

## Coordination Notes

### 3B — Wasted-loot detection (also reads RC history)

Both 3B and 3C are read-only against `RCLootCouncilLootDB`. 3B's wasted-loot detection adds a `TRADE_CLOSED` hook that inspects live RC history entries and marks them 0-weight in BobleLoot's own accounting. When 3C's detection samples per-entry fields, it will encounter 3B's annotated entries if they have already been processed; this is harmless because 3B does not remove or rename any RC fields — it only reads them.

3B implementors: if 3B adds new fields to entries (e.g. `_bobleLootWasted = true`), these will not appear in `EXPECTED_ENTRY_FIELDS` and detection will ignore them, which is correct. Do not add BobleLoot-specific fields to RC's own SavedVariables; write them to `BobleLootDB` instead.

### 3E — Loot history viewer (depends on correct history reads)

3E's history viewer renders the data produced by `LH:Apply`. If drift is detected and `Apply` returns empty or partial results, the viewer's table will be empty or incomplete. The 3E plan should:
1. Check `BobleLootDB.profile.rcSchemaDetected.status` on viewer open.
2. If `status ~= "ok"`, render a banner at the top of the viewer table using the same text as the Settings panel banner: `"RCLootCouncil schema mismatch — history may be incomplete. Run /bl lootdb for details."`
3. Do not re-run detection from the viewer; read the stored verdict only.

This ensures the user sees a consistent message across both surfaces without introducing duplicate detection logic.

### 3D — Council UI (unrelated)

No coordination required. 3D does not read RC history.

### 3A — Python CI (unrelated)

No coordination required. 3A operates on the Python toolchain, not Lua runtime.

### Cross-cutting principle 10 (from the roadmap)

> RC coupling is explicit and detected. Every field read from `RCLootCouncilLootDB` or RC session entries has a documented expected shape and a logged fallback. Silent nil returns are never acceptable.

This plan is the direct implementation of that principle for `LootHistory.lua`. When adding new RC field reads in any future plan, update `EXPECTED_ENTRY_FIELDS` and document the fallback in the field group's `names` list.
