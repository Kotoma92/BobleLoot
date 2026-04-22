--[[ Sync.lua — BobleLoot raid sync protocol v2
     Implements: roadmap items 1.4 (schemaVersion) and 1.5 (proto + Adler32).

── Distribution model ────────────────────────────────────────────────────────
  Whoever holds the highest `version` (generatedAt timestamp from wowaudit.py)
  is the de-facto data master for that raid session. On entering a group,
  every BobleLoot client announces its version with HELLO. Anyone who hears a
  newer version sends a REQ whisper; the master replies with DATA (compressed
  + serialized, with Adler32 integrity field).

── Wire format (AceSerializer-encoded tables) ────────────────────────────────
  All envelopes carry:
    proto   [number]  Protocol version this message was encoded with.
                      Absent on v1 legacy messages (treated as proto=1).
                      Currently PROTO_VERSION = 2.

  HELLO    { kind="HELLO",    proto=N, v="<generatedAt>", n=<count>, pv=N }
             pv = highest proto the sender speaks (used for negotiation).

  REQ      { kind="REQ",      proto=N, v="<generatedAt>" }
             Whisper to the HELLO sender requesting the named version.

  DATA     { kind="DATA",     proto=N, v="<generatedAt>",
             payload="<base64-like>", adler=<number> }
             payload = LibDeflate:EncodeForWoWAddonChannel(
                         LibDeflate:CompressDeflate(
                           AceSerializer:Serialize(data), {level=9}))
             adler   = LibDeflate:Adler32(AceSerializer:Serialize(data))
                       (computed on the PRE-compression serialized string)

  SETTINGS { kind="SETTINGS", proto=N, transparency=true|false }
             Leader-only; broadcast to RAID/PARTY.

  SCORES   { kind="SCORES",   proto=N, iid=<itemID>,
             scores={["Name-Realm"]=number,...} }
             Leader-only; broadcast to RAID/PARTY.

── Protocol negotiation ──────────────────────────────────────────────────────
  On receiving HELLO, the receiver records sender.pv in Sync.peers[sender].
  Subsequent messages to that peer are sent at math.min(PROTO_VERSION, peer.pv).
  A peer with no pv field (v1 client) is treated as pv=1.
  proto=1 envelopes are accepted (no adler field expected or verified).
  proto > PROTO_VERSION envelopes are rejected and logged once per sender.

── Integrity ─────────────────────────────────────────────────────────────────
  DATA envelopes (proto >= 2) carry an Adler32 checksum of the serialized
  string before compression. LibDeflate:Adler32 is the public API used —
  it is LibDeflate's only public checksum function (no CRC32 is exposed).
  Receiver verifies before decompressing; mismatch → log once, drop.

── Rejection log ─────────────────────────────────────────────────────────────
  All drops are written to the _warnings ring buffer (max 20 entries).
  Read via ns.Sync:GetRecentWarnings(). Consumed by plan 3.12 toast system.
  In-game: /bl syncwarnings

── Channel ───────────────────────────────────────────────────────────────────
  RAID or PARTY (auto-detected). REQ and DATA are WHISPER.
  Prefix: "BobleLootSync"
]]

local _, ns = ...
local Sync = {}
ns.Sync = Sync

local PREFIX = "BobleLootSync"

-- Protocol and schema constants (see wire-format reference at bottom of plan).
local SCHEMA_VERSION     = 1   -- BobleLootSyncDB.schemaVersion; consumed by plan 2.7
local PROTO_VERSION      = 2   -- highest proto this client speaks
local MIN_PROTO_VERSION  = 1   -- lowest proto this client will accept from peers
-- Message kind strings (one authoritative list; never duplicated).
local KIND_HELLO    = "HELLO"
local KIND_REQ      = "REQ"
local KIND_DATA     = "DATA"
local KIND_SETTINGS = "SETTINGS"
local KIND_SCORES   = "SCORES"

-- Expose for external inspection (e.g., diagnostics, plan 3.12 toast).
Sync.PROTO_VERSION     = PROTO_VERSION
Sync.MIN_PROTO_VERSION = MIN_PROTO_VERSION

