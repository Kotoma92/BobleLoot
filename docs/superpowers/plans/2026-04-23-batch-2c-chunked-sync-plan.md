# Batch 2C — Chunked Sync Protocol v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split large AceSerializer+LibDeflate DATA payloads into ordered DATACHUNK messages so that growing datasets never hit the addon-channel per-message size throttle, with full Adler32 integrity verified after reassembly and graceful fallback to the existing single-message path for older peers.

**Architecture:** The sender serializes and compresses the full dataset exactly as today, then slices the WoWAddonChannel-encoded output into fixed-size `CHUNK_SIZE` byte strings numbered `seq = 1..total`; each slice is wrapped in a DATACHUNK envelope and whispered in order. The receiver accumulates slices in `BobleLootSyncDB.pendingChunks[sender][version]` keyed by `seq`, and only when all `total` chunks have arrived does it concatenate, decode, decompress, deserialize, verify Adler32 against the checksum carried in every chunk envelope, and promote the result to `BobleLoot_Data`. A per-transfer AceTimer fires after 30 seconds and discards any incomplete entry. Protocol negotiation is extended by bumping `PROTO_VERSION` from `2` to `3` and advertising `pv = 3` in HELLO; peers that respond with `pv <= 2` receive the existing single-message DATA path unchanged.

**Tech Stack:** Lua, AceComm-3.0, AceSerializer-3.0, LibDeflate (existing), AceTimer-3.0 (for 30-second transfer timeouts)

**Roadmap items covered:**

> **2.8 `[Cross]` Chunked sync protocol v2**
>
> Full-dataset single-message broadcasts approach addon-channel throttling
> as the roster + sim column count grows. Add `DATACHUNK` message type:
>
> ```lua
> { kind = "DATACHUNK", v = version, seq = N, total = N, chunk = payload }
> ```
>
> - Receiver accumulates in `BobleLootSyncDB.pendingChunks[sender][version]`;
>   promotes to `BobleLoot_Data` only when all `total` chunks arrive.
> - 30-second timeout discards incomplete transfers.
> - HELLO `pv = 2` negotiation; `pv = 1` peers fall back to full-DATA.
>
> Cross contract: data side owns chunking/reassembly. UI side shows a
> progress toast (via Batch 3.12) during transfer and a failure toast on
> timeout.

**Dependencies:** Batch 1C fully merged (proto v2, Adler32, HELLO negotiation, peers table). `release/v1.1.0` branch carries the authoritative Sync.lua that this plan extends. AceTimer-3.0 must be listed in the `.toc` mixin if not already present.

---

## File Structure

```
BobleLoot/
  Sync.lua          -- primary target; all chunking/reassembly logic lives here
  Core.lua          -- add `/bl syncinflight` slash command branch
  BobleLoot.toc     -- ensure AceTimer-3.0 mixin (verify, may already be present)
```

No new files are introduced. Chunking helpers are local functions inside `Sync.lua`; if the file exceeds ~600 lines of meaningful logic a `ChunkHelper` local table can be used as a namespace but the file is not split — WoW addon loading order concerns make single-file safer and the current Sync.lua is well within readable bounds.

---

## Wire-format v3 Reference

### Protocol version decision

This plan bumps `PROTO_VERSION` from `2` to `3`. The alternative was a `pv2_chunked = true` capability flag, but a version bump is simpler: `_checkProto` already gates on `MIN_PROTO_VERSION..PROTO_VERSION`, negotiation already uses `math.min(PROTO_VERSION, peer.pv)`, and a numeric comparison is unambiguous. The cap flag approach would require a separate capability-table check that has no reuse value. Decision: **`pv = 3`**. Document this in the file header.

### Updated constant table

| Constant | Old value | New value | Notes |
|---|---|---|---|
| `PROTO_VERSION` | `2` | `3` | Highest proto this client speaks |
| `MIN_PROTO_VERSION` | `1` | `1` | Still accept legacy clients |
| `SCHEMA_VERSION` | `1` | `1` | Unchanged; 2.7 owns schema bumps |
| `CHUNK_SIZE` | — | `2048` | Bytes of encoded output per chunk (see Size Tuning section) |
| `CHUNK_TIMEOUT` | — | `30` | Seconds before an incomplete transfer is discarded |
| `KIND_DATACHUNK` | — | `"DATACHUNK"` | New message kind string |

### HELLO envelope (updated)

