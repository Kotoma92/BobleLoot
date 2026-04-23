# Batch 4C — RC Version Compatibility + Note Field Write Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce a versioned resolver matrix (`ns.RCCompat`) that adapts all RC field-path reads to the detected RC major version, and use the same resolver contract to write BobleLoot scores into RC's native per-candidate Note field on voting-frame open.

**Architecture:** `RCCompat.lua` (top-level, loaded before `VotingFrame.lua` and `LootFrame.lua`) defines a static `RESOLVER_MATRIX` table keyed by RC major version string, each entry holding function resolvers for every RC field-path BobleLoot touches. At addon-load time `RCCompat:Detect()` reads `_G.RCLootCouncil.version` (falling back to `LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil").version`), parses the major version, and stores the chosen resolver set in `ns.RCCompat.resolver`. `VotingFrame.lua` and `LootFrame.lua` replace their inline field-probe chains with calls to `ns.RCCompat.resolver.*`; `LootHistory.lua`'s fallback chains remain intact for now but gain an advisory comment pointing at the resolver. The Note-field write is a one-shot additive operation: on the first `UpdateScrollTable` pass per voting-session, if `candidate.note` is blank and the toggle is on, `resolver.writeCandidateNote(candidate, text)` is called — this shim encapsulates the version-specific write path so the caller stays clean. Batch 3C's schema-drift detection feeds resolver selection: a `degraded` or `unknown` verdict triggers the `fallback` resolver rather than a version-matched one.

**Tech Stack:** Lua (WoW 10.x), LibStub / AceAddon-3.0 for RC version detection

**Roadmap items covered:**

> **4.8 `[Cross]` RCLootCouncil version-compatibility matrix**
>
> Known-shape table keyed by RC major version, storing field-path
> resolvers for each RC version the addon has been tested against.
> Detected RC version (from `_G.RCLootCouncil.version`) selects the
> right resolver.
>
> Cross contract: data side owns the compatibility table; UI side
> renders a "Tested on RC %s, detected %s" line in the Settings panel's
> Data tab, coloured green on match, yellow on "newer than tested,"
> red on unsupported.

> **4.9 `[Cross]` Write score into RC candidate `Note` field**
>
> RC allows addons to pre-populate the per-candidate Note field. On
> voting frame open, write `note = tostring(score)` if the note is blank.
> Council members who don't run BobleLoot still see the number in RC's
> native Note column.
>
> Cross contract: data side computes; UI side writes the note via the
> existing `RCVotingFrame:UpdateScrollTable` hook.

**Dependencies:**
- Batch 1 hook paths: `TryHookRC()` in `Core.lua` (line 112–125), `VotingFrame:Hook(addon, RC)` in `VotingFrame.lua` (line 292–355), `LootFrame:Hook(addon, RC)` in `LootFrame.lua` (line 235–261). The resolver injects into these existing paths.
- Batch 3C (`LH:DetectSchemaVersion`): its verdict (`ok` / `degraded` / `unknown`) stored on `BobleLootDB.profile.rcSchemaDetected` feeds `RCCompat:Detect()` — a `degraded` or `unknown` verdict forces the `fallback` resolver regardless of version string match.
- Batch 3E Settings Panel Data tab: the "RC version" info line and "Write score into RC Note" toggle land in `UI/SettingsPanel.lua`'s `BuildDataTab`. Batch 3C's drift banner and Batch 4D's RC-not-detected banner also live there; layout coordination is documented in the coordination notes at the bottom of this plan.

---

## RC Version Detection — API Research

RCLootCouncil is loaded by the time `TryHookRC()` runs (either synchronously in `OnEnable` or via the `ADDON_LOADED` event). The version string is accessible via two paths:

```lua
-- Path A: direct field access (works in all known RC versions)
local version = _G.RCLootCouncil and _G.RCLootCouncil.version

-- Path B: AceAddon wrapper (equivalent; falls through if RC not an AceAddon)
local ok, RC = pcall(function()
    return LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil", true)
end)
local version = ok and RC and RC.version
```

`RCLootCouncil.version` is a string like `"3.14.1"`. RC does not expose a `GetVersion()` method; the `.version` field is the canonical surface used by RC itself in its own debug output and by third-party addons such as RCLootCouncil-Utils. Parse major version with `version:match("^(%d+)")`.

RC major versions in the wild:
- **v2.x** — older (pre-Shadowlands). Loot table stored in `RC.lootTable` (flat array). Candidate note accessed via `candidate.note` on the scroll-table row data directly.
- **v3.x** — current stable series (TWW). Loot table accessed via `rcVoting:GetLootTable()`. Candidate note stored as `candidate.note` on the row data; writing to it during `UpdateScrollTable` is the documented pattern used by RC's own "Officer Note" feature.
- **v4.x** — hypothetical next major (not yet released as of 2026-04-22). Documented as TODO in the resolver matrix; fallback resolver applies.

**Candidate Note write path (RC v3.x):** RC's voting frame stores per-candidate data in the scroll-table's `data` array. Each row has a `note` field. RC re-reads this field when rendering the Note column cell via its own `DoCellUpdate` for the Note column. Writing `candidate.note = text` before or during `UpdateScrollTable` propagates to the rendered cell without further RC calls needed — this is the same mechanism RC uses internally when a council member types in the Note field. The `writeCandidateNote` resolver shim for v3.x is therefore a simple assignment.

**Verification required in-game:** Confirm that assigning to `candidate.note` during `hooksecurefunc(rcVoting, "UpdateScrollTable", ...)` actually causes RC to re-render the cell, or whether the hook fires after RC has already read the value (in which case the write should happen in an earlier hook — see Task 5).

