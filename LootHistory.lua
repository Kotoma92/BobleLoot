--[[ LootHistory.lua
     Sole source of `char.itemsReceived`. Reads RCLootCouncil's own loot
     history (`RCLootCouncil.lootDB`) on load and on awards. The wowaudit
     public API doesn't expose loot history, so the generated data file
     no longer carries this field at all — LootHistory populates it.

     Each awarded entry is classified into one of:
        bis      -- "BiS" response
        major    -- "Major upgrade" response
        minor    -- "Minor upgrade" response
        mainspec -- generic "Mainspec/Need" (catch-all upgrade)
     Anything else (transmog, off-spec/greed, disenchant, pass, PvP, …)
     is excluded. The credited amount per category is configurable via
     `BobleLootDB.profile.lootWeights` (defaults: bis=1.5, major=1.0,
     mainspec=1.0, minor=0.5).

     The resulting weighted sum is written to `char.itemsReceived`, and a
     per-category breakdown is stored on `char.itemsReceivedBreakdown`
     for the score tooltip. Until LootHistory has run for a character,
     `itemsReceived` is nil and the history component is excluded from
     the score (see Scoring.lua:historyComponent).

     Filtering knobs (BobleLootDB.profile):
        lootHistoryDays  -- only count items awarded within last N days
        lootMinIlvl      -- ignore items below this item level (used to
                            exclude lower upgrade tracks like Champion
                            once Hero/Myth becomes the norm)
]]

local _, ns = ...
local LH = {}
ns.LootHistory = LH

local DEFAULT_DAYS    = 28
local DEFAULT_WEIGHTS = { bis = 1.5, major = 1.0, mainspec = 1.0, minor = 0.5 }
local DEFAULT_MIN_ILVL = 0

-- Try every plausible field RC has used to record an awarded item's
-- ilvl. Falls back to parsing the link via GetDetailedItemLevelInfo.
local function entryItemLevel(entry)
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
end

-- Anything matching one of these patterns is fully excluded (zero credit).
-- Matched against the lowercased `response` string.
local EXCLUDE_PATTERNS = {
    "transmog",
    "off%-spec", "off spec", "offspec", "off%-set",
    "greed",
    "disenchant", "sharded?",
    "pass", "autopass",
    "pvp",
    "free%s*roll", "fun",
}

-- Patterns mapping a response string -> category key. Order matters: more
-- specific labels are tested first so "Mainspec/Need" doesn't swallow
-- "BiS" or "Major upgrade".
local CATEGORY_PATTERNS = {
    { key = "bis",      patterns = { "^bis$", "best in slot", "%(bis%)" } },
    { key = "major",    patterns = { "major" } },
    { key = "minor",    patterns = { "minor", "small upgrade" } },
    { key = "mainspec", patterns = { "mainspec", "main%-spec", "main spec",
                                     "need", "upgrade" } },
}

-- Numeric response IDs only used as a fallback when the entry has no
-- string response (legacy data). RC default response 1 = Mainspec.
local NUMERIC_FALLBACK = { [1] = "mainspec" }

local function classify(entry)
    local r = entry.response or entry.responseID
    if type(r) == "string" then
        local lower = r:lower()
        for _, p in ipairs(EXCLUDE_PATTERNS) do
            if lower:find(p) then return nil end
        end
        for _, cat in ipairs(CATEGORY_PATTERNS) do
            for _, p in ipairs(cat.patterns) do
                if lower:find(p) then return cat.key end
            end
        end
        -- Unknown string response: treat as excluded to be safe (better
        -- to undercount than to credit "Transmog (custom)" by accident).
        return nil
    end
    if type(r) == "number" then
        return NUMERIC_FALLBACK[r]
    end
    -- Truly missing response field (very old entries): assume mainspec.
    return "mainspec"
end

local function getRCLootDB(RC)
    -- RC stores loot history in a few places depending on version:
    --   * Modern: RC.lootDB
    --   * Some builds: RC:GetHistoryDB()
    --   * SavedVar fallback: RCLootCouncilLootDB
    if RC then
        if RC.lootDB then return RC.lootDB end
        if type(RC.GetHistoryDB) == "function" then
            local ok, db = pcall(RC.GetHistoryDB, RC)
            if ok and db then return db end
        end
    end
    if _G.RCLootCouncilLootDB and _G.RCLootCouncilLootDB.factionrealm then
        local fr = _G.RCLootCouncilLootDB.factionrealm
        for _, perRealm in pairs(fr) do
            if type(perRealm) == "table" then return perRealm end
        end
    end
    return nil