| Field | Type | Required | Description |
|---|---|---|---|
| `kind` | string | yes | `"HELLO"` |
| `proto` | number | yes | Sender's current `PROTO_VERSION` (= `3` after this plan) |
| `v` | string | yes | `generatedAt` timestamp of sender's current dataset |
| `n` | number | yes | Character count in sender's dataset |
| `pv` | number | yes | Highest proto the sender speaks; used by receiver for negotiation. `3` for updated clients, `2` for Batch 1C clients, `1` for legacy clients. |

No new fields on HELLO. The `pv = 3` value is the signal that the sender supports DATACHUNK.

### REQ envelope (unchanged)

| Field | Type | Required | Description |
|---|---|---|---|
| `kind` | string | yes | `"REQ"` |
| `proto` | number | yes | Effective negotiated proto |
| `v` | string | yes | `generatedAt` of the version being requested |

### DATA envelope (unchanged — fallback path only)

| Field | Type | Required | Description |
|---|---|---|---|
| `kind` | string | yes | `"DATA"` |
| `proto` | number | yes | Effective negotiated proto (will be `<= 2` on this path post-plan) |
| `v` | string | yes | `generatedAt` of this dataset |
| `payload` | string | yes | Full WoWAddonChannel-encoded compressed serialized blob |
| `adler` | number | yes (proto >= 2) | `LibDeflate:Adler32(serialized)` over the pre-compression serialized string |

### DATACHUNK envelope (new)

| Field | Type | Required | Description |
|---|---|---|---|
| `kind` | string | yes | `"DATACHUNK"` |
| `proto` | number | yes | Must be `3`; receiver rejects DATACHUNK with proto != 3 |
| `v` | string | yes | `generatedAt` of the dataset being transferred; used as the buffer key |
| `seq` | number | yes | 1-based chunk sequence number; must satisfy `1 <= seq <= total` |
| `total` | number | yes | Total chunk count for this transfer; same in every envelope of a transfer |
| `chunk` | string | yes | Slice `seq` of the WoWAddonChannel-encoded compressed serialized blob |
| `adler` | number | yes | `LibDeflate:Adler32(serialized)` over the full pre-compression serialized string — identical in every chunk envelope of the same transfer; verified only after all chunks arrive |

The `adler` field is repeated in every chunk so the receiver does not need to store a separate out-of-band checksum; any chunk can supply it and the value is authoritative once reassembly completes.

### SETTINGS envelope (unchanged)

| Field | Type | Required | Description |
|---|---|---|---|
| `kind` | string | yes | `"SETTINGS"` |
| `proto` | number | yes | Current PROTO_VERSION |
| `transparency` | boolean | yes | Leader's current transparency setting |

### SCORES envelope (unchanged)

| Field | Type | Required | Description |
|---|---|---|---|
| `kind` | string | yes | `"SCORES"` |
| `proto` | number | yes | Current PROTO_VERSION |
| `iid` | number | yes | Item ID |
| `scores` | table | yes | `{ ["Name-Realm"] = number, ... }` |

---

## `BobleLootSyncDB.pendingChunks` Schema

2B prunes this table on startup. This plan defines the schema so 2B can act on it.

```lua
BobleLootSyncDB.pendingChunks = {
    ["SenderName"] = {
        ["2026-04-15T20:00:00Z"] = {   -- keyed by generatedAt / version string
            total      = 7,            -- number: total chunks expected
            received   = 3,            -- number: count of distinct seq received so far
            chunks     = {             -- [seq] = chunk_string; sparse array
                [1] = "...",
                [2] = "...",
                [3] = "...",
            },
            adler      = 1234567890,   -- number: Adler32 from the first chunk received
            startedAt  = 1713218400,   -- number: time() when first chunk arrived
            timerHandle = <AceTimer>,  -- opaque: cancel via addon:CancelTimer(handle)
        },
    },
}
```

**Schema invariants:**
- `chunks` is a sparse array indexed by `seq` (1-based). Missing keys are missing chunks.
- `received` counts distinct seq values written; duplicate seq values from a retry-spam are ignored (see Task 7).
- `adler` is set on first chunk arrival; subsequent chunks must carry the same value — mismatch causes the transfer to be dropped and a warning recorded.
- `timerHandle` is an AceTimer scheduled at first-chunk arrival; cancelled on successful reassembly or on timeout callback.
- On promotion (all chunks arrived and Adler32 passes), the entire `pendingChunks[sender][version]` entry is nilled.
- **2B's responsibility:** at `Sync:Setup()` time, call `Sync:PrunePendingChunks()` which nils the entire table. This plan exposes that function.

---

## Tasks

### Task 1 — Bump PROTO_VERSION and add constants

**Files:** `Sync.lua`

