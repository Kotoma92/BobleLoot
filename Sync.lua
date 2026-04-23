--[[ Sync.lua — BobleLoot raid sync protocol v3
     Implements: roadmap items 1.4 (schemaVersion), 1.5 (proto + Adler32),
                 and 2.8 (chunked sync / DATACHUNK message type).

── Distribution model ────────────────────────────────────────────────────────
  Whoever holds the highest `version` (generatedAt timestamp from wowaudit.py)
  is the de-facto data master for that raid session. On entering a group,
  every BobleLoot client announces its version with HELLO. Anyone who hears a
  newer version sends a REQ whisper; the master replies with DATA (compressed
  + serialized, with Adler32 integrity field) or a sequence of DATACHUNK
  messages when both peers speak pv=3.

── Wire format (AceSerializer-encoded tables) ────────────────────────────────
  All envelopes carry:
    proto   [number]  Protocol version this message was encoded with.
                      Absent on v1 legacy messages (treated as proto=1).
                      PROTO_VERSION = 3 as of Batch 2C.

  HELLO    { kind="HELLO",    proto=N, v="<generatedAt>", n=<count>, pv=N }
             pv = highest proto the sender speaks (3 for Batch 2C clients).
             pv=3 clients use DATACHUNK for DATA transfers; pv<=2 peers receive full-DATA fallback.

  REQ      { kind="REQ",      proto=N, v="<generatedAt>" }
             Whisper to the HELLO sender requesting the named version.

  DATA     { kind="DATA",     proto=N, v="<generatedAt>",
             payload="<base64-like>", adler=<number> }
             Fallback path used only when negotiated proto < 3 (pv<=2 peer).
             payload = LibDeflate:EncodeForWoWAddonChannel(
                         LibDeflate:CompressDeflate(
                           AceSerializer:Serialize(data), {level=9}))
             adler   = LibDeflate:Adler32(AceSerializer:Serialize(data))
                       (computed on the PRE-compression serialized string)

  DATACHUNK { kind="DATACHUNK", proto=3, v="<generatedAt>",
              seq=N, total=N, chunk="<slice>", adler=<number> }
             Used when both peers have pv=3.
             chunk   = slice [seq..seq+CHUNK_SIZE-1] of the full encoded payload.
             adler   = Adler32 of the full pre-compression serialized string;
                       identical in all envelopes of the same transfer;
                       verified by receiver only after all total chunks arrive.
             Receiver accumulates in BobleLootSyncDB.pendingChunks[sender][v];
             promotes to BobleLoot_Data when received==total and Adler32 passes.
             30-second timeout (CHUNK_TIMEOUT) discards incomplete transfers.

  SETTINGS { kind="SETTINGS", proto=N, transparency=true|false }
             Leader-only; broadcast to RAID/PARTY.

  SCORES   { kind="SCORES",   proto=N, iid=<itemID>,
             scores={["Name-Realm"]=number,...} }
             Leader-only; broadcast to RAID/PARTY.

── Protocol negotiation (v3) ─────────────────────────────────────────────────
  HELLO.pv advertises the sender's highest supported proto.
  Receiver negotiates: effectivePv = math.min(PROTO_VERSION, peer.pv).
  effectivePv >= 3  → SendDataChunked (DATACHUNK path).
  effectivePv <= 2  → SendData legacy (DATA path, single message).
  pv=1 peers (pre-1C clients): full-DATA, no Adler32 sent.
  pv=2 peers (1C clients, no chunking): full-DATA with Adler32.
  pv=3 peers (2C clients): DATACHUNK with per-transfer Adler32.
  On receiving HELLO, the receiver records sender.pv in Sync.peers[sender].
  A peer with no pv field (v1 client) is treated as pv=1.
  proto=1 envelopes are accepted (no adler field expected or verified).
  proto > PROTO_VERSION envelopes are rejected and logged once per sender.

── Integrity ─────────────────────────────────────────────────────────────────
  DATA envelopes (proto >= 2) carry an Adler32 checksum of the serialized
  string before compression. LibDeflate:Adler32 is the public API used —
  it is LibDeflate's only public checksum function (no CRC32 is exposed).
  Receiver verifies before decompressing; mismatch → log once, drop.
  DATACHUNK transfers carry the same Adler32 in every chunk envelope;
  the receiver verifies it only after all chunks have been reassembled —
  not per-chunk. A mismatch after reassembly discards the entire transfer.

── Rejection log ─────────────────────────────────────────────────────────────
  All drops are written to the _warnings ring buffer (max 20 entries).
  Read via ns.Sync:GetRecentWarnings(). Consumed by plan 3.12 toast system.
  In-game: /bl syncwarnings

── Channel ───────────────────────────────────────────────────────────────────
  RAID or PARTY (auto-detected). REQ, DATA, and DATACHUNK are WHISPER.
  Prefix: "BobleLootSync"
]]

