--[[ Sync.lua
     Boble Loot raid sync.

     Distribution model:
       * Whoever has the highest `version` (timestamp from the generator)
         is the de-facto data master for that raid.
       * On entering a group, every Boble Loot user announces their
         version with HELLO. Anyone who hears a newer version REQuests
         the data; the master replies with DATA (chunked + compressed +
         serialized).
       * Receivers store the dataset in BobleLootSyncDB so it survives
         relog, and inject it into _G.BobleLoot_Data so Scoring.lua sees
         it transparently.

     Wire format (all messages are AceSerializer tables):
       HELLO    { v = "...", n = numCharacters }
       REQ      { v = "..." }                   -- newest version we know about
       DATA     { v = "...", payload = "..." }  -- payload = Deflate(Serialize(data))
       SETTINGS { transparency = true|false }   -- leader-only; broadcast to RAID

     Channel: "RAID" (sent only when in a raid/party).
     Prefix : "BobleLootSync"
]]

local _, ns = ...
local Sync = {}
ns.Sync = Sync

local PREFIX = "BobleLootSync"

local AceSerializer = LibStub("AceSerializer-3.0")
local LibDeflate    = LibStub("LibDeflate", true)
if not LibDeflate then
    -- Soft fallback: sync will be disabled. Scoring still works locally.
    geterrorhandler()("BobleLoot: LibDeflate not found; raid sync disabled.")
end

----------------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------------

local function getDataVersion(data)
    if not data then return nil end
    return data.generatedAt
end

local function countChars(data)
    if not data or not data.characters then return 0 end
    local n = 0
    for _ in pairs(data.characters) do n = n + 1 end
    return n
end

-- Compare two ISO-8601 strings (or any sortable strings) safely.
local function newerThan(a, b)
    if not a then return false end
    if not b then return true end
    return a > b
end

local function inGroup()
    return IsInRaid() or IsInGroup()
end

local function channel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

----------------------------------------------------------------------------
-- (de)serialize
----------------------------------------------------------------------------

local function encodeData(data)
    local serialized = AceSerializer:Serialize(data)
    if not LibDeflate then return nil end
    local compressed = LibDeflate:CompressDeflate(serialized, { level = 9 })
    return LibDeflate:EncodeForWoWAddonChannel(compressed)
end

local function decodeData(payload)
    if not LibDeflate then return nil end
    local compressed = LibDeflate:DecodeForWoWAddonChannel(payload)
    if not compressed then return nil end
    local serialized = LibDeflate:DecompressDeflate(compressed)
    if not serialized then return nil end
    local ok, data = AceSerializer:Deserialize(serialized)
    if not ok then return nil end
    return data
end

----------------------------------------------------------------------------
-- send wrappers
----------------------------------------------------------------------------

local function send(addon, msgTable, dist, target)
    local ok, serialized = pcall(AceSerializer.Serialize, AceSerializer, msgTable)
    if not ok then return end
    addon:SendCommMessage(PREFIX, serialized, dist, target, "BULK")
end

local function isLeader()
    return UnitIsGroupLeader("player")
end

function Sync:SendSettings(addon)
    if not isLeader() then return end
    local dist = channel()
    if not dist then return end
    local s = addon:GetSyncedSettings()
    send(addon, { kind = "SETTINGS", transparency = s.transparency and true or false }, dist)
end

function Sync:SendHello(addon)
    local data = addon:GetData()
    local v = getDataVersion(data)
    if not v then return end
    local dist = channel()
    if not dist then return end
    send(addon, { kind = "HELLO", v = v, n = countChars(data) }, dist)
end

function Sync:SendRequest(addon, target, version)
    send(addon, { kind = "REQ", v = version }, "WHISPER", target)
end

