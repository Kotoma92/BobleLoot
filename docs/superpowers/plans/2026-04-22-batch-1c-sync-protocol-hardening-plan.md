# Batch 1C — Sync Protocol Hardening Implementation Plan

> **Agentic-workers note:** This plan is authored by the data/correctness AI agent
> and is intended for execution by Kotoma92 (data side). The UI side (separate agent)
> owns only the toast surface described in item 3.12 of the roadmap. This plan
> deliberately stops at the API boundary — `ns.Sync:GetRecentWarnings()` — and does
> not touch `VotingFrame.lua`, `LootFrame.lua`, `Config.lua`, or any other UI module.
> Coordination point: once this plan ships, the UI agent reads the wire-format
> reference at the bottom of this document before implementing the 3.12 toast.

---

## Goal

Harden the BobleLoot AceComm sync layer so that:

1. The persistence schema carries a version field usable by the Batch 2.7
   migration framework.
2. Every message on the wire carries an explicit protocol-version field,
   and receivers can safely drop messages from future or incompatible
   senders without deserializing garbage.
3. Every compressed DATA payload carries an Adler32 checksum; receivers
   reject payloads whose checksum does not match before decompressing.
4. A HELLO exchange negotiates the highest mutually-supported protocol
   version per peer, enabling graceful rollout alongside v1 clients.
5. All rejection events are recorded in a ring buffer accessible to the
   future toast system (plan 3.12) without that system existing yet.

---

## Architecture

The existing `Sync.lua` uses AceSerializer for envelope encoding and
LibDeflate + WoWAddonChannel encoding for the DATA payload blob. The
protocol is currently unversioned: no `proto` field exists on any
envelope, and no integrity check is performed on the compressed blob.

After this plan the envelope shape becomes:

```
{ kind = "...", proto = 2, ... }
```

Every sender attaches `proto = ns.Sync.PROTO_VERSION` via a single
`Sync:_wrap(tbl)` helper. Every receiver calls `Sync:_checkProto(msg,
sender)` before dispatching, which drops and logs anything with an
unknown proto value. DATA envelopes gain an `adler` field carrying
`LibDeflate:Adler32(serialized)` computed on the pre-compression
serialized string; the receiver verifies this before decompressing.

HELLO envelopes gain a `pv` field advertising the sender's highest
supported proto. The receiver records `ns.Sync.peers[sender].pv` and
subsequent DATA/SETTINGS/SCORES messages from that sender are sent at
`math.min(self.PROTO_VERSION, peer.pv)`.

No new files are introduced. All changes live in `Sync.lua` (the
protocol layer) and one line in `Core.lua` (the `schemaVersion`
idempotent write, delegated to `Sync:Setup`).

---

## Tech Stack

- **AceSerializer-3.0** — envelope serialization (unchanged)
- **LibDeflate** (LibStub) — compression + WoWAddonChannel encoding
  + `LibDeflate:Adler32(str)` for payload integrity (public API,
  confirmed in `RCLootCouncil/Libs/LibDeflate/LibDeflate.lua` line 349)
- **AceComm-3.0** — channel transport (unchanged)
- **Lua 5.1** (WoW runtime) — no external dependencies added