local _, ns = ...
local Sync = {}
ns.Sync = Sync

local PREFIX = "BobleLootSync"

-- Protocol and schema constants (see wire-format reference at bottom of plan).
local SCHEMA_VERSION     = 1   -- BobleLootSyncDB.schemaVersion; consumed by plan 2.7
local PROTO_VERSION      = 3   -- highest proto this client speaks
local MIN_PROTO_VERSION  = 1   -- lowest proto this client will accept from peers
-- Message kind strings (one authoritative list; never duplicated).
local KIND_HELLO     = "HELLO"
local KIND_REQ       = "REQ"
local KIND_DATA      = "DATA"
local KIND_DATACHUNK = "DATACHUNK"
local KIND_SETTINGS  = "SETTINGS"
local KIND_SCORES    = "SCORES"

-- Chunked transfer constants.
-- CHUNK_SIZE: bytes of WoWAddonChannel-encoded output per DATACHUNK envelope.
-- AceComm fragments at 4078 bytes; we stay well below to leave room for the
-- serialized envelope overhead (kind, proto, v, seq, total, adler fields).
-- See "Size Tuning" section of the implementation plan for derivation.
local CHUNK_SIZE    = 2048   -- bytes; tunable
local CHUNK_TIMEOUT = 30     -- seconds; discard incomplete transfers after this

-- Expose for external inspection (e.g., diagnostics, plan 3.12 toast).
Sync.PROTO_VERSION     = PROTO_VERSION
Sync.MIN_PROTO_VERSION = MIN_PROTO_VERSION
Sync.KIND_DATACHUNK    = KIND_DATACHUNK
Sync.CHUNK_SIZE        = CHUNK_SIZE
Sync.CHUNK_TIMEOUT     = CHUNK_TIMEOUT

-- Session-scoped state (reset each load; not persisted).
Sync._loggedProtoWarn = {}   -- [sender] = true; throttle proto-rejection logs
Sync._loggedAdlerWarn = {}   -- [sender] = true; throttle Adler32-rejection logs (legacy DATA path only)
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

-- Compare two Adler32 values for equality. LibDeflate:Adler32 is documented
-- to return a non-negative integer in [0, 2^32), but we normalise both sides
-- via `% 2^32` defensively against version-skew or any future LibDeflate
-- implementation that summed without the final modular reduction. In Lua 5.1
-- on WoW, numbers are doubles; 2^32 fits exactly so the modulo is lossless.
local ADLER_MOD = 4294967296
local function adlerEquals(a, b)
    if type(a) ~= "number" or type(b) ~= "number" then return false end
    return (a % ADLER_MOD) == (b % ADLER_MOD)
end

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