function Sync:SendData(addon, target)
    local data = addon:GetData()
    if not data then return end
    local payload = encodeData(data)
    if not payload then
        addon:Print("could not encode data (LibDeflate missing?)")
        return
    end
    send(addon, { kind = "DATA", v = getDataVersion(data), payload = payload },
         "WHISPER", target)
    addon:Print(string.format("sent dataset (%d chars) to %s",
        countChars(data), target))
end

----------------------------------------------------------------------------
-- receive
----------------------------------------------------------------------------

function Sync:OnComm(addon, prefix, message, dist, sender)
    if prefix ~= PREFIX then return end
    if sender == UnitName("player") then return end

    local ok, msg = AceSerializer:Deserialize(message)
    if not ok or type(msg) ~= "table" or not msg.kind then return end

    if msg.kind == "HELLO" then
        local mine = getDataVersion(addon:GetData())
        if newerThan(msg.v, mine) then
            -- Throttle: only ask once per (sender, version).
            self._asked = self._asked or {}
            local key = sender .. "|" .. tostring(msg.v)
            if self._asked[key] then return end
            self._asked[key] = true
            self:SendRequest(addon, sender, msg.v)
        end

    elseif msg.kind == "REQ" then
        local mine = getDataVersion(addon:GetData())
        -- Only respond if we actually have at least as new a version.
        if mine and not newerThan(msg.v, mine) then
            self:SendData(addon, sender)
        end

    elseif msg.kind == "SETTINGS" then
        -- Only honour SETTINGS from the actual group leader, to prevent
        -- a rogue raid member from forcing transparency on everyone.
        if not (UnitInRaid(sender) or UnitInParty(sender)) then return end
        if not UnitIsGroupLeader(sender) then return end
        local s = addon:GetSyncedSettings()
        local prev = s.transparency
        s.transparency = msg.transparency and true or false
        if prev ~= s.transparency then
            addon:Print(string.format("transparency mode %s by %s.",
                s.transparency and "ENABLED" or "DISABLED", sender))
            if ns.LootFrame and ns.LootFrame.Refresh then
                ns.LootFrame:Refresh()
            end
        end

    elseif msg.kind == "DATA" then
        local mine = getDataVersion(addon:GetData())
        if not newerThan(msg.v, mine) then return end
        local data = decodeData(msg.payload)
        if not data or type(data.characters) ~= "table" then
            addon:Print("received malformed data from " .. sender)
            return
        end
        _G.BobleLoot_Data = data
        if _G.BobleLootSyncDB then
            _G.BobleLootSyncDB.data = data
        end
        addon:Print(string.format("received dataset from %s (%d characters, version %s)",
            sender, countChars(data), tostring(data.generatedAt)))
    end
end

----------------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------------

function Sync:Setup(addon)
    -- Restore previously synced data if no fresh local file is present
    -- *or* if the synced one is newer.
    _G.BobleLootSyncDB = _G.BobleLootSyncDB or {}
    local saved = _G.BobleLootSyncDB.data
    if saved and saved.characters then
        local mine = getDataVersion(_G.BobleLoot_Data)
        if newerThan(getDataVersion(saved), mine) then
            _G.BobleLoot_Data = saved
        end
    end

    addon:RegisterComm(PREFIX, function(_, prefix, message, dist, sender)
        Sync:OnComm(addon, prefix, message, dist, sender)
    end)

    addon:RegisterEvent("GROUP_ROSTER_UPDATE", function()
        if inGroup() then
            Sync:SendHello(addon)
            -- If we're the leader, also (re)broadcast the current
            -- transparency setting so newly-joined members pick it up.
            if isLeader() then Sync:SendSettings(addon) end
        end
    end)
    addon:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        C_Timer.After(5, function()
            if inGroup() then
                Sync:SendHello(addon)
                if isLeader() then Sync:SendSettings(addon) end
            end
        end)
    end)
end

function Sync:BroadcastNow(addon)
    -- Manual push: everyone in the raid will compare versions and ask if needed.
    self:SendHello(addon)
end