-- Session-scoped state (reset each load; not persisted).
Sync._loggedProtoWarn = {}   -- [sender] = true; throttle proto-rejection logs
Sync._loggedAdlerWarn = {}   -- [sender] = true; throttle Adler32-rejection logs
Sync._warnings        = {}   -- ring buffer; max WARNINGS_MAX entries
local WARNINGS_MAX    = 20

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

-- Returns encoded_payload, adler32_of_serialized_string.
-- Returns nil, nil on failure (LibDeflate missing).
local function encodeData(data)
    local serialized = AceSerializer:Serialize(data)
    if not LibDeflate then return nil, nil end
    local adler = LibDeflate:Adler32(serialized)
    local compressed = LibDeflate:CompressDeflate(serialized, { level = 9 })
    local encoded = LibDeflate:EncodeForWoWAddonChannel(compressed)
    return encoded, adler
end

-- Returns data_table, serialized_string on success.
-- Returns nil, nil on any failure.
local function decodeData(payload)
    if not LibDeflate then return nil, nil end
    local compressed = LibDeflate:DecodeForWoWAddonChannel(payload)
    if not compressed then return nil, nil end
    local serialized = LibDeflate:DecompressDeflate(compressed)
    if not serialized then return nil, nil end
    local ok, data = AceSerializer:Deserialize(serialized)
    if not ok then return nil, nil end
    return data, serialized
end

----------------------------------------------------------------------------
-- send wrappers
----------------------------------------------------------------------------

-- Stamp the proto version onto every outgoing envelope.
-- Pass a proto override when speaking to a known older peer (Task 5).
function Sync:_wrap(tbl, protoOverride)
    tbl.proto = protoOverride or PROTO_VERSION
    return tbl
end

local function send(addon, msgTable, dist, target)
    local ok, serialized = pcall(AceSerializer.Serialize, AceSerializer, msgTable)
    if not ok then return end
    addon:SendCommMessage(PREFIX, serialized, dist, target, "BULK")
end

local function isLeader()
    return UnitIsGroupLeader("player")
end

function Sync:SendHello(addon)
    local data = addon:GetData()
    local v = getDataVersion(data)
    if not v then return end
    local dist = channel()
    if not dist then return end
    -- pv = highest proto this client speaks; negotiated per Task 5.
    send(addon, self:_wrap({ kind = KIND_HELLO, v = v, n = countChars(data), pv = PROTO_VERSION }), dist)
end

function Sync:SendRequest(addon, target, version)
    -- REQ is a whisper; speak at the peer's negotiated proto if known.
    local peerPv = self.peers and self.peers[target] and self.peers[target].pv
    local effectivePv = peerPv and math.min(PROTO_VERSION, peerPv) or PROTO_VERSION
    send(addon, self:_wrap({ kind = KIND_REQ, v = version }, effectivePv), "WHISPER", target)
end

function Sync:SendData(addon, target)
    local data = addon:GetData()
    if not data then return end
    local payload, adler = encodeData(data)
    if not payload then
        addon:Print("could not encode data (LibDeflate missing?)")
        return
    end
    local peerPv = self.peers and self.peers[target] and self.peers[target].pv
    local effectivePv = peerPv and math.min(PROTO_VERSION, peerPv) or PROTO_VERSION
    send(addon, self:_wrap({
        kind    = KIND_DATA,
        v       = getDataVersion(data),
        payload = payload,
        adler   = adler,   -- Adler32 of pre-compression serialized string
    }, effectivePv), "WHISPER", target)
    addon:Print(string.format("sent dataset (%d chars) to %s", countChars(data), target))
end

function Sync:SendSettings(addon)
    if not isLeader() then return end
    local dist = channel()
    if not dist then return end
    local s = addon:GetSyncedSettings()
    send(addon, self:_wrap({
        kind         = KIND_SETTINGS,
        transparency = s.transparency and true or false,
    }), dist)
end