---

## File Structure

```
BobleLoot/
├── BobleLoot.toc                    [modify] — add RCCompat.lua before VotingFrame.lua
├── Core.lua                         [modify] — DB_DEFAULTS.profile.writeRCNote; /bl rcversion
├── RCCompat.lua                     [NEW]    — ns.RCCompat module, resolver matrix, Detect()
├── VotingFrame.lua                  [modify] — consult resolver for field reads; Note write
├── LootFrame.lua                    [modify] — consult resolver for field reads
├── LootHistory.lua                  [advisory comment only] — no logic changes
└── UI/
    └── SettingsPanel.lua            [modify] — Data tab: RC version info line + Note toggle
```

`RCCompat.lua` is placed at the top level (not `UI/`) because it is a data/correctness module shared by both `VotingFrame.lua`, `LootFrame.lua`, and `LootHistory.lua`. Placing it under `UI/` would imply it is a rendering concern; it is not. Load order in the `.toc` must be: `Core.lua` → `Scoring.lua` → `RCCompat.lua` → `VotingFrame.lua` → `LootFrame.lua`.

---

## Tasks

### Task 1 — Create `RCCompat.lua` with resolver matrix skeleton

- [ ] Create `E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/RCCompat.lua`

**Full file:**

```lua
--[[ RCCompat.lua
     RC version-compatibility matrix for BobleLoot.

     Provides ns.RCCompat:Detect(RC) which reads _G.RCLootCouncil.version,
     selects the best matching resolver from RESOLVER_MATRIX, and stores it
     as ns.RCCompat.resolver. All field-path reads from RCLootCouncil data
     structures must go through the resolver rather than inline probe chains.

     Extends Batch 3C's schema-drift detection: drift verdict 'degraded' or
     'unknown' forces the fallback resolver regardless of version match.

     To add support for a new RC major version:
       1. Add a new entry to RESOLVER_MATRIX keyed by the major-version string.
       2. Populate each field resolver function with the correct path for that
          RC version (consult RC's own CHANGELOG.md and SavedVariables schema).
       3. Update the TESTED_VERSIONS list so the Settings panel info line is
          accurate.
]]

local _, ns = ...
local RCCompat = {}
ns.RCCompat = RCCompat

-- Versions BobleLoot has been explicitly tested against. Used by the
-- Settings panel to colour the "Tested on RC %s, detected %s" info line.
-- Format: major-version string (the part before the first dot).
RCCompat.TESTED_VERSIONS = {
    ["2"] = true,   -- RC v2.x (Shadowlands / early Dragonflight)
    ["3"] = true,   -- RC v3.x (TWW, current stable)
    -- ["4"] = true -- TODO: populate when RC v4.x releases
}

-- ============================================================
-- Resolver matrix
-- Each entry provides function resolvers for every RC data-path
-- BobleLoot reads or writes. A resolver must NEVER error — it
-- should return nil on missing data rather than throwing.
-- ============================================================

local RESOLVER_MATRIX = {}

-- -------------------------------------------------------
-- RC v2.x resolver
-- Loot table in RC.lootTable (flat array, session = index).
-- GetLootTable() may not exist; access rc.lootTable directly.
-- Candidate note: candidate.note (direct field, same as v3).
-- -------------------------------------------------------
RESOLVER_MATRIX["2"] = {
    name = "rc-v2",

    -- Returns the itemID for a given session index.
    -- RC v2: loot table is rc.lootTable[session], fields: link, id.
    sessionItemID = function(rcVoting, session)
        local lt = rawget(rcVoting, "lootTable")
        if not lt or not lt[session] then return nil end
        local entry = lt[session]
        if entry.link then
            local id = tonumber(entry.link:match("item:(%d+)"))
            if id then return id end
        end
        return entry.id or entry.itemID
    end,

    -- Returns the itemID stored on an RC loot-entry row (used in
    -- LootFrame's entryItemID helper).
    lootEntryItemID = function(entry)
        if not entry then return nil end
        local function fromAny(v)
            if type(v) == "number" then return v end
            if type(v) == "string" then
                local id = tonumber(v:match("item:(%d+)"))
                if id then return id end
            end
        end
        return fromAny(entry.link)
            or fromAny(entry.itemLink)
            or fromAny(entry.id)
            or fromAny(entry.itemID)
    end,

    -- Returns the timestamp for an RC loot-history entry.
    -- RC v2: entry.time (Unix number) or entry.date (string "d/m/y").
    lootEntryTimestamp = function(entry)
        local t = entry.time or entry.timestamp
        if type(t) == "number" then return t end
        local d, m, y = (entry.date or ""):match("^(%d+)/(%d+)/(%d+)$")
        if d then
            return time({ day = tonumber(d), month = tonumber(m),
                          year = 2000 + tonumber(y) })
        end
        return nil
    end,

    -- Returns the item level for an RC loot-history entry.
    lootEntryIlvl = function(entry)
        local v = entry.ilvl or entry.itemLevel or entry.iLvl or entry.lvl
        if type(v) == "number" and v > 0 then return v end
        if type(v) == "string" then
            local n = tonumber(v:match("(%d+)"))
            if n and n > 0 then return n end
        end
        -- RC v2 sometimes stores ilvl in the link; fall back to API.
        local link = entry.lootWon or entry.link or entry.itemLink
        if type(link) == "string" and GetDetailedItemLevelInfo then
            local ilvl = GetDetailedItemLevelInfo(link)
            if type(ilvl) == "number" and ilvl > 0 then return ilvl end
        end
        return nil
    end,

    -- Returns the factionrealm key used by RCLootCouncilLootDB.
    -- RC v2: stored as RCLootCouncilLootDB.factionrealm["Faction - Realm"].
    -- Detection logic is identical to v3; resolver is a no-op passthrough.
    factionRealmKey = function(db)
        -- db is already the merged flat name->entries map from LootHistory.
        return db
    end,

    -- Writes BobleLoot score into the candidate's Note field.
    -- RC v2: candidate.note is a direct field on the scroll-table row.
    writeCandidateNote = function(candidate, text)
        if type(candidate) == "table" and (candidate.note == nil or candidate.note == "") then
            candidate.note = text
        end
    end,
}

-- -------------------------------------------------------
-- RC v3.x resolver (current stable, TWW)
-- GetLootTable() available. Candidate note: candidate.note.
-- -------------------------------------------------------
RESOLVER_MATRIX["3"] = {
    name = "rc-v3",

    sessionItemID = function(rcVoting, session)
        local lt = rcVoting.GetLootTable and rcVoting:GetLootTable()
        if not lt or not lt[session] then return nil end
        local entry = lt[session]
        if entry.link then
            local id = tonumber(entry.link:match("item:(%d+)"))
            if id then return id end
        end
        return entry.id or entry.itemID
    end,

    lootEntryItemID = function(entry)
        if not entry then return nil end
        local function fromAny(v)
            if type(v) == "number" then return v end
            if type(v) == "string" then
                local id = tonumber(v:match("item:(%d+)"))
                if id then return id end
            end
        end
        return fromAny(entry.link)
            or fromAny(entry.itemLink)
            or fromAny(entry.item and entry.item.link)
            or fromAny(entry.session and entry.session.link)
            or fromAny(entry.itemID)
            or fromAny(entry.id)
    end,

    lootEntryTimestamp = function(entry)
        local t = entry.time or entry.timestamp
        if type(t) == "number" then return t end
        -- RC v3 also uses "d/m/y" date strings and ISO-like strings.
        local d, m, y = (entry.date or ""):match("^(%d+)/(%d+)/(%d+)$")
        if d then
            return time({ day = tonumber(d), month = tonumber(m),
                          year = 2000 + tonumber(y) })
        end
        local Y, M, D, h, mi, s = (entry.date or ""):match(
            "^(%d+)-(%d+)-(%d+)%s+(%d+):(%d+):(%d+)$")
        if Y then
            return time({ year = tonumber(Y), month = tonumber(M),
                          day = tonumber(D), hour = tonumber(h),
                          min = tonumber(mi), sec = tonumber(s) })
        end
        return nil
    end,

    lootEntryIlvl = function(entry)
        local v = entry.ilvl or entry.itemLevel or entry.iLvl or entry.lvl
        if type(v) == "number" and v > 0 then return v end
        if type(v) == "string" then
            local n = tonumber(v:match("(%d+)"))
            if n and n > 0 then return n end
        end
        local link = entry.lootWon or entry.link or entry.itemLink or entry.string
        if type(link) == "string" and GetDetailedItemLevelInfo then
            local ilvl = GetDetailedItemLevelInfo(link)
            if type(ilvl) == "number" and ilvl > 0 then return ilvl end
        end
        return nil
    end,

    factionRealmKey = function(db)
        return db
    end,

    writeCandidateNote = function(candidate, text)
        if type(candidate) == "table" and (candidate.note == nil or candidate.note == "") then
            candidate.note = text
        end
    end,
}

-- -------------------------------------------------------
-- Fallback resolver — used when RC version is unknown or
-- schema-drift detection returned 'degraded'/'unknown'.
-- Attempts all known field paths in order; maximally defensive.
-- -------------------------------------------------------
local FALLBACK_RESOLVER = {
    name = "fallback",

    sessionItemID = function(rcVoting, session)
        -- Try v3 path first, then v2.
        local lt = (rcVoting.GetLootTable and rcVoting:GetLootTable())
                   or rawget(rcVoting, "lootTable")
        if not lt or not lt[session] then return nil end
        local entry = lt[session]
        if entry.link then
            local id = tonumber(entry.link:match("item:(%d+)"))
            if id then return id end
        end
        return entry.id or entry.itemID
    end,

    lootEntryItemID = function(entry)
        if not entry then return nil end
        local function fromAny(v)
            if type(v) == "number" then return v end
            if type(v) == "string" then
                local id = tonumber(v:match("item:(%d+)"))
                if id then return id end
            end
        end
        return fromAny(entry.link)
            or fromAny(entry.itemLink)
            or fromAny(entry.item and entry.item.link)
            or fromAny(entry.session and entry.session.link)
            or fromAny(entry.itemID)
            or fromAny(entry.id)
    end,

    lootEntryTimestamp = function(entry)
        local t = entry.time or entry.timestamp
        if type(t) == "number" then return t end
        local d, m, y = (entry.date or ""):match("^(%d+)/(%d+)/(%d+)$")
        if d then
            return time({ day = tonumber(d), month = tonumber(m),
                          year = 2000 + tonumber(y) })
        end
        local Y, M, D, h, mi, s = (entry.date or ""):match(
            "^(%d+)-(%d+)-(%d+)%s+(%d+):(%d+):(%d+)$")
        if Y then
            return time({ year = tonumber(Y), month = tonumber(M),
                          day = tonumber(D), hour = tonumber(h),
                          min = tonumber(mi), sec = tonumber(s) })
        end
        return nil
    end,

    lootEntryIlvl = function(entry)
        local v = entry.ilvl or entry.itemLevel or entry.iLvl or entry.lvl
        if type(v) == "number" and v > 0 then return v end
        if type(v) == "string" then
            local n = tonumber(v:match("(%d+)"))
            if n and n > 0 then return n end
        end
        local link = entry.lootWon or entry.link or entry.itemLink or entry.string
        if type(link) == "string" and GetDetailedItemLevelInfo then
            local ilvl = GetDetailedItemLevelInfo(link)
            if type(ilvl) == "number" and ilvl > 0 then return ilvl end
        end
        return nil
    end,

    factionRealmKey = function(db) return db end,

    writeCandidateNote = function(candidate, text)
        if type(candidate) == "table" and (candidate.note == nil or candidate.note == "") then
            candidate.note = text
        end
    end,
}

-- ============================================================
-- Public API
-- ============================================================

-- Called from TryHookRC() (Core.lua) after RC is confirmed present.
-- Reads RC version, selects resolver, stores detection metadata.
-- `schemaVerdict` is the string returned by LH:DetectSchemaVersion()
-- (Batch 3C): "ok" | "degraded" | "unknown" | nil.
function RCCompat:Detect(RC, schemaVerdict)
    -- Read version string.
    local rawVersion = (RC and RC.version)
        or (_G.RCLootCouncil and _G.RCLootCouncil.version)
        or nil

    self.detectedVersion = rawVersion or "unknown"
    self.majorVersion    = rawVersion and rawVersion:match("^(%d+)") or nil

    -- If schema-drift detection returned a degraded verdict, fall back
    -- regardless of version string — the table shape is unreliable.
    if schemaVerdict == "degraded" or schemaVerdict == "unknown" then
        self.resolver          = FALLBACK_RESOLVER
        self.resolverReason    = "schema-drift verdict: " .. (schemaVerdict or "nil")
        self.resolverMatchType = "fallback"
        return
    end

    -- Version-matched resolver.
    if self.majorVersion and RESOLVER_MATRIX[self.majorVersion] then
        self.resolver          = RESOLVER_MATRIX[self.majorVersion]
        self.resolverReason    = "matched major version " .. self.majorVersion
        self.resolverMatchType = self.TESTED_VERSIONS[self.majorVersion]
            and "tested" or "untested-major"
        return
    end

    -- Unknown version but no drift warning: use fallback.
    self.resolver          = FALLBACK_RESOLVER
    self.resolverReason    = "no resolver for version: " .. self.detectedVersion
    self.resolverMatchType = "fallback"
end

-- Returns the active resolver table. Callers should cache the return
-- value at hook-time rather than calling GetResolver() per-frame.
function RCCompat:GetResolver()
    return self.resolver or FALLBACK_RESOLVER
end

-- Diagnostic string for /bl rcversion and the Settings panel info line.
-- Returns: detectedVersion, resolverName, resolverReason, matchType
function RCCompat:GetStatus()
    return
        self.detectedVersion  or "not detected",
        self.resolver and self.resolver.name or "fallback",
        self.resolverReason   or "Detect() not yet called",
        self.resolverMatchType or "unknown"
end
```