- [ ] 1.1 Update the file header comment block to document the v3 wire format and the DATACHUNK message kind. Add a line: `--   pv=3 clients use DATACHUNK for DATA transfers; pv<=2 peers receive full-DATA fallback.`

- [ ] 1.2 Change `PROTO_VERSION = 2` to `PROTO_VERSION = 3`.

- [ ] 1.3 Add the new constants immediately after the existing kind constants:

```lua
local KIND_DATACHUNK = "DATACHUNK"

-- Chunked transfer constants.
-- CHUNK_SIZE: bytes of WoWAddonChannel-encoded output per DATACHUNK envelope.
-- AceComm fragments at 4078 bytes; we stay well below to leave room for the
-- serialized envelope overhead (kind, proto, v, seq, total, adler fields).
-- See "Size Tuning" section of the implementation plan for derivation.
local CHUNK_SIZE     = 2048   -- bytes; tunable
local CHUNK_TIMEOUT  = 30     -- seconds; discard incomplete transfers after this
```

- [ ] 1.4 Expose `KIND_DATACHUNK` and `CHUNK_SIZE` on the `Sync` table for diagnostic use:

```lua
Sync.KIND_DATACHUNK = KIND_DATACHUNK
Sync.CHUNK_SIZE     = CHUNK_SIZE
Sync.CHUNK_TIMEOUT  = CHUNK_TIMEOUT
```

- [ ] 1.5 Verify (read) that `Sync.PROTO_VERSION` and `Sync.MIN_PROTO_VERSION` are already exposed on the `Sync` table from Batch 1C. They are; no change needed there.

---

### Task 2 — Add AceTimer mixin and in-flight state table

**Files:** `Sync.lua`, `BobleLoot.toc`

- [ ] 2.1 In `Sync:Setup`, after initializing `Sync.peers`, initialize the in-flight tracker:

```lua
-- In-flight transfer state; keyed by sender name then version string.
-- Mirrors BobleLootSyncDB.pendingChunks but the timer handles live here
-- (timers cannot be serialized into SavedVariables).
Sync._inFlight = {}   -- [sender][version] = { received=N, total=M, startedAt=t, timerHandle=h }
```

Note: `BobleLootSyncDB.pendingChunks` holds the chunk data; `Sync._inFlight` holds the parallel session-only metadata including the timer handle. They are kept in sync by the chunk-receive and cleanup helpers in Task 5.

- [ ] 2.2 Check `BobleLoot.toc` for `AceTimer-3.0` in the `## OptionalDeps` or `## Dependencies` line. If absent, add it. AceTimer-3.0 must also be mixed into the addon in `Core.lua`'s `AceAddon:NewAddon(...)` call if not already present. Read both files before editing.

The addon declaration in Core.lua currently reads:
```lua
local BobleLoot = AceAddon:NewAddon(ADDON_NAME,
    "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0", "AceSerializer-3.0")
```
If `AceTimer-3.0` is not in this list, add it so `addon:ScheduleTimer` and `addon:CancelTimer` are available.

- [ ] 2.3 Add a `Sync._addonRef` field set during `Sync:Setup(addon)` so timer callbacks can call `Sync:_onChunkTimeout(sender, version)` without capturing a local. Add this line at the top of `Sync:Setup`:

```lua
Sync._addonRef = addon
```

---

### Task 3 — Implement `encodeChunks` sender helper

**Files:** `Sync.lua`

This function takes the already-encoded full payload string (output of `LibDeflate:EncodeForWoWAddonChannel`) and slices it into a sequence of `CHUNK_SIZE`-byte strings.

- [ ] 3.1 Add the following local function after `encodeData` and `decodeData`:

```lua
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
```

- [ ] 3.2 Add a local function `reassembleChunks` that concatenates an ordered chunks table back into the full encoded string. The `chunks` argument is the sparse `[seq] = str` table from `pendingChunks`:

```lua
--- Reassemble a chunks table (sparse [seq]=str) into the full encoded payload.
-- Assumes all seq 1..total are present (caller verifies before calling).
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
```

---

### Task 4 — Implement `SendDataChunked`

**Files:** `Sync.lua`

`SendDataChunked` is the new send path used when the peer's `pv >= 3`. It replaces the single `send(...)` call currently in `SendData` for those peers.

- [ ] 4.1 Add `Sync:SendDataChunked(addon, target)` after `Sync:SendData`:

```lua
--- Send the current dataset to `target` as a sequence of DATACHUNK whispers.
-- Called when the negotiated proto is 3 (peer.pv >= 3).
-- Falls back to SendData (single-message path) on encoding failure.
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
    local v      = getDataVersion(data)

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
```

