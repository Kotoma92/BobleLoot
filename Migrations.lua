--[[ Migrations.lua
     Sequential, idempotent DB migration framework for BobleLoot.

     Each migration in Migrations.list has:
       version  (number)  -- the dbVersion this migration brings the profile TO.
       up       (function(profile)) -- idempotent transform; never errors.

     Migrations:Run(profile) is called from BobleLoot:OnInitialize immediately
     after AceDB:New().  It advances profile.dbVersion from its current value
     (0 if absent) to the highest registered migration version, running each
     intermediate migration exactly once.

     Adding a new migration: append a new entry to Migrations.list with the
     next version number.  Never renumber existing entries.

     Schema note:
       profile.dbVersion is stored in BobleLootDB (AceDB profile scope) so it
       persists across sessions and follows per-character profile swaps.
]]

local _, ns = ...
local Migrations = {}
ns.Migrations = Migrations

----------------------------------------------------------------------------
-- Migration list (append-only)
----------------------------------------------------------------------------

Migrations.list = {
    -- v1: Convert legacy `mplusScore` (raider.io score integer) to
    --     `mplusDungeons = 0` (count of M+ dungeons this season).
    --     The old field was written by wowaudit.py before the Batch 2.3
    --     pipeline changes.  Characters that still carry it in their
    --     profile data would feed the wrong metric into Scoring:Compute.
    {
        version = 1,
        up = function(profile)
            -- profile itself doesn't store per-character data; the canonical
            -- location is _G.BobleLoot_Data.characters (the generated Lua
            -- file).  However the scorer reads `char.mplusDungeons or
            -- char.mplusScore` (see Scoring.lua:mplusComponent) so the
            -- old key is harmless in the data file.  What we DO want to
            -- clean up is any stale `mplusScore` persisted in BobleLootSyncDB
            -- (received from an older leader and stored as-is).
            local syncDB = _G.BobleLootSyncDB
            if not syncDB or not syncDB.data then return end
            local chars = syncDB.data.characters
            if type(chars) ~= "table" then return end
            local converted = 0
            for _, char in pairs(chars) do
                if char.mplusScore ~= nil and char.mplusDungeons == nil then
                    char.mplusDungeons = 0
                    char.mplusScore = nil
                    converted = converted + 1
                end
            end
            if converted > 0 then
                -- Use print() directly; the addon object isn't passed here.
                -- This runs before the frame is shown so DEFAULT_CHAT_FRAME
                -- is the right target.
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "|cffffcc00BobleLoot migration v1:|r converted %d legacy mplusScore "
                    .. "entries to mplusDungeons=0 in BobleLootSyncDB.", converted))
            end
        end,
    },
    -- v2: Initialise 3.5 wastedLootMap and 3.8 scoreHistory/trend keys.
    -- Safe to run on any profile version < 2; idempotent because we only
    -- set keys that are nil (AceDB will have supplied defaults on fresh
    -- installs, but old installs pre-3B won't have them).
    {
        version = 2,
        up = function(profile)
            if profile.scoreHistory == nil then
                profile.scoreHistory = {}
            end
            if profile.wastedLootMap == nil then
                profile.wastedLootMap = {}
            end
            if profile.trackTrends == nil then
                profile.trackTrends = true
            end
            if profile.trendHistoryDays == nil then
                profile.trendHistoryDays = 28
            end
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cffffcc00BobleLoot migration v2:|r initialised scoreHistory and wastedLootMap.")
        end,
    },
}

----------------------------------------------------------------------------
-- Runner
----------------------------------------------------------------------------

-- Run all pending migrations against `profile`.
-- profile.dbVersion is the last successfully-applied migration version
-- (0 = never migrated / fresh install).
function Migrations:Run(profile)
    if type(profile) ~= "table" then return end
    local current = profile.dbVersion or 0
    for _, migration in ipairs(self.list) do
        if migration.version > current then
            local ok, err = pcall(migration.up, profile)
            if ok then
                profile.dbVersion = migration.version
                current = migration.version
            else
                -- Log but continue; a failed migration should not block
                -- the addon from loading.
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "|cffff5555BobleLoot migration v%d failed: %s|r",
                    migration.version, tostring(err)))
            end
        end
    end
end