Verification:
- `/reload` with RC loaded. No Lua errors. `ns.RCCompat` is present in global namespace via `_G.BobleLoot` access or inline check.

---

### Task 2 — Update `BobleLoot.toc` load order

- [ ] Edit `BobleLoot.toc` to add `RCCompat.lua` between `Scoring.lua` and `VotingFrame.lua`.

Current relevant section (lines 16–20 in `BobleLoot.toc`):
```
Core.lua
Scoring.lua
Config.lua
Sync.lua
VotingFrame.lua
LootFrame.lua
```

Change to:
```
Core.lua
Scoring.lua
Config.lua
Sync.lua
RCCompat.lua
VotingFrame.lua
LootFrame.lua
```

The `Config.lua` reference remains until Batch 1E's SettingsPanel replaces it; `RCCompat.lua` simply slots in before the frame hooks.

Verification:
- `/reload` with RC loaded. Check no "undefined global" errors for `ns.RCCompat` in `VotingFrame.lua`.

---

### Task 3 — Wire `RCCompat:Detect()` into `TryHookRC()` and add `/bl rcversion`

- [ ] Edit `Core.lua`

**Changes:**

**3a. Add `writeRCNote` to `DB_DEFAULTS.profile`.**

Inside `DB_DEFAULTS`, after the existing `historyCap = 5,` line, add:

