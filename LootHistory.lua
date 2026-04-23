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
local DEFAULT_WEIGHTS = { bis = 1.5, major = 1.0, mainspec = 1.0, minor = 0.5, vault = 0.5 }
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
    -- BOE distributions are tracked as "vault" category (same weight,
    -- configurable). Tested after the normal upgrade categories so a
    -- response of "Major upgrade (BOE)" still reads as "major".
    { key = "vault",    patterns = { "boe", "bind on equip", "bind%-on%-equip" } },
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

-- Detect whether `db` looks like the factionrealm-shaped table
--   { ["Horde - Draenor"] = { ["Player-Realm"] = {entries...}, ... }, ... }
-- or already a flat name->entries map.
local function looksLikeFactionRealm(db)
    if type(db) ~= "table" then return false end
    for k, v in pairs(db) do
        if type(k) == "string" and type(v) == "table"
           and k:find(" %- ") then  -- "<Faction> - <Realm>"
            return true
        end
        return false
    end
    return false
end

local function mergeFactionRealms(fr)
    local merged, sources = {}, {}
    for frName, perRealm in pairs(fr) do
        if type(perRealm) == "table" then
            sources[#sources + 1] = frName
            for charName, entries in pairs(perRealm) do
                if type(entries) == "table" then
                    -- IMPORTANT: never alias the original RC table here.
                    -- A previous version set `merged[charName] = entries`
                    -- and then appended to it on a second factionrealm
                    -- match, which mutated RC's own SavedVariables and
                    -- accumulated duplicates on every re-Apply (every
                    -- /reload, PLAYER_ENTERING_WORLD, CHAT_MSG_LOOT...).
                    local dst = merged[charName]
                    if not dst then
                        dst = {}
                        merged[charName] = dst
                    end
                    for _, e in ipairs(entries) do
                        dst[#dst + 1] = e
                    end
                end
            end
        end
    end
    return merged, sources
end

local function getRCLootDB(RC)
    -- Prefer the canonical SavedVariables global — it's the most
    -- comprehensive (all characters across factionrealms recorded by
    -- this account). RC.lootDB / RC:GetHistoryDB() are wrappers that
    -- in some versions return only the active factionrealm.
    if _G.RCLootCouncilLootDB and _G.RCLootCouncilLootDB.factionrealm then
        local merged, sources = mergeFactionRealms(_G.RCLootCouncilLootDB.factionrealm)
        if next(merged) then
            return merged, "RCLootCouncilLootDB.factionrealm{"
                .. table.concat(sources, ",") .. "}"
        end
    end
    -- Fallbacks if for some reason the SavedVar is missing.
    if RC then
        if RC.lootDB then
            local db = RC.lootDB
            if looksLikeFactionRealm(db) then
                local merged, sources = mergeFactionRealms(db)
                if next(merged) then
                    return merged, "RC.lootDB[merged:" .. table.concat(sources, ",") .. "]"
                end
            end
            return db, "RC.lootDB"
        end
        if type(RC.GetHistoryDB) == "function" then
            local ok, db = pcall(RC.GetHistoryDB, RC)
            if ok and db then
                if looksLikeFactionRealm(db) then
                    local merged = mergeFactionRealms(db)
                    if next(merged) then
                        return merged, "RC:GetHistoryDB()[merged]"
                    end
                end
                return db, "RC:GetHistoryDB()"
            end
        end
    end
    return nil, "no source found"
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
        vault    = (profile.vaultWeight ~= nil) and profile.vaultWeight
                   or DEFAULT_WEIGHTS.vault,
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
            local row = { total = 0, counts = { bis = 0, major = 0, mainspec = 0, minor = 0, vault = 0 } }
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
    local db, source = getRCLootDB(RC)
    self.lastSource = source
    if not db then return end
    local profile = addon.db.profile
    local days    = profile.lootHistoryDays or DEFAULT_DAYS
    local minIlvl = profile.lootMinIlvl or DEFAULT_MIN_ILVL
    local weights = effectiveWeights(profile)
    local rows    = self:CountItemsReceived(db, days, weights, minIlvl)
    local matched, scanned = 0, 0
    for name, _ in pairs(rows) do scanned = scanned + 1 end
    for name, char in pairs(data.characters) do
        local r = rows[name]
        if r then
            char.itemsReceived          = r.total
            char.itemsReceivedBreakdown = r.counts
            matched = matched + 1
        end
    end
    self.lastApply   = time()
    self.lastMatched = matched
    self.lastScanned = scanned
end

-- Diagnostic helper used by /bl lootdb.
function LH:Diagnose(addon)
    local RC = LibStub and LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil", true)
    local db, source = getRCLootDB(RC)
    addon:Print("Loot history source: " .. (source or "?"))
    if not db then
        addon:Print("|cffff5555No loot history database found.|r")
        addon:Print(" - RC loaded: " .. tostring(RC ~= nil))
        addon:Print(" - _G.RCLootCouncilLootDB present: "
            .. tostring(_G.RCLootCouncilLootDB ~= nil))
        if _G.RCLootCouncilLootDB then
            addon:Print(" - .factionrealm present: "
                .. tostring(_G.RCLootCouncilLootDB.factionrealm ~= nil))
        end
        return
    end
    local n = 0; for _ in pairs(db) do n = n + 1 end
    addon:Print(string.format("Found %d character(s) in RC loot history.", n))
    local data = addon:GetData()
    if data and data.characters then
        local matches, missing = {}, {}
        for name in pairs(data.characters) do
            if db[name] then
                local cnt = 0; for _ in ipairs(db[name]) do cnt = cnt + 1 end
                matches[#matches + 1] = string.format("%s (%d)", name, cnt)
            else
                missing[#missing + 1] = name
            end
        end
        if #matches > 0 then
            addon:Print("Matched: " .. table.concat(matches, ", "))
        end
        if #missing > 0 then
            addon:Print("|cffaaaaaaUnmatched dataset chars: "
                .. table.concat(missing, ", ") .. "|r")
        end
        local sample = {}
        for name in pairs(db) do
            sample[#sample + 1] = name
            if #sample >= 5 then break end
        end
        if #sample > 0 then
            addon:Print("|cffaaaaaaSample names in RC DB: "
                .. table.concat(sample, ", ") .. "|r")
        end
    end
end

-- Per-character deep diagnostic. Walks the live RC db for the given
-- character key and prints, step by step, how many entries pass each
-- filter and how they classify. Helps explain a bogus tooltip number.
function LH:DiagnoseChar(addon, name)
    if not name or name == "" then
        addon:Print("usage: /bl debugchar Name-Realm"); return
    end
    local RC = LibStub and LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil", true)
    local db, source = getRCLootDB(RC)
    addon:Print("Source: " .. (source or "?"))
    if not db then addon:Print("|cffff5555no db|r"); return end
    local entries = db[name]
    if type(entries) ~= "table" then
        -- case-insensitive / substring fallback
        local lname = name:lower()
        local exact, partial
        for k, v in pairs(db) do
            if type(k) == "string" and type(v) == "table" then
                if k:lower() == lname then exact = k
                elseif k:lower():find(lname, 1, true) then partial = partial or k end
            end
        end
        local resolved = exact or partial
        if resolved then
            addon:Print("|cffaaaaaaresolved '"..name.."' -> '"..resolved.."'|r")
            name, entries = resolved, db[resolved]
        else
            addon:Print("|cffff5555no entries for "..name.."|r")
            local sample, n = {}, 0
            for k in pairs(db) do
                n = n + 1
                if #sample < 12 then sample[#sample+1] = k end
            end
            addon:Print(string.format("db has %d keys. sample: %s", n, table.concat(sample, ", ")))
            return
        end
    end
    local profile = addon.db.profile
    local days    = profile.lootHistoryDays or DEFAULT_DAYS
    local minIlvl = profile.lootMinIlvl or DEFAULT_MIN_ILVL
    local weights = effectiveWeights(profile)
    local cutoff  = (days and days > 0) and (time() - days * 24 * 3600) or nil
    local total, arrayLen = 0, 0
    for _ in pairs(entries) do total = total + 1 end
    for _ in ipairs(entries) do arrayLen = arrayLen + 1 end
    addon:Print(string.format(
        "%s: pairs=%d, ipairs=%d  (filters: days=%s, minIlvl=%d)",
        name, total, arrayLen, tostring(days), minIlvl))
    local responses, classified = {}, { bis=0, major=0, mainspec=0, minor=0 }
    local kept, droppedTime, droppedIlvl, droppedClass = 0, 0, 0, 0
    for _, e in ipairs(entries) do
        if type(e) == "table" then
            local r = tostring(e.response or e.responseID or "<nil>")
            responses[r] = (responses[r] or 0) + 1
            local cat = classify(e)
            if not cat then
                droppedClass = droppedClass + 1
            else
                local t = entryTime(e)
                local timeOk = (not cutoff) or (not t) or t >= cutoff
                local ilvl = entryItemLevel(e)
                local ilvlOk = (minIlvl <= 0) or (ilvl == nil) or (ilvl >= minIlvl)
                if not timeOk then droppedTime = droppedTime + 1
                elseif not ilvlOk then droppedIlvl = droppedIlvl + 1
                else
                    kept = kept + 1
                    classified[cat] = classified[cat] + 1
                end
            end
        end
    end
    addon:Print(string.format(
        "kept=%d  dropped: byClassify=%d byTime=%d byIlvl=%d",
        kept, droppedClass, droppedTime, droppedIlvl))
    local rparts = {}
    for r, c in pairs(responses) do rparts[#rparts+1] = string.format("%s=%d", r, c) end
    table.sort(rparts)
    addon:Print("response breakdown: " .. table.concat(rparts, ", "))
    local weighted = 0
    local cparts = {}
    for _, k in ipairs({"bis","major","mainspec","minor"}) do
        weighted = weighted + classified[k] * (weights[k] or 0)
        cparts[#cparts+1] = string.format("%s=%d", k, classified[k])
    end
    addon:Print(string.format("classified: %s  -> weighted=%.1f",
        table.concat(cparts, " "), weighted))
    local data = addon:GetData()
    local char = data and data.characters and data.characters[name]
    if char then
        local b = char.itemsReceivedBreakdown
        local bs = b and string.format("bis=%d major=%d mainspec=%d minor=%d",
            b.bis or 0, b.major or 0, b.mainspec or 0, b.minor or 0) or "<nil>"
        addon:Print(string.format(
            "stored on data.characters[%s]: itemsReceived=%s  breakdown=%s",
            name, tostring(char.itemsReceived), bs))
    else
        addon:Print("no entry in BobleLoot_Data.characters for " .. name)
    end
end

-- One-shot dedup of the live RC saved-variables table. A previous
-- version of mergeFactionRealms (BobleLoot < 1.0.1) aliased RC's
-- per-character entry array and then appended a second factionrealm's
-- entries into it, growing RC's own SavedVariables on every Apply().
-- This walks RCLootCouncilLootDB.factionrealm[*][*] and removes any
-- duplicate entries (same (date, time, lootWon/link, response)) so
-- the next SavedVariables write doesn't persist the corruption.
-- Returns total entries removed.
function LH:DedupRCSavedVar()
    local fr = _G.RCLootCouncilLootDB and _G.RCLootCouncilLootDB.factionrealm
    if type(fr) ~= "table" then return 0 end
    local removed = 0
    for _, perRealm in pairs(fr) do
        if type(perRealm) == "table" then
            for charName, entries in pairs(perRealm) do
                if type(entries) == "table" and #entries > 0 then
                    local seen, kept = {}, {}
                    for _, e in ipairs(entries) do
                        if type(e) == "table" then
                            local key = table.concat({
                                tostring(e.date or ""), tostring(e.time or ""),
                                tostring(e.lootWon or e.link or e.itemLink or ""),
                                tostring(e.response or e.responseID or ""),
                                tostring(e.owner or ""),
                            }, "|")
                            if not seen[key] then
                                seen[key] = true
                                kept[#kept + 1] = e
                            else
                                removed = removed + 1
                            end
                        end
                    end
                    if #kept ~= #entries then
                        for i = #entries, 1, -1 do entries[i] = nil end
                        for i, e in ipairs(kept) do entries[i] = e end
                    end
                end
            end
        end
    end
    return removed
end

function LH:Setup(addon)
    self.addon = addon
    -- Apply once after a short delay so RC has fully loaded its DB.
    C_Timer.After(5, function() self:Apply(addon) end)
    -- And re-apply whenever RC announces a new awarded item.
    local f = CreateFrame("Frame")
    f:RegisterEvent("CHAT_MSG_LOOT")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:RegisterEvent("PLAYER_LOGOUT")
    f:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_LOGOUT" then
            -- Last-chance dedup before SavedVariables get written.
            local n = LH:DedupRCSavedVar()
            if n > 0 and addon and addon.Print then
                addon:Print(string.format(
                    "BobleLoot: removed %d duplicate RC loot entr%s before save.",
                    n, n == 1 and "y" or "ies"))
            end
            return
        end
        if self.lastApply and (time() - self.lastApply) < 10 then return end
        C_Timer.After(2, function() self:Apply(addon) end)
    end)
end
