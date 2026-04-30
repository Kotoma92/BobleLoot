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
        -- Resolver contract: must NEVER error. RC's GetLootTable can throw
        -- mid-teardown, so isolate it.
        if not rcVoting.GetLootTable then return nil end
        local ok, lt = pcall(rcVoting.GetLootTable, rcVoting)
        if not ok or not lt or not lt[session] then return nil end
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