-- Leader broadcasts authoritative score map for an item so candidates'
-- transparency-mode display matches what the leader sees in council.
-- Throttled per-item via signature comparison so rapid voting frame
-- refreshes don't spam the channel.
function Sync:SendScores(addon, itemID, scores)
    if not isLeader() then return end
    local dist = channel()
    if not dist then return end
    if not itemID or type(scores) ~= "table" then return end

    self._lastSentScores = self._lastSentScores or {}
    -- Build a stable signature: sorted "name=score" pairs.
    local pairs_ = {}
    for n, s in pairs(scores) do
        pairs_[#pairs_ + 1] = string.format("%s=%.2f", n, s or -1)
    end
    table.sort(pairs_)
    local sig = table.concat(pairs_, "|")
    if self._lastSentScores[itemID] == sig then return end
    self._lastSentScores[itemID] = sig

    send(addon, self:_wrap({ kind = KIND_SCORES, iid = itemID, scores = scores }), dist)
end

----------------------------------------------------------------------------
-- warning ring buffer
----------------------------------------------------------------------------

-- Record a warning for the GetRecentWarnings API (consumed by plan 3.12 toast).
-- `reason` is a short human-readable string.
function Sync:_recordWarning(sender, reason)
    local entry = {
        time   = time(),    -- Unix timestamp (seconds)
        sender = sender,
        reason = reason,
    }
    table.insert(self._warnings, entry)
    -- Trim to WARNINGS_MAX by removing the oldest entry.
    while #self._warnings > WARNINGS_MAX do
        table.remove(self._warnings, 1)
    end
end

--- Returns the most recent sync warnings (up to 20), newest last.
-- Each entry: { time = <unix seconds>, sender = <string>, reason = <string> }
-- Consumed by plan 3.12 toast system. Do not modify the returned table.
function Sync:GetRecentWarnings()
    return self._warnings
end

----------------------------------------------------------------------------
-- proto-version gate
----------------------------------------------------------------------------

-- Returns true if the message proto is acceptable; false + side-effects if not.
-- Call this at the top of OnComm before any dispatch.
function Sync:_checkProto(msg, sender)
    local p = msg.proto
    -- v1 messages have no proto field; treat absence as proto=1.
    if p == nil then p = 1 end
    if type(p) ~= "number" then p = 0 end

    if p >= MIN_PROTO_VERSION and p <= PROTO_VERSION then
        return true   -- within our supported range
    end

    -- Outside range: log once per sender per session, then drop.
    if not self._loggedProtoWarn[sender] then
        self._loggedProtoWarn[sender] = true
        local msg_text = string.format(
            "|cffff6666[BobleLoot]|r Dropped message from %s: unsupported proto %d " ..
            "(supported %d-%d)",
            sender, p, MIN_PROTO_VERSION, PROTO_VERSION)
        DEFAULT_CHAT_FRAME:AddMessage(msg_text)
        self:_recordWarning(sender, string.format("unsupported proto %d", p))
    end
    return false
end

----------------------------------------------------------------------------
-- receive
----------------------------------------------------------------------------

function Sync:OnComm(addon, prefix, message, dist, sender)
    if prefix ~= PREFIX then return end
    if sender == UnitName("player") then return end

    local ok, msg = AceSerializer:Deserialize(message)
    if not ok or type(msg) ~= "table" or not msg.kind then return end

    -- Proto-version gate: drop anything outside our supported range.
    if not self:_checkProto(msg, sender) then return end

    if msg.kind == KIND_HELLO then
        -- Record peer's highest supported proto (pv field; absent on v1 peers).
        local peerPv = tonumber(msg.pv) or 1
        self.peers[sender] = self.peers[sender] or {}
        self.peers[sender].pv = peerPv

        local negotiated = math.min(PROTO_VERSION, peerPv)
        if peerPv ~= PROTO_VERSION then
            -- Log negotiation once per session per sender (informational, not a warning).
            if not (self.peers[sender] and self.peers[sender]._pvLogged) then
                self.peers[sender]._pvLogged = true
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "|cffffff00[BobleLoot]|r Proto negotiated with %s: speaking v%d " ..
                    "(peer max=%d, ours=%d)",
                    sender, negotiated, peerPv, PROTO_VERSION))
            end
        end

        -- Existing version-compare and REQ logic (unchanged in behaviour).
        local mine = getDataVersion(addon:GetData())
        if newerThan(msg.v, mine) then
            self._asked = self._asked or {}
            local key = sender .. "|" .. tostring(msg.v)
            if self._asked[key] then return end
            self._asked[key] = true
            self:SendRequest(addon, sender, msg.v)
        end

    elseif msg.kind == KIND_REQ then
        local mine = getDataVersion(addon:GetData())
        -- Only respond if we actually have at least as new a version.
        if mine and not newerThan(msg.v, mine) then
            self:SendData(addon, sender)
        end

    elseif msg.kind == KIND_SETTINGS then
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
            if ns.SettingsPanel and ns.SettingsPanel.Refresh then
                ns.SettingsPanel:Refresh()
            end
        end

    elseif msg.kind == KIND_SCORES then
        -- Only honour authoritative scores from the actual group leader.
        if not (UnitInRaid(sender) or UnitInParty(sender)) then return end
        if not UnitIsGroupLeader(sender) then return end
        if type(msg.iid) ~= "number" or type(msg.scores) ~= "table" then return end
        addon._leaderScores = addon._leaderScores or {}
        addon._leaderScores[msg.iid] = msg.scores
        if ns.LootFrame and ns.LootFrame.Refresh then
            ns.LootFrame:Refresh()
        end

    elseif msg.kind == KIND_DATA then
        local mine = getDataVersion(addon:GetData())
        if not newerThan(msg.v, mine) then return end

        -- Adler32 integrity check. Only enforce when proto >= 2 AND adler is present,
        -- so v1 peers (no adler field) degrade gracefully.
        if msg.proto and msg.proto >= 2 and msg.adler ~= nil then
            -- We must decode first (Adler32 is on the serialized string, not the
            -- encoded payload), then verify, then use.
            local data, serialized = decodeData(msg.payload)
            if not serialized then
                -- decodeData already failed; log as malformed.
                addon:Print("received malformed data from " .. sender)
                self:_recordWarning(sender, "decode failure")
                return
            end
            local actualAdler = LibDeflate:Adler32(serialized)
            -- Adler32 comparison must use modular equivalence to handle sign
            -- differences (LibDeflate's own IsEqualAdler32 pattern: compare mod 2^32).
            -- In Lua 5.1 on WoW, numbers are doubles; 2^32 fits exactly.
            local match = (actualAdler % 4294967296) == (msg.adler % 4294967296)
            if not match then
                if not self._loggedAdlerWarn[sender] then
                    self._loggedAdlerWarn[sender] = true
                    DEFAULT_CHAT_FRAME:AddMessage(string.format(
                        "|cffff6666[BobleLoot]|r Dropped data from %s: Adler32 mismatch " ..
                        "(got %d, expected %d)",
                        sender, actualAdler, msg.adler))
                    self:_recordWarning(sender, string.format(
                        "Adler32 mismatch got=%d expected=%d", actualAdler, msg.adler))
                end
                return
            end
            -- Adler32 passed; use the already-decoded data.
            if not data or type(data.characters) ~= "table" then
                addon:Print("received malformed data from " .. sender)
                self:_recordWarning(sender, "malformed characters table")
                return
            end
            _G.BobleLoot_Data = data
            if _G.BobleLootSyncDB then
                _G.BobleLootSyncDB.data = data
            end
            addon:Print(string.format(
                "received dataset from %s (%d characters, version %s) [Adler32 OK]",
                sender, countChars(data), tostring(data.generatedAt)))
        else
            -- Proto 1 or missing adler field: fall back to old path (no integrity check).
            local data = decodeData(msg.payload)
            -- Note: decodeData now returns two values; take only the first.
            if type(data) ~= "table" then data = nil end
            if not data or type(data.characters) ~= "table" then
                addon:Print("received malformed data from " .. sender)
                return
            end
            _G.BobleLoot_Data = data
            if _G.BobleLootSyncDB then
                _G.BobleLootSyncDB.data = data
            end
            addon:Print(string.format(
                "received dataset from %s (%d characters, version %s)",
                sender, countChars(data), tostring(data.generatedAt)))
        end
    end
end

----------------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------------

function Sync:Setup(addon)
    -- Restore previously synced data if no fresh local file is present
    -- *or* if the synced one is newer.
    _G.BobleLootSyncDB = _G.BobleLootSyncDB or {}

    -- Write schema version. Idempotent: never clobber a higher version
    -- that a future migration (plan 2.7) may have already written.
    local sv = _G.BobleLootSyncDB.schemaVersion
    if not sv or sv < SCHEMA_VERSION then
        _G.BobleLootSyncDB.schemaVersion = SCHEMA_VERSION
    end

    -- Initialize per-session peer table (re-learned via HELLO on each login).
    Sync.peers = {}   -- [senderName] = { pv = N }; populated on HELLO receive

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