- [ ] 4.2 Modify `Sync:SendData` to branch on negotiated proto. The existing function body becomes the `pv <= 2` fallback path. Wrap the existing logic in an `if effectivePv < 3 then ... else ... end` block:

```lua
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
        adler   = adler,
    }, effectivePv), "WHISPER", target)
    addon:Print(string.format("sent dataset (%d chars) to %s [legacy DATA]",
        countChars(data), target))
end
```

---

### Task 5 — Implement chunk receive path and timeout

**Files:** `Sync.lua`

- [ ] 5.1 Add a cleanup helper that cancels the timer and removes both the `pendingChunks` entry and the `_inFlight` entry:

```lua
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
```

- [ ] 5.2 Add the timeout callback:

```lua
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
```

- [ ] 5.3 Add the chunk-receive handler `Sync:_onReceiveChunk(addon, msg, sender)`. This is called from `OnComm` when `msg.kind == KIND_DATACHUNK`. It contains all validation, accumulation, and reassembly logic:

```lua
--- Handle one incoming DATACHUNK envelope.
function Sync:_onReceiveChunk(addon, msg, sender)
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
        if not adlerEquals(entry.adler, adler) then
            self:_recordWarning(sender, string.format(
                "DATACHUNK adler mismatch across chunks from %s", sender))
            self:_cancelTransfer(sender, v)
            return
        end
    end

    -- Ignore duplicate seq (idempotent).
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

    -- Decode (decompress + deserialize).
    local data, serialized = decodeData(fullPayload)
    if not serialized then
        self:_recordWarning(sender, "DATACHUNK decode failure after reassembly")
        self:_cancelTransfer(sender, v)
        return
    end

    -- Verify Adler32 over the reassembled serialized string.
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
```

---

### Task 6 — Wire DATACHUNK into OnComm dispatch

**Files:** `Sync.lua`

- [ ] 6.1 In `Sync:OnComm`, add a `DATACHUNK` branch after the `KIND_DATA` branch. The full `elseif` block:

```lua
    elseif msg.kind == KIND_DATACHUNK then
        -- Only process DATACHUNK from proto=3 envelopes.
        -- _checkProto already confirmed proto is within [MIN,PROTO_VERSION];
        -- additionally gate that this specific kind requires proto=3.
        if not (msg.proto and msg.proto >= 3) then
            self:_recordWarning(sender, "DATACHUNK on proto < 3 rejected")
            return
        end
        -- Only accept from group members (same guard as DATA/SCORES).
        if not (UnitInRaid(sender) or UnitInParty(sender)) then return end
        self:_onReceiveChunk(addon, msg, sender)
```

- [ ] 6.2 Verify that the `_checkProto` gate at the top of `OnComm` still accepts proto=3 envelopes. After Task 1's constant change `PROTO_VERSION = 3`, the gate accepts `[MIN_PROTO_VERSION=1 .. PROTO_VERSION=3]`, so proto=3 passes. No change needed.

- [ ] 6.3 Update the existing `KIND_DATA` receive branch so it only applies the full-DATA path. The existing code is correct for proto <= 2 peers; the proto=3 chunked path arrives via `KIND_DATACHUNK` instead. Add a defensive comment:

```lua
    elseif msg.kind == KIND_DATA then
        -- This path handles the legacy single-message DATA transfer (proto <= 2 peers).
        -- proto=3 peers use DATACHUNK instead; a proto=3 peer should never send KIND_DATA
        -- but we tolerate it gracefully by processing it normally here.
        -- ... (existing code unchanged below)
```

---

### Task 7 — Expose `GetInflightTransfers` API and `PrunePendingChunks`

**Files:** `Sync.lua`

These are the two public contract functions required by the cross-plan boundary.

- [ ] 7.1 Add `Sync:GetInflightTransfers()` after `Sync:GetRecentWarnings()`:

```lua
--- Returns a snapshot of all currently in-flight chunked transfers.
-- Shape: { [senderName] = { received = N, total = M, startedAt = t } }
-- `startedAt` is a Unix timestamp (time()).
-- Consumed by plan 3.12 toast system's progress display.
-- Do not mutate the returned table.
function Sync:GetInflightTransfers()
    local result = {}
    if not self._inFlight then return result end
    for sender, versions in pairs(self._inFlight) do
        for version, entry in pairs(versions) do
            -- Return the most recent in-flight entry per sender.
            -- In practice there is at most one per sender at a time.
            if not result[sender] or entry.startedAt > result[sender].startedAt then
                result[sender] = {
                    received  = entry.received,
                    total     = entry.total,
                    startedAt = entry.startedAt,
                    version   = version,
                }
            end
        end
    end
    return result
end
```