```lua
        -- RC Note field integration (item 4.9).
        writeRCNote = true,
```

**3b. Call `RCCompat:Detect()` inside `TryHookRC()`.**

Replace the existing `TryHookRC` function:

```lua
function BobleLoot:TryHookRC()
    local ok, RC = pcall(function()
        return LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil", true)
    end)
    if not ok or not RC then return false end

    -- Initialise the version-compat resolver before any frame hooks run.
    -- Pass the schema-drift verdict from Batch 3C (nil if 3C not yet shipped).
    if ns.RCCompat and ns.RCCompat.Detect then
        local schemaVerdict = self.db and self.db.profile
            and self.db.profile.rcSchemaDetected or nil
        ns.RCCompat:Detect(RC, schemaVerdict)
    end

    local hookedAny = false
    if ns.VotingFrame and ns.VotingFrame.Hook then
        if ns.VotingFrame:Hook(self, RC) then hookedAny = true end
    end
    if ns.LootFrame and ns.LootFrame.Hook then
        if ns.LootFrame:Hook(self, RC) then hookedAny = true end
    end
    return hookedAny
end
```

**3c. Add `/bl rcversion` slash subcommand.**

In `OnSlashCommand`, before the final `else` branch, add:

```lua
    elseif input == "rcversion" then
        if ns.RCCompat then
            local detected, resolverName, reason, matchType = ns.RCCompat:GetStatus()
            self:Print(string.format(
                "RC detected version: %s | resolver: %s | match: %s | reason: %s",
                detected, resolverName, matchType, reason))
        else
            self:Print("RCCompat module not loaded.")
        end
```

