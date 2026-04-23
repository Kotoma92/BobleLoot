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

-- Record a Great Vault selection as a synthetic loot history entry.
-- Called from Core.lua's WEEKLY_REWARDS_ITEM_GRABBED handler.
function LH:RecordVaultSelection(addon, playerName, itemLink, ilvl)
    local profile = addon.db.profile
    profile.vaultEntries = profile.vaultEntries or {}
    local entry = {
        player   = playerName,
        link     = itemLink,
        ilvl     = ilvl,
        response = "vault",
        time     = time(),
    }
    table.insert(profile.vaultEntries, entry)
    -- Kick off a debounced re-apply so the score updates promptly.
    if ns.SettingsPanel and ns.SettingsPanel.ScheduleLootHistoryApply then
        ns.SettingsPanel.ScheduleLootHistoryApply()
    end
end

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
        LH.lastVerdictForDiag = verdict
        if profile then profile.rcSchemaDetected = verdict end
        return verdict
    end

    local fr = db.factionrealm
    if type(fr) ~= "table" then
        verdict.status = "unknown"
        verdict.missingFields = { "RCLootCouncilLootDB.factionrealm" }
        LH.lastVerdictForDiag = verdict
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
        LH.lastVerdictForDiag = verdict
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
        LH.lastVerdictForDiag = verdict
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

    LH.lastVerdictForDiag = verdict
    if profile then profile.rcSchemaDetected = verdict end
    return verdict
end

-- Build name -> { total = weighted sum, counts = {bis=N, major=N, ...} }
-- profile (6th param) is used for wasted-loot filtering (3.5). When nil,
-- wasted-loot checks are skipped (backward compat with any ad-hoc callers).
function LH:CountItemsReceived(rcLootDB, days, weights, minIlvl, extraEntries, profile)
    local cutoff = nil
    if days and days > 0 then
        cutoff = time() - days * 24 * 3600
    end
    minIlvl = minIlvl or 0

    -- Merge synthetic entries (vault selections) into a copy of rcLootDB
    -- so we do not mutate RC's own SavedVariables.
    local merged = {}
    if type(rcLootDB) == "table" then
        for name, entries in pairs(rcLootDB) do
            if type(entries) == "table" then
                merged[name] = {}
                for _, e in ipairs(entries) do
                    merged[name][#merged[name] + 1] = e
                end
            end
        end
    end
    if type(extraEntries) == "table" then
        for _, e in ipairs(extraEntries) do
            local name = e.player
            if type(name) == "string" and name ~= "" then
                merged[name] = merged[name] or {}
                merged[name][#merged[name] + 1] = e
            end
        end
    end

    local result = {}
    for name, entries in pairs(merged) do
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
                        -- Wasted-loot check: skip entries flagged as traded away.
                        local wastedOk = true
                        if profile then
                            local link = e.lootWon or e.link or e.itemLink
                            local iid = link and C_Item and C_Item.GetItemInfoInstant and
                                select(2, C_Item.GetItemInfoInstant(link))
                            if iid and self:IsWasted(name, iid, profile) then
                                wastedOk = false
                            end
                        end
                        if timeOk and ilvlOk and wastedOk then
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

-- item 4.5: resolve a data-file character name to the RC loot-history key.
-- data.renames maps old RC name -> new data name (emitted by wowaudit.py
-- from tools/renames.json). To look up a data-file char in RC rows we need
-- the reverse: given new name, find old name that RC still uses.
local function resolveRCName(newName, data)
    if data and data.renames then
        for oldName, mappedName in pairs(data.renames) do
            if mappedName == newName then
                return oldName
            end
        end
    end
    return newName
end

-- Walk our loaded data file and overwrite itemsReceived using the live
-- counts. Names in the data file are "Name-Realm"; RC keys them the same
-- way ("Sprinty-Doomhammer"), so they line up directly.
function LH:Apply(addon)
    -- Refresh schema detection on every Apply so the stored verdict
    -- reflects the current RC SavedVar state. No chat warning here;
    -- the first-session warning is throttled in Setup.
    self:DetectSchemaVersion(nil, addon)

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
    local rows    = self:CountItemsReceived(db, days, weights, minIlvl,
                                            profile.vaultEntries or {}, profile)
    local matched, scanned = 0, 0
    for name, _ in pairs(rows) do scanned = scanned + 1 end
    for name, char in pairs(data.characters) do
        -- item 4.5: apply character renames before lookup so realm-transferred
        -- characters are matched by their old RC key when data.renames is present.
        local rcName = resolveRCName(name, data)
        local r = rows[rcName]
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

-- ── Wasted-loot API (3.5) ────────────────────────────────────────────────

-- Deterministic fingerprint for a (recipient, itemID) pair.
-- Deliberately excludes timestamp so the key is stable across Apply calls.
function LH:MakeFingerprint(name, itemID)
    return tostring(name) .. ":" .. tostring(itemID)
end

-- Record a fresh RC award in Core's pending-awards table so TRADE_CLOSED
-- can match against it within the 5-minute window.
function LH:RegisterPendingAward(addonObj, name, itemID)
    if not addonObj or not addonObj._pendingAwards then return end
    local fp = self:MakeFingerprint(name, itemID)
    addonObj._pendingAwards[fp] = { name = name, itemID = itemID, ts = time() }
end

-- Flag a (name, itemID) pair as wasted in the persistent profile map.
-- Safe to call multiple times for the same pair (idempotent).
function LH:MarkWasted(name, itemID, profile)
    if not profile or not profile.wastedLootMap then return end
    local fp = self:MakeFingerprint(name, itemID)
    profile.wastedLootMap[fp] = true
end

function LH:IsWasted(name, itemID, profile)
    if not profile or not profile.wastedLootMap then return false end
    local fp = self:MakeFingerprint(name, itemID)
    return profile.wastedLootMap[fp] == true
end

-- Set to true after the first-session drift warning has been emitted.
-- Reset to false by Setup() on each addon load.
LH._driftWarnedThisSession = false

function LH:Setup(addon)
    self._driftWarnedThisSession = false
    self.addon = addon
    -- Apply once after a short delay so RC has fully loaded its DB.
    C_Timer.After(5, function() self:Apply(addon) end)

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

        -- Register the most recent RC award as a pending wasted-loot candidate.
        -- RC does not fire a dedicated addon event here, so we read the active
        -- session's last award from the RC addon object if available.
        local RC = LibStub and LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil", true)
        if RC then
            local session = RC.GetCurrentSession and RC:GetCurrentSession()
            if session then
                for _, candidate in pairs(session) do
                    if candidate.awarded and candidate.name and candidate.link then
                        local iid = C_Item and C_Item.GetItemInfoInstant and
                            select(2, C_Item.GetItemInfoInstant(candidate.link))
                        if iid then
                            self:RegisterPendingAward(addon, candidate.name, iid)
                        end
                    end
                end
            end
        end

        C_Timer.After(2, function() self:Apply(addon) end)
    end)
end