- [ ] 7.2 Add `Sync:PrunePendingChunks()` — the function that plan 2B calls from `Sync:Setup` to discard stale chunk data from the previous session:

```lua
--- Discard all pending chunk data from BobleLootSyncDB.
-- Called by plan 2B's DB migration/prune step (and by Sync:Setup directly
-- until 2B is implemented). Any incomplete transfers from a prior session
-- are unresumable because AceTimer handles do not survive reload.
function Sync:PrunePendingChunks()
    if _G.BobleLootSyncDB then
        _G.BobleLootSyncDB.pendingChunks = {}
    end
    self._inFlight = {}
end
```

- [ ] 7.3 Call `Sync:PrunePendingChunks()` at the end of `Sync:Setup`, after initializing `_G.BobleLootSyncDB` and before restoring saved data. This ensures stale data from a prior session never reaches reassembly:

```lua
    -- Discard any chunks left over from a previous session (timers don't survive reload).
    -- Plan 2B will call this from its migration runner; until 2B ships, call it here.
    self:PrunePendingChunks()
```

---

### Task 8 — Update HELLO negotiation logging

**Files:** `Sync.lua`

- [ ] 8.1 In the `KIND_HELLO` receive branch of `OnComm`, update the negotiation log message to mention DATACHUNK capability:

```lua
        if peerPv ~= PROTO_VERSION then
            if not (self.peers[sender] and self.peers[sender]._pvLogged) then
                self.peers[sender]._pvLogged = true
                local chunkedNote = (math.min(PROTO_VERSION, peerPv) >= 3)
                    and " [DATACHUNK enabled]"
                    or  " [legacy DATA fallback]"
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "|cffffff00[BobleLoot]|r Proto negotiated with %s: speaking v%d%s " ..
                    "(peer max=%d, ours=%d)",
                    sender, math.min(PROTO_VERSION, peerPv), chunkedNote,
                    peerPv, PROTO_VERSION))
            end
        end
```

- [ ] 8.2 When `peerPv == PROTO_VERSION` (both v3), no log is emitted by the existing code. This is correct; no change needed. Both peers silently use DATACHUNK.

---

### Task 9 — Add `/bl syncinflight` slash command

**Files:** `Core.lua`

- [ ] 9.1 In `BobleLoot:OnSlashCommand`, add a branch for `"syncinflight"` before the final `else`:

```lua
    elseif input == "syncinflight" then
        if ns.Sync and ns.Sync.GetInflightTransfers then
            local transfers = ns.Sync:GetInflightTransfers()
            local count = 0
            for sender, info in pairs(transfers) do
                count = count + 1
                self:Print(string.format(
                    "  %s: %d/%d chunks (version %s, started %s ago)",
                    sender,
                    info.received,
                    info.total,
                    tostring(info.version),
                    tostring(math.floor(time() - info.startedAt)) .. "s"))
            end
            if count == 0 then
                self:Print("No chunked transfers currently in flight.")
            end
        else
            self:Print("Sync module not loaded.")
        end
```

- [ ] 9.2 Update the final help line in `OnSlashCommand` to include the new command:

```lua
    self:Print("Commands: /bl config | /bl minimap | /bl version | /bl broadcast | " ..
        "/bl transparency on|off | /bl checkdata | /bl lootdb | " ..
        "/bl debugchar <Name-Realm> | /bl test [N] | " ..
        "/bl score <itemID> <Name-Realm> | /bl syncwarnings | /bl syncinflight")
```

---

### Task 10 — Update file-header wire-format comment in Sync.lua

**Files:** `Sync.lua`

- [ ] 10.1 Extend the wire-format comment block at the top of `Sync.lua` to document the DATACHUNK kind and the v3 negotiation decision. Replace the existing `── Wire format ...` section with:

```
── Wire format (AceSerializer-encoded tables) ────────────────────────────────
  All envelopes carry:
    proto   [number]  Protocol version this message was encoded with.
                      Absent on v1 legacy messages (treated as proto=1).
                      PROTO_VERSION = 3 as of Batch 2C.

  HELLO    { kind="HELLO",    proto=N, v="<generatedAt>", n=<count>, pv=N }
             pv = highest proto the sender speaks (3 for Batch 2C clients).

  REQ      { kind="REQ",      proto=N, v="<generatedAt>" }
             Whisper to the HELLO sender requesting the named version.

  DATA     { kind="DATA",     proto=N, v="<generatedAt>",
             payload="<base64-like>", adler=<number> }
             Fallback path used only when negotiated proto < 3 (pv<=2 peer).
             payload = LibDeflate:EncodeForWoWAddonChannel(
                         LibDeflate:CompressDeflate(
                           AceSerializer:Serialize(data), {level=9}))
             adler   = LibDeflate:Adler32(AceSerializer:Serialize(data))

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
```