Also update the usage string at the bottom of `OnSlashCommand`:

```lua
    else
        self:Print("Commands: /bl config | /bl version | /bl rcversion | /bl broadcast | /bl transparency on|off | /bl checkdata | /bl lootdb | /bl debugchar <Name-Realm> | /bl test [N] | /bl score <itemID> <Name-Realm>")
    end
```

Verification:
- `/reload` with RC present. Run `/bl rcversion`. Should print detected version (e.g. `3.14.1`), resolver `rc-v3`, match `tested`.
- Simulate unknown RC version by running `/run _G.RCLootCouncil.version = "99.99.99"` then `/bl rcversion` — should show `fallback` resolver. (Full simulation requires a fresh load; this tests the readout path only.)

---

### Task 4 — Update `VotingFrame.lua` to use resolver for field reads

- [ ] Edit `VotingFrame.lua`

**Changes:**

**4a. Cache resolver at hook time.**

In `VF:Hook(addon, RC)`, after the line `self.rcVoting = rcVoting`, add:

```lua
    self.resolver = ns.RCCompat and ns.RCCompat:GetResolver() or nil
```

**4b. Replace `getItemIDForSession` with resolver-backed version.**

Replace the existing `getItemIDForSession` local function:

```lua
-- Pull the current itemID for a session using the version-compat resolver.
local function getItemIDForSession(rcVoting, session)
    local resolver = VF.resolver
    if resolver and resolver.sessionItemID then
        local ok, id = pcall(resolver.sessionItemID, rcVoting, session)
        if ok and id then return id end
    end
    -- Fallback: inline probe for safety during early startup before Detect().
    local lt = (rcVoting.GetLootTable and rcVoting:GetLootTable())
               or rawget(rcVoting, "lootTable")
    if not lt or not lt[session] then return nil end
    local entry = lt[session]
    if entry.link then
        local id = tonumber(entry.link:match("item:(%d+)"))
        if id then return id end
    end
    return entry.id or entry.itemID
end
```