end

-- RC entries store time as either a Unix timestamp (number) or a "date"
-- string like "12/04/26" / "2026-04-12 19:30:00". Try a few shapes.
local function entryTime(entry)
    local t = entry.time or entry.timestamp
    if type(t) == "number" then return t end
    local d, m, y = string.match(entry.date or "", "^(%d+)/(%d+)/(%d+)$")
    if d then
        return time({ day = tonumber(d), month = tonumber(m),
                      year = 2000 + tonumber(y) })
    end
    local Y, M, D, h, mi, s = string.match(entry.date or "",
        "^(%d+)-(%d+)-(%d+)%s+(%d+):(%d+):(%d+)$")
    if Y then
        return time({ year = tonumber(Y), month = tonumber(M), day = tonumber(D),
                      hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
    end
    return nil
end

local function effectiveWeights(profile)
    local w = profile.lootWeights or {}
    return {
        bis      = w.bis      or DEFAULT_WEIGHTS.bis,
        major    = w.major    or DEFAULT_WEIGHTS.major,
        mainspec = w.mainspec or DEFAULT_WEIGHTS.mainspec,
        minor    = w.minor    or DEFAULT_WEIGHTS.minor,
    }
end

-- Build name -> { total = weighted sum, counts = {bis=N, major=N, ...} }
function LH:CountItemsReceived(rcLootDB, days, weights, minIlvl)
    local cutoff = nil
    if days and days > 0 then
        cutoff = time() - days * 24 * 3600
    end
    minIlvl = minIlvl or 0
    local result = {}
    if type(rcLootDB) ~= "table" then return result end
    for name, entries in pairs(rcLootDB) do
        if type(entries) == "table" then
            local row = { total = 0, counts = { bis = 0, major = 0, mainspec = 0, minor = 0 } }
            for _, e in ipairs(entries) do
                if type(e) == "table" then
                    local cat = classify(e)
                    if cat then
                        local t = entryTime(e)
                        local timeOk = (not cutoff) or (not t) or t >= cutoff
                        local ilvl = entryItemLevel(e)
                        -- Items with unknown ilvl are kept (we'd rather
                        -- count an old entry than silently drop it).
                        local ilvlOk = (minIlvl <= 0) or (ilvl == nil) or (ilvl >= minIlvl)
                        if timeOk and ilvlOk then
                            row.counts[cat] = (row.counts[cat] or 0) + 1
                            row.total = row.total + (weights[cat] or 0)
                        end
                    end
                end
            end
            result[name] = row
        end
    end
    return result
end

-- Walk our loaded data file and overwrite itemsReceived using the live
-- counts. Names in the data file are "Name-Realm"; RC keys them the same
-- way ("Sprinty-Doomhammer"), so they line up directly.
function LH:Apply(addon)
    local data = addon:GetData()
    if not data or not data.characters then return end
    local RC = LibStub and LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil", true)
    local db = getRCLootDB(RC)
    if not db then return end
    local profile = addon.db.profile
    local days    = profile.lootHistoryDays or DEFAULT_DAYS
    local minIlvl = profile.lootMinIlvl or DEFAULT_MIN_ILVL
    local weights = effectiveWeights(profile)
    local rows    = self:CountItemsReceived(db, days, weights, minIlvl)
    for name, char in pairs(data.characters) do
        local r = rows[name]
        if r then
            char.itemsReceived          = r.total
            char.itemsReceivedBreakdown = r.counts
        end
    end
    self.lastApply = time()
end

function LH:Setup(addon)
    self.addon = addon
    -- Apply once after a short delay so RC has fully loaded its DB.
    C_Timer.After(5, function() self:Apply(addon) end)
    -- And re-apply whenever RC announces a new awarded item.
    local f = CreateFrame("Frame")
    f:RegisterEvent("CHAT_MSG_LOOT")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:SetScript("OnEvent", function()
        if self.lastApply and (time() - self.lastApply) < 10 then return end
        C_Timer.After(2, function() self:Apply(addon) end)
    end)
end