- [ ] 10.2 Update the `── Integrity ──` comment to note that DATACHUNK verifies Adler32 after reassembly rather than per-chunk.

---

### Task 11 — Update `_loggedAdlerWarn` reset scope

**Files:** `Sync.lua`

- [ ] 11.1 `_loggedAdlerWarn` currently throttles Adler32 rejection logs per sender for the DATA path. The DATACHUNK path uses `_recordWarning` directly (no per-sender gate) because each transfer attempt should be logged individually — a transfer failing every 30 seconds would spam without a per-transfer gate, but per-sender gating is too coarse. Add a per-transfer Adler32 warning key:

In `_onReceiveChunk`, the Adler32 mismatch branch already calls `_recordWarning` and then `_cancelTransfer` (which removes the entry). The warn is emitted once per transfer attempt by construction — no additional throttle needed. Verify this is correct and add a comment to document it.

- [ ] 11.2 Ensure `_loggedAdlerWarn` is not consulted or set in the DATACHUNK path; it remains exclusively for the legacy DATA path. Add a comment on the `_loggedAdlerWarn` field declaration making this explicit:

```lua
Sync._loggedAdlerWarn = {}   -- [sender] = true; throttle for legacy DATA path only
```

---

### Task 12 — Final integration check and defensive edge cases

**Files:** `Sync.lua`

- [ ] 12.1 Confirm that `decodeData` is called with the reassembled full payload string in `_onReceiveChunk`, not with a single chunk. The `fullPayload = reassembleChunks(...)` call precedes `decodeData(fullPayload)`. Verify the call site.

- [ ] 12.2 Add a guard in `_onReceiveChunk` for the case where `LibDeflate` is nil (the existing soft-fallback from Batch 1C). If `LibDeflate` is nil, log a warning and return early before reaching `decodeData`:

```lua
    if not LibDeflate then
        self:_recordWarning(sender, "DATACHUNK ignored: LibDeflate not available")
        return
    end
```
Place this check immediately after the field-validation block (step 5.3), before the `newerThan` check.

- [ ] 12.3 Confirm that `reassembleChunks` cannot be called with a `chunks` table that is a mixed-key table (both numeric and string keys). The schema defines `chunks` as `[seq] = string` (numeric keys only); the accumulation code in step 5.3 only writes `entry.chunks[seq] = chunk` with numeric `seq`. No risk; add a comment confirming this.

- [ ] 12.4 Add a safety check in `SendDataChunked` for the edge case where `encodeChunks` returns an empty sequence (payload was empty string). In practice `encodeData` on a non-nil dataset never returns an empty string, but defensively:

```lua
    if total == 0 then
        -- Degenerate: fall back to legacy DATA rather than sending zero chunks.
        addon:Print("warning: encoded payload is empty; falling back to legacy DATA send")
        self:SendData(addon, target)   -- will re-enter SendData but effectivePv < 3 check
        return
    end
```

Actually this creates infinite recursion if `effectivePv >= 3`. Use a direct fallback instead:

```lua
    if total == 0 then
        addon:Print("warning: encoded payload is empty; aborting send to " .. target)
        return
    end
```

- [ ] 12.5 Verify that no existing code in `Sync.lua` references `PROTO_VERSION` as a literal `2`; all uses should be through the constant. After the bump to `3`, literal `2` references would be bugs. Search the file and fix any found.

---

## Manual Verification Checklist

These are the only practical tests available (no Lua test runner). Each scenario requires two WoW clients logged into the same group.

### Scenario A — Both peers pv=3: chunked transfer succeeds

1. Client A: run `/bl broadcast`; observe chat: `"announcing dataset to raid."`
2. Client B: observe HELLO received; B's version is older; B sends REQ.
3. Client A: observe `"sending dataset to <B> in N chunk(s)"` message.
4. Client B: observe `"received dataset from <A> via N chunks (...) [Adler32 OK]"` message.
5. Client B: run `/bl score <itemID> <Name-Realm>` — confirm score matches Client A's.
6. Both: run `/bl syncinflight` — confirm "No chunked transfers currently in flight."

### Scenario B — pv=2 sender to pv=3 receiver: legacy DATA fallback