No other `VotingFrame.lua` field-probe chains need replacement in this batch — `bidderNames`, `simReferenceFor`, and `historyReferenceFor` read from `data.characters` (BobleLoot's own dataset), not from RC structures. The resolver's `sessionItemID` is the only RC structure VotingFrame touches directly (besides the frame hook mechanics).

Verification:
- Open RC voting frame in a test session. Score column populates normally. No Lua errors.

---

### Task 5 — Note field write in `VotingFrame.lua`

- [ ] Edit `VotingFrame.lua`

**Architecture note — hook timing:** RC's `UpdateScrollTable` reads candidate row data to populate columns, including the Note column. Writing to `candidate.note` must happen *before* RC's own `UpdateScrollTable` executes, not inside a `hooksecurefunc` post-hook (which runs after RC has already read the value and rendered). The correct hook point is `OpenFrame` or `StartVotingSession` — whichever RC method runs as the voting frame first becomes visible for a session. In RC v3.x the method is `rcVoting:Open(session)` or `rcVoting:StartSession(session)`. Use `hooksecurefunc(rcVoting, "Open", ...)` as the primary hook; if that method does not exist in the running RC version, fall back to `UpdateScrollTable` (noting that in this case the write will take effect on the *second* render cycle, not the first — acceptable but suboptimal).

**5a. Track per-session Note-write state.**

Add a module-level variable at the top of `VotingFrame.lua`, after `local SCORE_COL = "blScore"`:

```lua
-- Tracks which sessions have had Notes written this instance so we
-- write once per session, not on every scroll update.
local _noteWrittenForSession = {}
```

**5b. Add `writeNotesForSession` helper.**

Add this function before `VF:Hook`:

```lua
-- Writes BobleLoot scores into blank RC candidate Note fields for the
-- given session. Called once per session on frame open. Skips candidates
-- whose Note is already non-empty (human-typed notes must not be clobbered).
local function writeNotesForSession(rcVoting, addon, session)
    local resolver = VF.resolver
    if not resolver or not resolver.writeCandidateNote then return end
    local profile = addon.db and addon.db.profile
    if not profile or not profile.writeRCNote then return end

    local itemID = getItemIDForSession(rcVoting, session)
    if not itemID then return end

    -- Walk the scroll-table data to find all candidate rows.
    local st = rcVoting.frame and rcVoting.frame.st
    local tableData = st and st.data
    if not tableData then return end

    local names = {}
    for _, row in ipairs(tableData) do
        if row.name then names[#names + 1] = row.name end
    end

    -- Compute sim/history references once for the whole session.
    local simRef  = simReferenceFor(addon, itemID, names)
    local histRef = historyReferenceFor(addon, names)

    for _, row in ipairs(tableData) do
        if row.name then
            local score = computeScoreForRow(rcVoting, addon, session,
                                             row.name, simRef, histRef)
            if score then
                local text = string.format("BL=%d", math.floor(score + 0.5))
                -- writeCandidateNote is a no-op if row.note is non-empty.
                resolver.writeCandidateNote(row, text)
            end
        end
    end
end
```

**5c. Hook `Open` (or `StartSession`) in `VF:Hook`.**

Inside `VF:Hook`, after the `self.hooked = true` line and before the `return true`:

```lua
    -- Hook the frame-open method to write Notes once per session.
    -- RC v3.x uses "Open"; v2.x may use "StartSession". Try both.
    local function onSessionOpen(_, session)
        session = session or (rcVoting.GetCurrentSession and rcVoting:GetCurrentSession())
                             or rcVoting.session
        if not session then return end
        if _noteWrittenForSession[session] then return end
        _noteWrittenForSession[session] = true
        -- Defer by one frame so RC has populated the scroll table first.
        C_Timer.After(0, function()
            writeNotesForSession(rcVoting, addon, session)
        end)
    end

    for _, methodName in ipairs({ "Open", "StartSession", "UpdateScrollTable" }) do
        if type(rcVoting[methodName]) == "function" then
            hooksecurefunc(rcVoting, methodName, onSessionOpen)
            break  -- hook only the first one found
        end
    end

    -- Reset per-session tracking when the voting frame closes.
    if type(rcVoting.CloseFrame) == "function" then
        hooksecurefunc(rcVoting, "CloseFrame", function()
            _noteWrittenForSession = {}
        end)
    end
```

**Implementation note on hook order:** The `break` after the first matched method means only one hook is installed. If `Open` exists, it is used (runs before scroll population). If only `UpdateScrollTable` is found, the one-frame `C_Timer.After(0, ...)` defer inside `onSessionOpen` ensures the write happens after RC's own `UpdateScrollTable` call completes its first pass, so the note becomes visible on the second render. If RC triggers a second `UpdateScrollTable` immediately (e.g. from a scroll event), `_noteWrittenForSession[session]` guard prevents double-write.

Verification:
- Open RC voting frame with `/bl test 1` → confirm candidates with blank Notes gain `BL=74` (or appropriate score) in the Note column.
- Open RC voting frame with a candidate who already has a non-blank note → confirm that note is unchanged.
- Toggle `/bl config` → Data tab → "Write score into RC Note field" off → open voting frame → confirm no notes are written.

---

### Task 6 — Update `LootFrame.lua` to use resolver for field reads

- [ ] Edit `LootFrame.lua`

**Changes:**

**6a. Cache resolver at hook time.**

In `LF:Hook(addon, RC)`, after `self.lootFrame = lootFrame`, add:

```lua
    self.resolver = ns.RCCompat and ns.RCCompat:GetResolver() or nil
```

**6b. Replace `entryItemID` with resolver-backed version.**

Replace the existing `entryItemID` local function:

```lua
local function entryItemID(entry)
    local resolver = LF.resolver
    if resolver and resolver.lootEntryItemID then
        local ok, id = pcall(resolver.lootEntryItemID, entry)
        if ok and id then return id end
    end
    -- Inline fallback (identical to FALLBACK_RESOLVER.lootEntryItemID).
    if not entry then return nil end
    local function fromAny(v)
        if type(v) == "number" then return v end
        if type(v) == "string" then
            local id = tonumber(v:match("item:(%d+)"))
            if id then return id end
        end
    end
    return fromAny(entry.link)
        or fromAny(entry.itemLink)
        or fromAny(entry.item and entry.item.link)
        or fromAny(entry.session and entry.session.link)
        or fromAny(entry.itemID)
        or fromAny(entry.id)
end
```

The `forEachEntry` iteration structure and the `renderEntry` logic do not read RC structures directly (they read from `addon:GetData()` and the synced `_leaderScores`), so no further changes are needed in `LootFrame.lua`.

Verification:
- Enable transparency mode. Open RC loot frame. Confirm score label renders. No Lua errors.

---

### Task 7 — Add advisory comment to `LootHistory.lua`

- [ ] Edit `LootHistory.lua` — documentation only, no logic changes.

At the top of the `entryItemLevel` function (line 40), add a comment:

```lua
-- NOTE (Batch 4C): The resolver equivalent for this function is
-- ns.RCCompat:GetResolver().lootEntryIlvl. LootHistory.lua retains its
-- own inline fallback chain because it runs before VotingFrame/LootFrame
-- hooks are established and operates on the SavedVariables DB rather than
-- live session data. If RC changes its ilvl field name in a future major
-- version, update both here and in RESOLVER_MATRIX (RCCompat.lua).
```

Similarly, at the top of `entryTime` (line 190):

```lua
-- NOTE (Batch 4C): Resolver equivalent: ns.RCCompat:GetResolver().lootEntryTimestamp.
-- Kept in sync with RCCompat.lua RESOLVER_MATRIX manually.
```

Verification:
- Read only; no functional change. Confirm no Lua errors after save.

---

### Task 8 — Settings panel: Data tab additions (`UI/SettingsPanel.lua`)

This task assumes Batch 1E's `UI/SettingsPanel.lua` exists. If Batch 1E has not shipped yet, these additions are staged as a pending diff to be applied once the file exists.

- [ ] Edit `UI/SettingsPanel.lua` — `BuildDataTab` function

**8a. "Write score into RC Note field" toggle.**

Inside `BuildDataTab`, after the existing transparency toggle block, add:

```lua
    -- RC Note field write toggle (item 4.9)
    local noteToggle = MakeToggle(dataContent, {
        label   = "Write score into RC Note field",
        tooltip = "When enabled, BobleLoot writes 'BL=<score>' into the"
               .. " per-candidate Note field when the RC voting frame opens."
               .. " Only fills blank notes — human-typed notes are never"
               .. " overwritten. Disable for councils that use Note for"
               .. " pure text.",
        get     = function() return addon.db.profile.writeRCNote ~= false end,
        set     = function(_, val) addon.db.profile.writeRCNote = val end,
        width   = 340,
    })
    noteToggle:SetPoint("TOPLEFT", transparencyToggle, "BOTTOMLEFT", 0, -8)
```

(Adjust anchor to whatever widget precedes it in the actual tab builder.)

**8b. "RC version" info line.**

After the toggle, add an info line that reads from `ns.RCCompat:GetStatus()`:

```lua
    -- RC version info line (item 4.8)
    local rcVersionLine = dataContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rcVersionLine:SetPoint("TOPLEFT", noteToggle, "BOTTOMLEFT", 0, -12)
    rcVersionLine:SetWidth(480)
    rcVersionLine:SetJustifyH("LEFT")
    rcVersionLine:SetWordWrap(false)

    -- Refresh the info line on every tab-show so it reflects post-load state.
    local rcVersionCard = MakeSection(dataContent, "RC Compatibility")
    rcVersionCard:HookScript("OnShow", function()
        if not ns.RCCompat then
            rcVersionLine:SetText("|cffff5555RCCompat module not loaded.|r")
            return
        end
        local detected, resolverName, _, matchType = ns.RCCompat:GetStatus()
        local testedList = {}
        for v in pairs(ns.RCCompat.TESTED_VERSIONS) do
            testedList[#testedList + 1] = "v" .. v .. ".x"
        end
        table.sort(testedList)
        local testedStr = table.concat(testedList, ", ")

        local colorCode
        if matchType == "tested" then
            colorCode = "|cff40ff40"      -- green: version is in TESTED_VERSIONS
        elseif matchType == "untested-major" then
            colorCode = "|cffffd040"      -- yellow: newer than tested
        else
            colorCode = "|cffff5050"      -- red: unknown / fallback
        end

        rcVersionLine:SetText(string.format(
            "%sTested on RC %s, detected %s (resolver: %s)|r",
            colorCode, testedStr, detected, resolverName))
    end)
```

**Layout stack in Data tab (all four adjacent banners, top to bottom):**
1. Batch 3C schema-drift warning banner (red, hidden when verdict is `ok`)
2. Batch 4C RC version info line (green / yellow / red based on match type)
3. Batch 4C "Write score into RC Note field" toggle
4. Batch 4D RC-not-detected warning banner (shown only when RC is absent)

The 3C banner and 4D banner are conditionally visible; the 4C info line and toggle are always rendered. Vertical spacing between items: 8px.

Verification:
- Open Settings → Data tab with RC v3.x loaded → info line shows green "Tested on RC v2.x, v3.x, detected 3.14.1 (resolver: rc-v3)".
- Disable RC, `/reload` → info line shows red "detected unknown".
- Toggle the Note toggle off, `/reload`, reopen → toggle remains unchecked.

---

### Task 9 — End-to-end verification and commit

- [ ] Verify all scenarios listed in the manual verification checklist below.
- [ ] Run `luacheck` if available in the environment.
- [ ] Commit with message:

```
feat: add RCCompat resolver matrix and RC Note field write (items 4.8, 4.9)

Introduces RCCompat.lua with a RESOLVER_MATRIX keyed by RC major version
(v2.x and v3.x covered; fallback for unknown versions). TryHookRC() calls
RCCompat:Detect() before hooking frames; VotingFrame and LootFrame use
the resolver for RC field reads. On voting-frame open, writes "BL=<score>"
into blank candidate Note fields (guarded by writeRCNote profile toggle).
Settings panel Data tab gains RC version info line (green/yellow/red) and
the Note-write toggle. /bl rcversion prints detected version and resolver.
```

---

## Manual Verification Checklist

### Scenario A — Normal load with RC present

- [ ] `/reload` with RC 3.x loaded.
- [ ] No Lua errors (test with `/console scriptErrors 1`).
- [ ] `/bl rcversion` prints: detected version matching RC's actual version, resolver `rc-v3`, match type `tested`.
- [ ] Open RC voting frame for any item. Score column populates as before.
- [ ] Inspect candidate Note column. Candidates with blank notes show `BL=<score>`. Candidates who had typed notes (if any) are unchanged.
- [ ] `/bl config` → Data tab. RC version info line shows green with correct detected version and tested range.

### Scenario B — Unknown RC version simulation

- [ ] `/run _G.RCLootCouncil.version = "99.99.99"` (must be done before `TryHookRC` fires; easiest with a fresh load by editing the override into `OnEnable` temporarily).
- [ ] `/bl rcversion` shows detected version `99.99.99`, resolver `fallback`, match type `fallback`.
- [ ] Score column still renders; scoring is unaffected (resolver fallback covers all field paths).
- [ ] Settings panel Data tab info line shows yellow or red (implementation will show red for `fallback` match type; adjust color logic to yellow for "newer than tested" if the major version is numeric and greater than all entries in `TESTED_VERSIONS`).

### Scenario C — Note field write behaviour

- [ ] Open RC voting frame (with `writeRCNote = true` in profile).
- [ ] All candidates with blank notes gain `BL=<N>` in Note column.
- [ ] A candidate whose note was pre-typed (e.g. "check logs") is untouched.
- [ ] Close and reopen the voting frame for the same session → notes remain; no duplicate writes.
- [ ] Toggle "Write score into RC Note field" off in Settings.
- [ ] Open a new voting frame session → no scores appear in Note column.

### Scenario D — Schema-drift interlock (Batch 3C present)

- [ ] If Batch 3C's `LH:DetectSchemaVersion` is available and returns `degraded` (simulate by removing the `factionrealm` key from `_G.RCLootCouncilLootDB`): `/bl rcversion` shows `fallback` resolver and reason includes `schema-drift verdict: degraded`.
- [ ] Scoring still works via the fallback resolver's field-probe chains.

### Scenario E — `writeRCNote = false` persists across reloads

- [ ] Toggle off in Settings. `/reload`. `/bl config` → Data tab → toggle is unchecked.
- [ ] Open voting frame → Note column untouched.

---

## Resolver Matrix Sample

The table below documents what is known from the RC changelog and codebase (RC is open-source on GitHub at `RCLootCouncil/RCLootCouncil`). Fields marked TODO require verification against the actual RC source at implementation time.

| RC Major Version | `sessionItemID` path | `lootEntryIlvl` path | `lootEntryTimestamp` path | `writeCandidateNote` path | Notes |
|---|---|---|---|---|---|
| **v2.x** (e.g. 2.22.x) | `rc.lootTable[session].link / .id` | `entry.ilvl / .itemLevel / .iLvl` | `entry.time` (Unix number) or `entry.date` (`d/m/y`) | `candidate.note = text` direct assignment | GetLootTable() may not exist; use `rawget(rcVoting, "lootTable")`. TODO: verify exact field names from RC 2.x tag. |
| **v3.x** (e.g. 3.14.x) | `rcVoting:GetLootTable()[session].link / .id` | `entry.ilvl / .itemLevel / .string` (via `GetDetailedItemLevelInfo` fallback) | `entry.time` (Unix) or `entry.date` (ISO or `d/m/y`) | `candidate.note = text` direct assignment | GetLootTable() confirmed in RC 3.x source. TODO: verify `entry.string` field name (RC may call it `.lootWon`). |
| **v4.x** | TODO: populate from RC CHANGELOG.md when v4.x releases | TODO | TODO | TODO | Fallback resolver applies until this row is populated. |

**TODO for executor before shipping:** Pull RC's Git history for the field-name changes between 2.x and 3.x and fill in the exact names. The RC repository tag `v2.22.0` and `v3.14.0` are the reference points. Look specifically at `RCLootCouncil/Modules/VotingFrame.lua` (scroll-table data population) and `RCLootCouncil/Modules/History.lua` (loot entry shape) in each tag.

---

## Coordination Notes

### 3C Schema-drift feed → 4.8 resolver selection

Batch 3C adds `LH:DetectSchemaVersion(db)` which writes a verdict string (`ok` / `degraded` / `unknown`) to `BobleLootDB.profile.rcSchemaDetected`. Task 3b of this plan reads that field inside `TryHookRC()` and passes it to `RCCompat:Detect()`. If Batch 3C has not shipped yet, `schemaVerdict` is `nil` and `Detect()` proceeds purely on version-string matching — functionally identical to the pre-3C behaviour. No hard dependency; graceful degradation.

When Batch 3C ships it should also call `ns.RCCompat:Detect(RC, verdict)` after updating `rcSchemaDetected`, or trigger a `BobleLoot_RCSchemaDetected` event that `Core.lua` handles by re-calling `TryHookRC()`. The simpler path: `LH:DetectSchemaVersion` writes the verdict and `Core.lua`'s `TryHookRC()` reads it at hook-time — since `LH:Setup` fires before `TryHookRC` completes (both called from `OnEnable`), ordering is naturally correct as long as `LH:Setup` does its synchronous schema check before the C_Timer.After(5) async apply. Confirm with Batch 3C implementer.

### 3E Data tab layout → 4.8 info line and 4.9 toggle

Batch 3E (Settings panel) defines `BuildDataTab` with sections for: dataset info, broadcast, transparency, WoWAudit link. This plan adds two new elements at the bottom of that section: the RC version info line and the Note-write toggle. Task 8 anchors both to the transparency toggle as the reference widget. If Batch 3E's transparency toggle uses a different variable name, adjust the anchor in Task 8. The layout stack (3C drift banner → 4C version line → 4C Note toggle → 4D RC-not-detected banner) should be coordinated with the Batch 1E / 3E implementer so the vertical ordering and 8px gap convention are respected.

### 4D RC-not-detected banner → 4.8/4.9 placement

Batch 4D (item 4.10) adds a banner in the Data tab when RC is absent after a 10-second grace period. That banner is a separate condition from "RC present but unknown version" (this plan's red info line). The two must not overlap:
- RC absent → 4D banner shown; 4C info line shows "not detected" in red; Note toggle is visible but irrelevant.
- RC present, unknown version → 4D banner hidden; 4C info line shows red "fallback resolver"; Note toggle functional.
- RC present, known version → 4D banner hidden; 4C info line shows green; Note toggle functional.

The 4D implementer should check `ns.RCCompat and ns.RCCompat.detectedVersion ~= "not detected"` to decide whether to show the 4D banner, or retain the existing 10-second timer check — both are acceptable; avoid duplicating the detection logic.

### 4E empty/error states audit → "unknown RC version" state

Item 4.12 audits every UI surface for designed empty/error states. The "unknown RC version" state introduced by this plan is a new surface that 4E must include in its audit pass:
- Score cell: unaffected — resolver fallback covers all field reads, score column renders normally.
- Settings panel Data tab info line: red text "detected 99.99.99 (resolver: fallback)" — this IS the designed error state for unknown version. 4E should verify this renders and is not accidentally blank.
- `/bl rcversion` output: designed to always print something (see Task 3c); 4E should add this to its slash-command error-state checklist.