--- Slice an encoded payload string into ordered chunks of at most CHUNK_SIZE bytes.
-- @param encoded  string  Full WoWAddonChannel-encoded payload (output of encodeData).
-- @return         table   Sequence { [1]=str, [2]=str, ... }; at least one entry.
local function encodeChunks(encoded)
    local chunks = {}
    local len = #encoded
    if len == 0 then
        chunks[1] = ""
        return chunks
    end
    local pos = 1
    while pos <= len do
        local slice = encoded:sub(pos, pos + CHUNK_SIZE - 1)
        chunks[#chunks + 1] = slice
        pos = pos + CHUNK_SIZE
    end
    return chunks
end

--- Reassemble a chunks table (sparse [seq]=str) into the full encoded payload.
-- Assumes all seq 1..total are present (caller verifies before calling).
-- chunks is a [seq] = string sparse array — only numeric keys are written
-- during accumulation (entry.chunks[seq] = chunk with numeric seq), so there
-- is no risk of mixed-key tables here.
-- @param chunks  table   { [1]=str, ..., [total]=str }
-- @param total   number  Expected chunk count.
-- @return        string  Concatenated payload, or nil if any seq is missing.
local function reassembleChunks(chunks, total)
    local parts = {}
    for i = 1, total do
        if not chunks[i] then return nil end
        parts[i] = chunks[i]
    end
    return table.concat(parts)
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
    local peerPv      = self.peers and self.peers[target] and self.peers[target].pv
    local effectivePv = peerPv and math.min(PROTO_VERSION, peerPv) or PROTO_VERSION

    if effectivePv >= 3 then
        -- Peer supports DATACHUNK; use chunked transfer.
        self:SendDataChunked(addon, target)
        return
    end

    -- Fallback: single-message DATA (proto <= 2 peer).
    local data = addon:GetData()
    if not data then return end
    local payload, adler = encodeData(data)
    if not payload then
        addon:Print("could not encode data (LibDeflate missing?)")
        return
    end
    send(addon, self:_wrap({
        kind    = KIND_DATA,
        v       = getDataVersion(data),
        payload = payload,
        adler   = adler,   -- Adler32 of pre-compression serialized string
    }, effectivePv), "WHISPER", target)
    addon:Print(string.format("sent dataset (%d chars) to %s [legacy DATA]",
        countChars(data), target))
end

--- Send the current dataset to `target` as a sequence of DATACHUNK whispers.
-- Called when the negotiated proto is 3 (peer.pv >= 3).
-- Falls back gracefully on encoding failure or degenerate empty payload.
function Sync:SendDataChunked(addon, target)
    local data = addon:GetData()
    if not data then return end

    local payload, adler = encodeData(data)
    if not payload then
        addon:Print("could not encode data (LibDeflate missing?)")
        return
    end

    local chunks = encodeChunks(payload)
    local total  = #chunks

    if total == 0 then
        -- Degenerate: encoded payload was empty; abort rather than send zero chunks.
        addon:Print("warning: encoded payload is empty; aborting send to " .. target)
        return
    end

    local v = getDataVersion(data)

    addon:Print(string.format(
        "sending dataset to %s in %d chunk(s) (CHUNK_SIZE=%d, adler=%d)",
        target, total, CHUNK_SIZE, adler))

    for seq, chunk in ipairs(chunks) do
        send(addon, self:_wrap({
            kind  = KIND_DATACHUNK,
            v     = v,
            seq   = seq,
            total = total,
            chunk = chunk,
            adler = adler,   -- same value in every envelope; verified after reassembly
        }, 3), "WHISPER", target)
        -- Note: AceComm queues messages internally; we do not sleep between sends.
        -- AceComm's BULK priority plus the addon-channel rate limiter handle pacing.
    end
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
-- chunked transfer receive path
----------------------------------------------------------------------------

--- Cancel and clean up all state for a given sender+version transfer.
-- Safe to call even if no transfer exists for that pair.
function Sync:_cancelTransfer(sender, version)
    local inFlight = self._inFlight and self._inFlight[sender]
    if inFlight and inFlight[version] then
        local handle = inFlight[version].timerHandle
        if handle then
            self._addonRef:CancelTimer(handle)
        end
        inFlight[version] = nil
        if not next(inFlight) then
            self._inFlight[sender] = nil
        end
    end

    if _G.BobleLootSyncDB and _G.BobleLootSyncDB.pendingChunks then
        local pc = _G.BobleLootSyncDB.pendingChunks
        if pc[sender] then
            pc[sender][version] = nil
            if not next(pc[sender]) then
                pc[sender] = nil
            end
        end
    end
end

--- Called by AceTimer when a transfer's 30-second window expires.
function Sync:_onChunkTimeout(sender, version)
    self:_recordWarning(sender, string.format(
        "transfer timed out after %ds (version %s)", CHUNK_TIMEOUT, tostring(version)))
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|cffff6666[BobleLoot]|r Chunked transfer from %s timed out (version %s); discarding.",
        sender, tostring(version)))
    self:_cancelTransfer(sender, version)
    -- Fire AceEvent for the future 3.12 toast system.
    self._addonRef:SendMessage("BobleLoot_SyncTimedOut", sender)