1. One client runs an artificially downgraded build (set `PROTO_VERSION = 2` locally before load).
2. That client broadcasts. The pv=3 receiver negotiates `effectivePv = min(3,2) = 2`.
3. pv=2 client sends KIND_DATA (single message). pv=3 receiver processes via the existing `KIND_DATA` branch.
4. Confirm dataset received and Adler32 OK message appears.
5. Confirm no DATACHUNK messages are sent (watch with `/bl syncwarnings`).

### Scenario C — pv=3 sender to pv=2 receiver: legacy DATA fallback

1. pv=3 sender receives HELLO from pv=2 peer. Negotiates `effectivePv = 2`.
2. Sender calls `SendData`; the `effectivePv < 3` branch executes; sends KIND_DATA.
3. pv=2 receiver processes normally. Confirm dataset received.
4. Sender: run `/bl syncinflight` — confirm no in-flight state (legacy path never creates it).

### Scenario D — Chunk drop: Adler32 rejects reassembled payload

1. Temporarily patch `_onReceiveChunk` to overwrite `fullPayload` with a corrupted string before `decodeData`.
2. Trigger a chunked transfer.
3. Confirm: `Adler32 mismatch` message appears in chat, `_cancelTransfer` fires, `BobleLoot_SyncTimedOut` event fires (observable via `/bl syncwarnings`).
4. Confirm: `BobleLoot_Data` is NOT updated to corrupted data.

### Scenario E — 30-second timeout: transfer never completes

1. Temporarily patch `_onReceiveChunk` to `return` after storing the first chunk, simulating a dropped transfer mid-stream.
2. Trigger a chunked transfer (5+ chunks).
3. Wait 30 seconds.
4. Confirm: `"Chunked transfer from <sender> timed out"` appears in chat.
5. Confirm: `/bl syncwarnings` lists the timeout entry.
6. Confirm: `BobleLootSyncDB.pendingChunks` entry is empty.
7. Confirm: `/bl syncinflight` shows no in-flight state.

### Scenario F — pv=1 legacy peer: no DATACHUNK sent

1. Client B has pre-1C build (no `pv` field in HELLO, treated as `pv=1`).
2. Client A (pv=3) receives HELLO; negotiates `effectivePv = min(3,1) = 1`.
3. Client A sends KIND_DATA (single message, no Adler32 field, proto=1).
4. Client B receives and processes normally (no verification).
5. Confirm: no DATACHUNK messages sent (watch addon traffic or `/bl syncwarnings`).

---

## Upgrade / Rollback Notes

### Forward compatibility: pv=3 client in a raid with pv=2 clients

- pv=3 sender calling `SendData` checks `effectivePv`; sends `KIND_DATA` to pv=2 targets.
- pv=3 receiver receiving `KIND_DATA` from a pv=2 sender processes via the existing `KIND_DATA` branch unchanged.
- No action required. The negotiation ensures the correct path is chosen per peer.

### Backward compatibility: pv=2 client in a raid with pv=3 clients

- pv=2 client's HELLO carries `pv=2`. pv=3 client negotiates down to effectivePv=2.
- pv=3 client sends `KIND_DATA` (single message) to the pv=2 client.
- pv=2 client processes `KIND_DATA` normally with its existing Batch 1C code.
- If the dataset is now large enough that the single `KIND_DATA` message hits the AceComm size limit, it will silently fail to deliver. This is the pre-existing risk that 2.8 mitigates; the only fix is to upgrade the pv=2 client.

### Rollback: reverting 2C after shipping

- Set `PROTO_VERSION` back to `2` and remove the `KIND_DATACHUNK` branch in `OnComm`.
- `BobleLootSyncDB.pendingChunks` entries are harmless left-over table data; 2B's startup prune will clear them on next load.
- No `BobleLoot_Data` corruption is possible from a rollback because `pendingChunks` entries are only promoted after full reassembly and Adler32 verification.

### What happens to in-flight transfers across a `/reload`

- AceTimer handles do not survive reload. Timer callbacks will never fire for pre-reload transfers.
- `Sync:PrunePendingChunks()` in `Sync:Setup` nils `pendingChunks` on every startup, so stale chunk data cannot be partially reassembled.
- The peer will see no acknowledgement and will not re-send automatically; the player can manually run `/bl broadcast` to restart the transfer.

---

## Size Tuning Note

**AceComm internals:** AceComm-3.0 splits outgoing messages at 250 bytes per addon-channel message and rate-limits at approximately 10 messages per second (2500 bytes/sec sustained throughput). The per-message limit is 250 encoded bytes, but AceComm handles splitting transparently — the effective limit on a single `SendCommMessage` call is not 250 bytes; AceComm will fragment large strings internally across multiple addon-channel messages and queue them.