**CRC32 vs Adler32 decision:** LibDeflate exposes `LibDeflate:Adler32(str)`
as a documented public function (line 349 of the library). It does not
expose a CRC32 function. Adler32 is a valid payload integrity check —
it catches the same single-byte corruption and truncation cases that
CRC32 would catch in this context. The roadmap item (1.5) says "CRC32
(via LibDeflate's built-in)" but LibDeflate's built-in is Adler32, not
CRC32. This plan uses `LibDeflate:Adler32` and documents the choice.
No helper library is inlined. The wire-format reference at the end of
this document records the field name as `adler` so Kotoma92's side and
any future reader knows exactly which algorithm is in use.

---

## Roadmap items covered

### Item 1.4 `[Data]` — `BobleLootSyncDB.schemaVersion` field

> Write `BobleLootSyncDB.schemaVersion = 1` during `Sync:Setup()`. No
> migrations yet; the field exists so Batch 2's migration framework has
> a clean baseline to detect "old install, no version" vs "version 1".

### Item 1.5 `[Cross]` — Sync protocol versioning + CRC32

> Wire format currently has no version field on the outer envelope and no
> payload integrity check. Silent corruption is possible the first time a
> message shape changes.
>
> - Add `proto = 2` field to every AceSerializer envelope.
> - CRC32 (via LibDeflate's built-in) over every compressed payload.
> - Receiver rejects unrecognized `proto` and bad CRC; logs once per
>   session per sender; never deserializes garbage.
> - HELLO message advertises sender's highest supported `pv`; sender
>   speaks the minimum of both peers.
> - Protocol version bump means subsequent messages from this batch
>   (and Batch 2's chunked transfer) carry `proto = 2` onward.
>
> Cross contract: data side owns the wire format. UI side surfaces a
> muted warning toast (per Batch 3.12) when a rejected message is logged.

---

## File Structure

| File | Change scope |
|---|---|
| `Sync.lua` | All protocol work: constants, `_wrap`/`_checkProto` helpers, Adler32 on DATA, HELLO `pv` field, peer table, `GetRecentWarnings`, top-of-file wire-format comment |
| `Core.lua` | One line: `BobleLootSyncDB.schemaVersion` idempotent write, added inside the existing `Sync:Setup` call block in `OnEnable` — actually the write lives in `Sync:Setup` itself, so `Core.lua` needs no edit beyond what `Sync.lua` already provides via the existing `ns.Sync:Setup(self)` call |

No new files. No new TOC entries.

---

## Tasks

---

### Task 1 — Write `BobleLootSyncDB.schemaVersion = 1` in `Sync:Setup`

**Files:** `Sync.lua`, the `Sync:Setup` function (currently lines 245-277).

This is the baseline field that plan 2.7's migration framework will
read. The write must be idempotent: never clobber a higher version that
a future migration may have already written. The rule is:

```
if not existing or existing < SCHEMA_VERSION then write SCHEMA_VERSION
```

#### Steps

- [ ] **1.1** Open `Sync.lua`. Immediately below the `local PREFIX =`
  line, add the schema version constant alongside the protocol constants
  that Task 2 will introduce (we place all constants in one block; Task 2
  fills in the rest). For this task, add only `SCHEMA_VERSION`:

  ```lua
  -- Protocol and schema constants (see wire-format reference at bottom of plan).
  local SCHEMA_VERSION = 1   -- BobleLootSyncDB.schemaVersion; read by plan 2.7 migrations
  ```

- [ ] **1.2** Inside `Sync:Setup`, immediately after the line
  `_G.BobleLootSyncDB = _G.BobleLootSyncDB or {}`, add the idempotent
  schema version write:

  ```lua
  -- Write schema version. Idempotent: never clobber a higher version
  -- that a future migration (plan 2.7) may have already written.
  local sv = _G.BobleLootSyncDB.schemaVersion
  if not sv or sv < SCHEMA_VERSION then
      _G.BobleLootSyncDB.schemaVersion = SCHEMA_VERSION
  end
  ```

- [ ] **1.3** Verify in-game:

  ```
  /reload
  /dump BobleLootSyncDB.schemaVersion
  ```

  Expected output: `1`

  On a second `/reload` without clearing SavedVariables, the value must
  still be `1` (idempotency confirmed: the guard did not overwrite).

- [ ] **1.4** Commit:

  ```
  git add Sync.lua
  git commit -m "Add BobleLootSyncDB.schemaVersion = 1 in Sync:Setup (roadmap 1.4)"
  ```

---

### Task 2 — Define protocol constants in one place

**Files:** `Sync.lua`, top of file (the constant block started in Task 1).

All protocol magic numbers live here. No other function in `Sync.lua`
hard-codes `2` or `1` for protocol versions.

#### Steps

- [ ] **2.1** Expand the constant block to its final shape:

  ```lua
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
  ```

- [ ] **2.2** Expose `PROTO_VERSION` on the `Sync` table so other modules
  (and future plans) can read the current version without reaching into
  local scope:

  ```lua
  -- Expose for external inspection (e.g., diagnostics, plan 3.12 toast).
  Sync.PROTO_VERSION     = PROTO_VERSION
  Sync.MIN_PROTO_VERSION = MIN_PROTO_VERSION
  ```

  Place these two lines immediately after `ns.Sync = Sync`.

- [ ] **2.3** Verify:

  ```
  /reload
  /dump ns.Sync.PROTO_VERSION
  /dump ns.Sync.MIN_PROTO_VERSION
  ```

  Expected: `2` and `1` respectively. (`ns` is the BobleLoot addon
  namespace; in the WoW console, access it as the second return of the
  addon vararg. If `ns` is not directly accessible at the console, use
  `/run print(BobleLoot.version)` first to confirm the addon is loaded,
  then `/run local _,n=...; print(n.Sync.PROTO_VERSION)` — or just
  verify via Task 8's full scenario.)

- [ ] **2.4** Commit:

  ```
  git add Sync.lua
  git commit -m "Add protocol version constants: PROTO_VERSION=2, MIN_PROTO_VERSION=1 (roadmap 1.5)"
  ```

---

### Task 3 — Add `proto` field to every outgoing envelope via `_wrap`

**Files:** `Sync.lua` — the `send` helper and all six `SendXxx` functions.

A single `Sync:_wrap(tbl)` helper stamps `proto` onto every outgoing
table so no sender duplicates the logic. The existing local `send`
function is unchanged in signature; it is the callers that pass
pre-wrapped tables.

#### Steps

- [ ] **3.1** Add the `_wrap` helper immediately above the `send` local
  function:

  ```lua
  -- Stamp the proto version onto every outgoing envelope.
  -- Pass a proto override when speaking to a known older peer (Task 5).
  function Sync:_wrap(tbl, protoOverride)
      tbl.proto = protoOverride or PROTO_VERSION
      return tbl
  end
  ```

- [ ] **3.2** Update `Sync:SendHello` to wrap before sending:

  ```lua
  function Sync:SendHello(addon)
      local data = addon:GetData()
      local v = getDataVersion(data)
      if not v then return end
      local dist = channel()
      if not dist then return end
      -- pv = highest proto this client speaks; negotiated per Task 5.
      send(addon, self:_wrap({ kind = KIND_HELLO, v = v, n = countChars(data), pv = PROTO_VERSION }), dist)
  end
  ```

- [ ] **3.3** Update `Sync:SendRequest`:

  ```lua
  function Sync:SendRequest(addon, target, version)
      -- REQ is a whisper; speak at the peer's negotiated proto if known.
      local peerPv = self.peers and self.peers[target] and self.peers[target].pv
      local effectivePv = peerPv and math.min(PROTO_VERSION, peerPv) or PROTO_VERSION
      send(addon, self:_wrap({ kind = KIND_REQ, v = version }, effectivePv), "WHISPER", target)
  end
  ```

- [ ] **3.4** Update `Sync:SendData` (Adler32 is added in Task 6;
  for now just add `proto`):

  ```lua
  function Sync:SendData(addon, target)
      local data = addon:GetData()
      if not data then return end
      local payload = encodeData(data)
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
          -- adler field added in Task 6
      }, effectivePv), "WHISPER", target)
      addon:Print(string.format("sent dataset (%d chars) to %s", countChars(data), target))
  end
  ```

- [ ] **3.5** Update `Sync:SendSettings`:

  ```lua
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
  ```

- [ ] **3.6** Update `Sync:SendScores`:

  ```lua
  function Sync:SendScores(addon, itemID, scores)
      if not isLeader() then return end
      local dist = channel()
      if not dist then return end
      if not itemID or type(scores) ~= "table" then return end

      self._lastSentScores = self._lastSentScores or {}
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
  ```

- [ ] **3.7** Replace the string literals in `OnComm`'s dispatch with
  the kind constants (consistency pass; catches future typos):

  Replace:
  ```lua
  if msg.kind == "HELLO" then
  elseif msg.kind == "REQ" then
  elseif msg.kind == "SETTINGS" then
  elseif msg.kind == "SCORES" then
  elseif msg.kind == "DATA" then
  ```
  With:
  ```lua
  if msg.kind == KIND_HELLO then
  elseif msg.kind == KIND_REQ then
  elseif msg.kind == KIND_SETTINGS then
  elseif msg.kind == KIND_SCORES then
  elseif msg.kind == KIND_DATA then
  ```

- [ ] **3.8** Commit:

  ```
  git add Sync.lua
  git commit -m "Stamp proto version onto all outgoing envelopes via Sync:_wrap (roadmap 1.5)"
  ```

---

### Task 4 — Reject unrecognized `proto` on receive, log once per sender

**Files:** `Sync.lua` — `Sync:OnComm`, new `Sync:_checkProto` helper.

A v2 client may receive a message from a future v3 sender before the
client upgrades. It must not attempt to deserialize or act on that
message. It also must not spam the log — one warning per session per
sender is enough.

#### Steps

- [ ] **4.1** Add the `_loggedProtoWarn` table to `Sync` (session-scoped,
  not persisted):

  ```lua
  Sync._loggedProtoWarn = {}   -- [sender] = true; throttle proto-rejection logs
  ```

  Place this with the other session-state initializations near the top of
  `Sync.lua`, below the constant block.

- [ ] **4.2** Add the `_checkProto` helper:

  ```lua
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
  ```

- [ ] **4.3** Insert the proto check as the very first gate inside
  `Sync:OnComm`, immediately after the existing `sender == UnitName`
  guard and the AceSerializer decode:

  ```lua
  function Sync:OnComm(addon, prefix, message, dist, sender)
      if prefix ~= PREFIX then return end
      if sender == UnitName("player") then return end

      local ok, msg = AceSerializer:Deserialize(message)
      if not ok or type(msg) ~= "table" or not msg.kind then return end

      -- Proto-version gate: drop anything outside our supported range.
      if not self:_checkProto(msg, sender) then return end

      -- ... rest of dispatch unchanged
  ```

- [ ] **4.4** Verify (single-client): after this change, a hand-crafted
  bad-proto message should be rejectable. Use the in-game test scenario
  in Task 8; for now just confirm the addon loads without Lua error:

  ```
  /reload
  /run print("Sync loaded OK, proto=" .. tostring(ns.Sync.PROTO_VERSION))
  ```

  Expected: `Sync loaded OK, proto=2`

- [ ] **4.5** Commit:

  ```
  git add Sync.lua
  git commit -m "Reject and log unrecognized proto versions in OnComm (roadmap 1.5)"
  ```

---

### Task 5 — HELLO exchange: advertise `pv`, track per-peer negotiated proto

**Files:** `Sync.lua` — `Sync:OnComm` HELLO branch, `Sync.peers` table.

When a HELLO arrives, record the sender's advertised `pv`. Future
outgoing messages to that sender speak `math.min(PROTO_VERSION, peer.pv)`
so the communication degrades gracefully when an unupgraded client is
present. The `SendRequest`, `SendData` functions in Task 3 already read
`self.peers[target].pv`; this task populates that table.

#### Steps

- [ ] **5.1** Initialize the peer table in `Sync:Setup` (session-scoped,
  reset on each load — we re-learn peers via HELLO on every login and
  GROUP_ROSTER_UPDATE):

  ```lua
  Sync.peers = {}   -- [senderName] = { pv = N }; populated on HELLO receive
  ```

  Add this line immediately after `_G.BobleLootSyncDB.schemaVersion` write.

- [ ] **5.2** Rewrite the `KIND_HELLO` branch of `OnComm`:

  ```lua
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
  ```

- [ ] **5.3** Verify the negotiation path logs correctly. In a two-client
  scenario (see Task 8) the leader's chat frame should print the
  negotiation line on first HELLO from an older peer.

  Single-client smoke test:

  ```
  /reload
  /dump ns.Sync.peers
  ```

  Expected with no group: empty table `{}`.

- [ ] **5.4** Commit:

  ```
  git add Sync.lua
  git commit -m "HELLO pv field: track per-peer negotiated proto version (roadmap 1.5)"
  ```

---

### Task 6 — Adler32 on DATA payloads: compute on send, verify on receive

**Files:** `Sync.lua` — `encodeData`, `decodeData`, `Sync:SendData`,
`OnComm` DATA branch.

The Adler32 is computed on the **serialized string** (after
`AceSerializer:Serialize` but before `LibDeflate:CompressDeflate`).
This catches corruption of the compressed blob and also catches
truncation by the addon channel. The `adler` field is sent in the
outer AceSerializer envelope alongside `payload`.

**Why pre-compression?** The Adler32 is computed on the human-readable
(well, AceSerializer-encoded) string rather than the binary compressed
blob because `LibDeflate:Adler32` operates on a Lua string and the
pre-compression string is directly available. Post-decompression
verification would also work but requires decompressing first (which
may crash on a corrupted payload). Pre-compression Adler32 means we
can verify integrity without ever touching the compressed bytes.

#### Steps

- [ ] **6.1** Refactor `encodeData` to return the Adler32 alongside the
  encoded payload so `SendData` can attach it to the envelope:

  ```lua
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
  ```

- [ ] **6.2** Update `Sync:SendData` to attach `adler` to the envelope:

  ```lua
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
  ```

- [ ] **6.3** Add the `_loggedAdlerWarn` throttle table alongside the
  proto-warn table:

  ```lua
  Sync._loggedAdlerWarn = {}   -- [sender] = true; throttle Adler32-rejection logs
  ```

- [ ] **6.4** Refactor `decodeData` to return the serialized string
  alongside the decoded data so the caller can verify Adler32 before
  decompression (or at minimum before trusting the result). Because we
  compute Adler32 pre-compression (on the serialized string), we must
  decompress first, then verify. This is safe because decompression
  itself cannot corrupt memory in Lua — it either returns a string or
  `nil`:

  ```lua
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
  ```

- [ ] **6.5** Update the `KIND_DATA` branch of `OnComm` to verify
  Adler32 before acting on the payload:

  ```lua
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
  ```

  **Note on the two-return `decodeData`:** All other callers of
  `decodeData` only used the first return value. After this refactor,
  the `decodeData` call in the old proto=1 fallback path uses
  `local data = decodeData(msg.payload)` which correctly gets only the
  first return. Lua silently discards extra returns.

- [ ] **6.6** Verify single-client (no group needed):

  ```
  /reload
  /run print("adler test:", LibStub("LibDeflate"):Adler32("hello"))
  ```

  Expected: a non-zero integer (e.g. `\d+`). Exact value doesn't matter
  for this step; confirming `LibDeflate:Adler32` is callable in-process
  is the check.

- [ ] **6.7** Commit:

  ```
  git add Sync.lua
  git commit -m "Add Adler32 integrity check on DATA payloads (roadmap 1.5)"
  ```

---

### Task 7 — `ns.Sync:GetRecentWarnings()` — API for future toast system

**Files:** `Sync.lua` — new `_warnings` ring buffer + `_recordWarning` +
`GetRecentWarnings`.

Plan 3.12 (toast notification system) will poll or be called by whatever
mechanism the UI side chooses. This plan defines only the data layer: a
ring buffer of the last 20 warning events, each a table with `time`,
`sender`, and `reason`. The UI side reads this; it does not write to it.

#### Steps

- [ ] **7.1** Initialize the warnings ring buffer alongside the other
  session-state tables in `Sync.lua` (top-level, not inside Setup):

  ```lua
  Sync._warnings     = {}   -- ring buffer; max WARNINGS_MAX entries
  local WARNINGS_MAX = 20
  ```

- [ ] **7.2** Add the `_recordWarning` internal method:

  ```lua
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
  ```

- [ ] **7.3** Add the public accessor:

  ```lua
  --- Returns the most recent sync warnings (up to 20), newest last.
  -- Each entry: { time = <unix seconds>, sender = <string>, reason = <string> }
  -- Consumed by plan 3.12 toast system. Do not modify the returned table.
  function Sync:GetRecentWarnings()
      return self._warnings
  end
  ```

- [ ] **7.4** Confirm `_recordWarning` is called in both rejection paths
  (already inserted in Tasks 4 and 6). Grep to verify:

  ```
  grep "_recordWarning" Sync.lua
  ```

  Expected: at least three occurrences (proto rejection, Adler32
  mismatch, decode failure).

- [ ] **7.5** Expose a slash-command diagnostic so Kotoma92 can inspect
  the warning buffer in-game without waiting for the toast UI. Add a
  branch to `Core.lua`'s `OnSlashCommand`:

  In `Core.lua`, inside `BobleLoot:OnSlashCommand`, add after the
  `lootdb` branch:

  ```lua
  elseif input == "syncwarnings" or input == "syncwarn" then
      if ns.Sync and ns.Sync.GetRecentWarnings then
          local w = ns.Sync:GetRecentWarnings()
          if #w == 0 then
              self:Print("No sync warnings this session.")
          else
              self:Print(string.format("%d sync warning(s) this session:", #w))
              for i, entry in ipairs(w) do
                  self:Print(string.format("  [%d] %s from %s: %s",
                      i,
                      date("%H:%M:%S", entry.time),
                      entry.sender,
                      entry.reason))
              end
          end
      end
  ```

  Also update the help string in the `else` branch of `OnSlashCommand`
  to include `syncwarnings`:

  ```lua
  self:Print("Commands: /bl config | /bl version | /bl broadcast | " ..
      "/bl transparency on|off | /bl checkdata | /bl lootdb | " ..
      "/bl debugchar <Name-Realm> | /bl test [N] | " ..
      "/bl score <itemID> <Name-Realm> | /bl syncwarnings")
  ```

- [ ] **7.6** Verify:

  ```
  /reload
  /bl syncwarnings
  ```

  Expected: `No sync warnings this session.`

- [ ] **7.7** Commit:

  ```
  git add Sync.lua Core.lua
  git commit -m "Add GetRecentWarnings ring buffer and /bl syncwarnings diagnostic (roadmap 1.5)"
  ```

---

### Task 8 — Manual verification scenarios

**Files:** None (in-game testing procedure).

There is no Lua test framework. Verification requires two WoW clients
logged into the same group, ideally on two machines or using the WoW
test realm's multi-account feature. The scenarios below are ordered
from easiest (single client) to hardest (two clients, injected corruption).

#### Scenario A — Fresh install: schemaVersion written

**Setup:** Delete or rename `BobleLootSyncDB` from your SavedVariables
file (`WTF/Account/.../SavedVariables/BobleLoot.lua`) so the addon
starts with no prior sync DB. Alternatively, use `/run BobleLootSyncDB =
nil` then `/reload`.

**Steps:**

```
/run BobleLootSyncDB = nil
/reload
/dump BobleLootSyncDB.schemaVersion
```

**Expected:** `1`

**Steps (idempotency):**

```
/reload
/dump BobleLootSyncDB.schemaVersion
```

**Expected:** still `1` (guard did not clobber).

---

#### Scenario B — Two v2-proto clients handshake (normal case)

**Setup:** Two WoW clients both running the updated BobleLoot, both in
the same party or raid. Client A is the leader with a loaded dataset.
Client B has no dataset (or an older version).

**On Client A:**

```
/reload
/run ns.Sync:SendHello(BobleLoot)
```

**On Client B (after ~1 second):**

```
/dump ns.Sync.peers
```

**Expected on Client B:** a table entry for `["ClientAName"] = { pv = 2, _pvLogged = nil or true }`
— or no `_pvLogged` key at all since both speak v2 (no negotiation
downgrade was needed, so the log line is suppressed).

**Expected on Client A:** if Client B auto-replied with its own HELLO
(via GROUP_ROSTER_UPDATE), Client A's peer table similarly has
`ClientBName` with `pv = 2`.

**On Client A, push data:**

```
/bl broadcast
```

**On Client B (after ~2 seconds):**

```
/dump BobleLoot_Data.generatedAt
/bl syncwarnings
```

**Expected:** `generatedAt` matches the dataset on Client A. No sync
warnings.

---

#### Scenario C — v1 peer simulation (downgrade path)

**Purpose:** Verify that a v2 client receiving a v1-style HELLO (no `pv`
field) correctly defaults `peerPv = 1`, logs the negotiation once, and
does not crash.

**Setup (single client is sufficient):** Use the in-game console to
call `OnComm` directly with a hand-crafted v1 HELLO. This requires
constructing a serialized message. The easiest approach is to call the
internal `OnComm` via the raw AceComm callback bypass.

**Steps:**

```lua
/run
local ser = LibStub("AceSerializer-3.0")
local fakeHello = ser:Serialize({ kind = "HELLO", v = "2020-01-01T00:00:00", n = 5 })
-- No proto field, no pv field (authentic v1 shape)
ns.Sync:OnComm(BobleLoot, "BobleLootSync", fakeHello, "RAID", "TestSender-Realm")
```

**Expected:** No Lua error. In `DEFAULT_CHAT_FRAME`, a yellow
negotiation line:

```
[BobleLoot] Proto negotiated with TestSender-Realm: speaking v1 (peer max=1, ours=2)
```

(Because `msg.proto` is nil → `_checkProto` treats it as proto=1 which
is within `MIN_PROTO_VERSION=1`..`PROTO_VERSION=2`, so the message
passes the proto gate. The HELLO branch then records `pv=1` and logs
the downgrade.)

**Verify the peer table:**

```
/dump ns.Sync.peers["TestSender-Realm"]
```

**Expected:** `{ pv = 1, _pvLogged = true }`

---

#### Scenario D — Unknown proto (future version rejection)

**Purpose:** Verify that a message with `proto = 9` (hypothetical future
version) is logged and dropped.

**Steps:**

```lua
/run
local ser = LibStub("AceSerializer-3.0")
local futureMsg = ser:Serialize({ kind = "HELLO", proto = 9, pv = 9, v = "2030-01-01", n = 0 })
ns.Sync:OnComm(BobleLoot, "BobleLootSync", futureMsg, "RAID", "FutureSender-Realm")
```

**Expected:** A red rejection line in chat:

```
[BobleLoot] Dropped message from FutureSender-Realm: unsupported proto 9 (supported 1-2)
```

**Verify warning buffer:**

```
/bl syncwarnings
```

**Expected:**

```
1 sync warning(s) this session:
  [1] HH:MM:SS from FutureSender-Realm: unsupported proto 9
```

**Verify second call does NOT produce a second chat line** (once-per-session
throttle):

```lua
/run
local ser = LibStub("AceSerializer-3.0")
local futureMsg = ser:Serialize({ kind = "HELLO", proto = 9, pv = 9, v = "2030-01-01", n = 0 })
ns.Sync:OnComm(BobleLoot, "BobleLootSync", futureMsg, "RAID", "FutureSender-Realm")
```

**Expected:** No new chat line. Warning buffer still has exactly 1 entry
(confirmed via `/bl syncwarnings`).

---

#### Scenario E — Corrupted payload (Adler32 rejection)

**Purpose:** Verify that a DATA envelope with a bad `adler` field is
rejected before any data is applied.

**Steps:**

```lua
/run
local ser = LibStub("AceSerializer-3.0")
local ld  = LibStub("LibDeflate")
-- Build a valid payload but supply a wrong adler.
local realData = BobleLoot_Data or { characters = {}, generatedAt = "test" }
local serialized = ser:Serialize(realData)
local compressed = ld:CompressDeflate(serialized, { level = 9 })
local encoded    = ld:EncodeForWoWAddonChannel(compressed)
local badAdler   = 12345  -- deliberately wrong
local fakeData   = ser:Serialize({
    kind    = "DATA",
    proto   = 2,
    v       = "9999-01-01T00:00:00",  -- newer than anything we have
    payload = encoded,
    adler   = badAdler,
})
ns.Sync:OnComm(BobleLoot, "BobleLootSync", fakeData, "WHISPER", "CorruptSender-Realm")
```

**Expected:** A red rejection line:

```
[BobleLoot] Dropped data from CorruptSender-Realm: Adler32 mismatch (got <N>, expected 12345)
```

**Verify data was NOT applied:**

```
/dump BobleLoot_Data.generatedAt
```

**Expected:** the previous generatedAt value, NOT `"9999-01-01T00:00:00"`.

**Verify warning buffer:**

```
/bl syncwarnings
```

**Expected:** entry from `CorruptSender-Realm` with reason containing
`Adler32 mismatch`.

---

### Task 9 — Code-doc pass: top-of-file wire-format comment in `Sync.lua`

**Files:** `Sync.lua` — replace the existing file-level comment block.

The existing header describes the v1 wire format. Replace it with a
comment that describes v2, documents the Adler32 choice, and lists the
negotiation rules, so any future contributor can understand the protocol
without reading git history.

#### Steps

- [ ] **9.1** Replace the existing `--[[ Sync.lua ... ]]` block at the
  top of the file with:

  ```lua
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
  ```

- [ ] **9.2** Commit:

  ```
  git add Sync.lua
  git commit -m "Replace Sync.lua file comment with v2 wire-format protocol documentation"
  ```

---

## Wire-Format Reference

This table is the single authoritative record of the v2 envelope shape.
Kotoma92's side and any future implementer should consult this table
before sending or receiving BobleLootSync messages.

| Field | Type | Present on | Description |
|---|---|---|---|
| `kind` | string | all messages | `"HELLO"`, `"REQ"`, `"DATA"`, `"SETTINGS"`, `"SCORES"` |
| `proto` | number | all messages | Protocol version used by the sender. Absent on v1 legacy clients (treat as `1`). Always `2` in v1.1. |
| `pv` | number | HELLO only | Sender's highest supported proto. Used for negotiation. Absent on v1 HELLOs (treat as `1`). |
| `v` | string | HELLO, REQ, DATA | ISO-8601 `generatedAt` timestamp from `wowaudit.py`. Determines which peer is the data master. |
| `n` | number | HELLO only | Character count in sender's dataset. Informational. |
| `payload` | string | DATA only | `LibDeflate:EncodeForWoWAddonChannel(LibDeflate:CompressDeflate(AceSerializer:Serialize(data)))` |
| `adler` | number | DATA only (proto >= 2) | `LibDeflate:Adler32(AceSerializer:Serialize(data))` — computed **before** compression. Compared mod 2^32. |
| `transparency` | boolean | SETTINGS only | Whether transparency mode is active. Leader-only. |
| `iid` | number | SCORES only | Item ID for which scores are being broadcast. |
| `scores` | table | SCORES only | `{ ["Name-Realm"] = number }` map of computed scores for `iid`. |

**Checksum algorithm note:** LibDeflate exposes `LibDeflate:Adler32(str)`
as a documented public function. It does not expose a CRC32 function.
The roadmap item 1.5 refers to "CRC32 (via LibDeflate's built-in)" but
LibDeflate's built-in checksum is Adler32. This implementation uses
Adler32. Both are adequate for detecting random corruption and truncation
in an addon channel. The field is named `adler` (not `crc`) in the wire
format to prevent confusion.

**Comparison rule:** `(actual % 4294967296) == (envelope.adler % 4294967296)`.
This matches LibDeflate's own `IsEqualAdler32` logic and handles the
unsigned/signed duality across different Lua runtime widths.

---

## Manual Verification Checklist

Complete all five scenarios in Task 8 in order. Record pass/fail for
each step before committing the final version.

| # | Scenario | Key check | Pass criteria |
|---|---|---|---|
| A | Fresh install | `/dump BobleLootSyncDB.schemaVersion` | Returns `1` |
| A | Idempotency | Second `/reload`, same dump | Still `1`, not incremented |
| B | Two v2 clients, handshake | `/dump ns.Sync.peers` on each | Both have `pv = 2` for each other |
| B | Two v2 clients, data transfer | `/dump BobleLoot_Data.generatedAt` on receiver | Matches sender's version; no syncwarnings |
| C | v1 peer simulation | Fake HELLO, no `pv` field | Yellow negotiation line in chat; peer.pv = 1 |
| C | v1 second call | Same fake HELLO again | No second yellow line (throttle works) |
| D | Future proto (proto=9) | Fake HELLO with proto=9 | Red rejection line; `/bl syncwarnings` shows entry |
| D | Future proto second call | Same fake again | No second red line |
| E | Corrupt Adler32 | Fake DATA with wrong adler | Red mismatch line; BobleLoot_Data.generatedAt unchanged |
| E | Corrupt Adler32 warning | `/bl syncwarnings` | Shows CorruptSender-Realm entry with Adler mismatch reason |

---

## Upgrade and Rollback Notes

### v2 client receiving from v1 client

A v1 client's HELLO has no `pv` field and no `proto` field. The
`_checkProto` helper treats absent `proto` as `proto = 1`, which falls
within `MIN_PROTO_VERSION = 1`..`PROTO_VERSION = 2`. The message is
accepted. The HELLO branch defaults `peerPv = 1` and logs the downgrade.
Subsequent messages to that peer use `effectivePv = 1`.

The v1 client's DATA envelope also has no `proto` and no `adler` field.
The DATA branch checks `if msg.proto and msg.proto >= 2 and msg.adler ~=
nil` — for a v1 message all three conditions fail, so it falls into the
legacy code path (no Adler32 verification). This is correct: the
degradation is intentional and documented.

### v1 client receiving from v2 client

A v1 client uses the old `OnComm` with no proto gate. When it receives a
v2 envelope (`{ kind="HELLO", proto=2, pv=2, ... }`), AceSerializer will
decode the table, the `msg.kind` dispatch will run normally (kind is still
`"HELLO"`), and the extra fields (`proto`, `pv`) will be silently ignored.
The v1 client will still request data if the version is newer.

When the v2 client responds with a DATA envelope, it will speak at the
negotiated proto. If the peer is known (HELLO already received), the
v2 client speaks `effectivePv = min(2, 1) = 1` and attaches no `adler`
field in that branch. **Wait** — `SendData` always attaches `adler`
regardless of effectivePv (Task 3.4 / Task 6.2). The v1 client will
receive an envelope with an `adler` field it does not recognize and will
silently ignore it, then proceed to decode the payload. This is safe.

**If HELLO was never received** (the v1 client joined after our HELLO
was sent), `self.peers[target]` is nil, `effectivePv` defaults to
`PROTO_VERSION = 2`, and the full v2 envelope is sent. The v1 client
ignores `proto` and `adler` and decodes the payload successfully.

There is no scenario in which a v1 client cannot receive data from a
v2 sender. The wire format is strictly additive.

### Rollback (reverting this plan)

Rolling back `Sync.lua` to the v1 commit removes `proto`, `pv`, `adler`,
`_checkProto`, `_wrap`, `GetRecentWarnings`, and the peer table. The
`BobleLootSyncDB.schemaVersion` field written to disk is harmless —
the reverted `Sync:Setup` simply does not reference it. Plan 2.7's
migration framework (which consumes it) has not shipped yet, so no
migration code will run. The field can be cleaned up manually via
`/run BobleLootSyncDB.schemaVersion = nil` if desired, but it causes
no harm if left in place.

The `/bl syncwarnings` slash-command branch in `Core.lua` must also be
reverted; it references `ns.Sync:GetRecentWarnings` which would no
longer exist after the rollback.