end

--- Handle one incoming DATACHUNK envelope.
-- Called from OnComm when msg.kind == KIND_DATACHUNK.
function Sync:_onReceiveChunk(addon, msg, sender)
    -- Guard: require LibDeflate before doing anything with the chunk data.
    if not LibDeflate then
        self:_recordWarning(sender, "DATACHUNK ignored: LibDeflate not available")
        return
    end

    -- Field validation.
    local v     = msg.v
    local seq   = msg.seq
    local total = msg.total
    local chunk = msg.chunk
    local adler = msg.adler

    if type(v) ~= "string" or type(seq) ~= "number" or type(total) ~= "number"
        or type(chunk) ~= "string" or type(adler) ~= "number" then
        self:_recordWarning(sender, "DATACHUNK malformed fields")
        return
    end
    if seq < 1 or seq > total or total < 1 then
        self:_recordWarning(sender, string.format(
            "DATACHUNK invalid seq/total seq=%d total=%d", seq, total))
        return
    end

    -- Check whether we already have a newer dataset; if so, ignore.
    local mine = getDataVersion(addon:GetData())
    if not newerThan(v, mine) then
        -- Not newer; silently discard (the sender is behind us).
        self:_cancelTransfer(sender, v)
        return
    end

    -- Initialize BobleLootSyncDB.pendingChunks if needed.
    _G.BobleLootSyncDB = _G.BobleLootSyncDB or {}
    _G.BobleLootSyncDB.pendingChunks = _G.BobleLootSyncDB.pendingChunks or {}
    local pc = _G.BobleLootSyncDB.pendingChunks
    pc[sender] = pc[sender] or {}

    -- Initialize in-flight tracker.
    self._inFlight         = self._inFlight or {}
    self._inFlight[sender] = self._inFlight[sender] or {}

    local entry   = pc[sender][v]
    local ifEntry = self._inFlight[sender][v]

    if not entry then
        -- First chunk of this transfer.
        entry = {
            total    = total,
            received = 0,
            chunks   = {},
            adler    = adler,
        }
        pc[sender][v] = entry

        ifEntry = {
            received    = 0,
            total       = total,
            startedAt   = time(),
            timerHandle = nil,
        }
        self._inFlight[sender][v] = ifEntry

        -- Schedule the 30-second timeout.
        ifEntry.timerHandle = addon:ScheduleTimer(function()
            self:_onChunkTimeout(sender, v)
        end, CHUNK_TIMEOUT)
    else
        -- Subsequent chunk: sanity-check total consistency.
        if entry.total ~= total then
            self:_recordWarning(sender, string.format(
                "DATACHUNK total mismatch: expected %d got %d from %s",
                entry.total, total, sender))
            self:_cancelTransfer(sender, v)
            return
        end
        -- Sanity-check adler consistency across chunks.
        -- Each chunk envelope must carry the same Adler32 value.
        if not adlerEquals(entry.adler, adler) then
            self:_recordWarning(sender, string.format(
                "DATACHUNK adler mismatch across chunks from %s", sender))
            self:_cancelTransfer(sender, v)
            return
        end
    end

    -- Ignore duplicate seq (idempotent; received count only increments on new seq).
    if entry.chunks[seq] then return end

    -- Store chunk.
    entry.chunks[seq] = chunk
    entry.received    = entry.received + 1
    if ifEntry then
        ifEntry.received = entry.received
    end

    -- Fire progress event for future 3.12 toast (consumed only when that plan ships).
    addon:SendMessage("BobleLoot_SyncProgress", sender, entry.received, total)

    -- Check if complete.
    if entry.received < total then return end

    -- All chunks arrived. Cancel timeout timer.
    if ifEntry and ifEntry.timerHandle then
        addon:CancelTimer(ifEntry.timerHandle)
        ifEntry.timerHandle = nil
    end

    -- Reassemble.
    local fullPayload = reassembleChunks(entry.chunks, total)
    if not fullPayload then
        self:_recordWarning(sender, "DATACHUNK reassembly failed (missing seq)")
        self:_cancelTransfer(sender, v)
        return
    end

    -- Decode (decompress + deserialize). decodeData returns (data, serialized).
    local data, serialized = decodeData(fullPayload)
    if not serialized then
        self:_recordWarning(sender, "DATACHUNK decode failure after reassembly")
        self:_cancelTransfer(sender, v)
        return
    end

    -- Verify Adler32 over the reassembled serialized string.
    -- The Adler32 mismatch warning is emitted once per transfer attempt by
    -- construction: _cancelTransfer removes the entry immediately after, so
    -- a retry from the same sender+version pair would create a fresh entry
    -- and be logged again. No additional per-transfer throttle is needed.
    local actualAdler = LibDeflate:Adler32(serialized)
    if not adlerEquals(actualAdler, entry.adler) then
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "|cffff6666[BobleLoot]|r Dropped chunked data from %s: Adler32 mismatch " ..
            "(got %d, expected %d)",
            sender, actualAdler, entry.adler))
        self:_recordWarning(sender, string.format(
            "DATACHUNK Adler32 mismatch got=%d expected=%d", actualAdler, entry.adler))
        self:_cancelTransfer(sender, v)
        return
    end

    -- Validate structure.
    if not data or type(data.characters) ~= "table" then
        self:_recordWarning(sender, "DATACHUNK reassembled data has no characters table")
        self:_cancelTransfer(sender, v)
        return
    end

    -- Promote to live dataset.
    _G.BobleLoot_Data = data
    if _G.BobleLootSyncDB then
        _G.BobleLootSyncDB.data = data
    end

    addon:Print(string.format(
        "received dataset from %s via %d chunks (%d characters, version %s) [Adler32 OK]",
        sender, total, countChars(data), tostring(data.generatedAt)))

    -- Clean up pending state.
    self:_cancelTransfer(sender, v)
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

        -- Adler32 integrity check. Only enforce when proto >= 2 AND adler is
        -- a number (a malicious peer could send a non-numeric adler; reject
        -- those as malformed rather than letting the modulo throw).
        if msg.proto and msg.proto >= 2 and type(msg.adler) == "number" then
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
            if not adlerEquals(actualAdler, msg.adler) then
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
            -- Proto 1 or missing/non-numeric adler field: fall back to old
            -- path (no integrity check). decodeData returns (data, serialized);
            -- we discard the serialized string here.
            local data = decodeData(msg.payload)
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
    -- Store addon reference so timer callbacks can reach Sync methods without
    -- capturing a local. Must be set before any ScheduleTimer calls.
    Sync._addonRef = addon

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

    -- In-flight transfer state; keyed by sender name then version string.
    -- Mirrors BobleLootSyncDB.pendingChunks but the timer handles live here
    -- (timers cannot be serialized into SavedVariables).
    Sync._inFlight = {}   -- [sender][version] = { received=N, total=M, startedAt=t, timerHandle=h }

    -- Discard any chunks left over from a previous session (timers don't survive reload).
    -- Plan 2B will call this from its migration runner; until 2B ships, call it here.
    self:PrunePendingChunks()

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