**The real constraint** is the per-second throughput: if the full dataset is sent as one large string, AceComm queues all the fragments together and they compete with any other addon-channel traffic. By sending multiple discrete DATACHUNK envelopes, each DATACHUNK is a separately-serialized AceSerializer blob. AceComm BULK priority de-prioritises our traffic relative to NORMAL priority messages, which is correct.

**Why `CHUNK_SIZE = 2048`:**

Each DATACHUNK envelope contains the chunk string plus AceSerializer overhead for the `kind`, `proto`, `v`, `seq`, `total`, and `adler` fields. A typical v string (`"2026-04-15T20:00:00Z"`) is 20 characters; the other fields add roughly 60-80 bytes of AceSerializer overhead. Total envelope size ≈ 2048 + 80 = ~2128 bytes before AceComm fragmentation.

AceComm-3.0's per-fragment cap is 250 bytes, so a 2128-byte envelope becomes approximately `ceil(2128 / 250) = 9` addon-channel messages. Across a 5-chunk transfer (~10,000 bytes encoded), this is ~45 addon-channel messages total — well within the session throughput budget.

**If the dataset grows significantly** (e.g., 30+ characters with per-item sims), the encoded payload may reach 50–100 KB. At 2048-byte chunks that is 25–50 DATACHUNK envelopes, or 225–450 addon-channel messages. Sustained at BULK priority this takes 45–90 seconds to deliver at 5 messages/sec (Blizzard's documented sustained addon rate). If transfer times approach or exceed `CHUNK_TIMEOUT = 30`, reduce to `CHUNK_SIZE = 512` or extend `CHUNK_TIMEOUT`. The `CHUNK_SIZE` constant is deliberately not buried — tuning it is a one-line change.

**Recommended profiling step:** After shipping, add a `time()` measurement around `SendDataChunked` and print the wall-clock duration to confirm actual delivery time. If consistently > 20 seconds, halve `CHUNK_SIZE` and re-measure.

---

## Coordination Notes

### With plan 2B (DB migration framework + prune)

Plan 2B owns `BobleLootSyncDB.pendingChunks` pruning as an explicit deliverable (roadmap 2.7 states: "clean `BobleLootSyncDB.pendingChunks` on every startup"). This plan exposes `Sync:PrunePendingChunks()` and calls it from `Sync:Setup` as a temporary measure. When 2B ships its migration runner, 2B's `OnInitialize` migration sequence should call `ns.Sync:PrunePendingChunks()` as one step, and the direct call in `Sync:Setup` should be removed to avoid double-pruning (which is harmless but clutters the startup log).

The `pendingChunks` schema defined in this plan (Task 5 / the schema block above) is the authoritative definition that 2B prunes. 2B does not need to understand the internal structure — `BobleLootSyncDB.pendingChunks = {}` is the entire prune action.

### With plan 3.12 (toast notification system)

Plan 3.12's toast system consumes two AceEvents fired by this plan:

- `"BobleLoot_SyncProgress"` — fired after every successfully stored chunk. Arguments: `sender` (string), `received` (number), `total` (number). The toast system should show a progress string such as `"Syncing from Boble: 3/7 chunks"` and update in-place as subsequent events arrive for the same sender.
- `"BobleLoot_SyncTimedOut"` — fired when the 30-second timer expires. Arguments: `sender` (string). The toast system should show an error toast: `"Dataset sync from <sender> timed out — using local data."` (cross-references roadmap 4.12 empty/error state: `"Sync timeout — toast reading 'Dataset sync timed out — using local data.' rather than silence."`).

The toast system also uses `ns.Sync:GetInflightTransfers()` to poll current progress if it needs to refresh a persistent progress display. The returned table shape is documented in Task 7.1.

Plan 3.12 does not need to ship before 3.12 — the AceEvents fire into the void until a listener registers. No coupling in either direction prevents independent shipping order.

### With plans 2D and 2E (UI plans, this batch)

No coordination required. Plans 2D and 2E own `VotingFrame.lua` / `LootFrame.lua` exclusively. This plan does not touch those files.

### With plan 2A (scoring maturity)

No coordination required. Plan 2A owns `wowaudit.py` and `Scoring.lua`. The chunked sync protocol is payload-agnostic: whatever dataset `addon:GetData()` returns is serialized and chunked. 2A may increase payload size (more sim columns), which is the primary motivation for 2.8, but no API contract changes are needed.
