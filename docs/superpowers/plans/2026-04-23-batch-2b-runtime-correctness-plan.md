# Batch 2B — Runtime Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate three classes of silent runtime failures — unauthorised dataset injection via DATA messages, stale leader-score caches surviving a leadership handoff, and a missing schema-migration pathway that would otherwise leave legacy fields and unbounded SyncDB growth unaddressed.

**Architecture:** Authorization hardening adds a `UnitIsGroupLeader` check to the DATA branch of `Sync:OnComm`, backed by a per-character whitelist (`BobleLootSyncDB.trustedSenders`) so a non-leader officer can still push data when the leader is AFK. Event-driven cache invalidation registers the `PARTY_LEADER_CHANGED` WoW event via AceEvent in `Core.lua` and clears `addon._leaderScores` immediately on receipt, then fires a LootFrame refresh. The migration framework introduces `BobleLootDB.profile.dbVersion`, a sequential `Migrations` table in a dedicated `Migrations.lua` module called from `OnInitialize`, and an automatic SyncDB prune in `Sync:Setup` that removes stale data older than 90 days and clears any `pendingChunks` table left over from 2C.

**Tech Stack:** Lua (WoW 10.x), AceDB for persistence, AceEvent for `PARTY_LEADER_CHANGED`, AceConsole for the new `/bl trustedsender` sub-command

**Roadmap items covered:** 2.5, 2.6, 2.7

> **2.5 `[Data]` Tighten sender identity check for DATA messages**
> `Sync.lua:OnComm` currently checks `UnitIsGroupLeader(sender)` for SETTINGS and SCORES but not for DATA. A non-leader with a forged `generatedAt` timestamp can push an arbitrary dataset. Add the leader check to DATA. Extend to a configurable `BobleLootSyncDB.trustedSenders` whitelist so a non-leader officer can still share a fresh dataset if the leader is AFK.

> **2.6 `[Data]` Invalidate cached `addon._leaderScores` on leader change**
> Transparency mode caches the leader's computed scores as `addon._leaderScores`. When leadership passes mid-raid, these stale scores remain visible until the next voting-frame open. Register `PARTY_LEADER_CHANGED`; clear the cache.

> **2.7 `[Data]` DB migration framework + automatic `BobleLootSyncDB` prune**
> Add `BobleLootDB.profile.dbVersion` (initially absent = 0). On `OnInitialize`, run a sequential `Migrations` table; each migration is idempotent and bumps `dbVersion`. First real migration converts any legacy `mplusScore` fields to `mplusDungeons = 0` with a log warning. Also: prune `BobleLootSyncDB.data` older than 90 days in `Sync:Setup`; clean `BobleLootSyncDB.pendingChunks` (from 2C) on every startup.

**Dependencies:** Batch 1 fully merged (1C `Sync.lua` proto v2 + peer table + `GetRecentWarnings` ring buffer, 1E `Core.lua` with new slash pattern + `SettingsPanel` Data tab, 1A not required but data-file consumers should tolerate `dbVersion = nil`).

---

## File Structure

```
BobleLoot/
├── BobleLoot.toc              -- add Migrations.lua entry (after Core.lua)
├── Core.lua                   -- PARTY_LEADER_CHANGED handler, migration runner call,
│                              --   /bl trustedsender slash sub-command
├── Migrations.lua             -- NEW: sequential migration table + runner
├── Sync.lua                   -- DATA leader+whitelist check, SyncDB prune in Setup,
│                              --   trustedSenders helpers
└── UI/
    └── SettingsPanel.lua      -- optional: "Trusted senders" read-only disclosure
                               --   appended to the existing Data tab
```

### Key invariants

- `Migrations.lua` is loaded before `Sync.lua` and after `Core.lua` in the TOC; the runner itself is called from `Core:OnInitialize` before `Sync:Setup` fires (which happens in `OnEnable`).
- `BobleLootSyncDB.trustedSenders` is a flat array of `"Name-Realm"` strings, never a hash, so it survives AceDB serialization without surprises.
- Migrations are one-way and additive. Rolling back means reverting the commit, not touching SavedVariables.
- The SyncDB prune in `Sync:Setup` is intentionally non-configurable: 90 days is long enough to survive a tier gap and short enough to keep DB size bounded.

---

## Task 1 — Add `Migrations.lua` skeleton to the TOC

**Files:** `BobleLoot.toc`

- [ ] 1.1 Open `BobleLoot.toc`. After the `Core.lua` line and before `Scoring.lua`, insert `Migrations.lua`:

  ```
  Core.lua
  Migrations.lua
  Scoring.lua
  ```

- [ ] 1.2 Verify the TOC parse order is correct by reading the file back. The loader executes files top-to-bottom, so `Migrations.lua` must precede any module that calls `ns.Migrations:Run`.

**Verification:** `/reload` in-game produces no "module not found" errors in the system log; `ns.Migrations` is non-nil after login.

---

## Task 2 — Create `Migrations.lua`

**Files:** `Migrations.lua` (new file)

This module owns the versioned migration table and the idempotent runner. It deliberately imports nothing from `Sync.lua` or `UI/`; it reads only `BobleLootDB.profile` (passed by the caller).

- [ ] 2.1 Create `Migrations.lua` with the following content:

  ```lua
  --[[ Migrations.lua — BobleLoot SavedVariables migration framework
       Roadmap item 2.7.

       Usage (called once from Core:OnInitialize, after AceDB:New):
         ns.Migrations:Run(addon)

       Each entry in Migrations.STEPS is a table:
         { version = N, run = function(profile, addon) ... end }

       Invariants:
         - Steps must be listed in ascending version order.
         - Each `run` function MUST be idempotent.
         - Each `run` function MUST NOT raise an error; use pcall internally
           for risky operations.
         - After a step completes, dbVersion is bumped to step.version.
         - Steps whose version <= current dbVersion are skipped entirely.
  ]]

  local ADDON_NAME, ns = ...
  local Migrations = {}
  ns.Migrations = Migrations

  -- ── Migration steps ──────────────────────────────────────────────────────
  --
  -- Add new steps here. Increment `version` sequentially.
  -- NEVER remove or reorder existing steps.

  Migrations.STEPS = {

      -- v1: Convert legacy `mplusScore` character fields to `mplusDungeons = 0`.
      --
      -- Background: older wowaudit.py builds emitted `mplusScore` (a raider.io
      -- numeric score, typically 0-4000). Scoring.lua already falls back via
      -- `char.mplusDungeons or char.mplusScore`, so live scoring is unaffected.
      -- This migration removes the field so the fallback path is never triggered
      -- on data that has gone through the pipeline, making future debugging less
      -- confusing.
      --
      -- The migration touches BobleLoot_Data (the global Lua data file), not
      -- BobleLootDB. BobleLoot_Data is loaded fresh on every /reload and is
      -- normally regenerated by wowaudit.py, so this migration is a one-time
      -- cleanup that fires once per character's profile version = 0 session.
      -- It is safe to run repeatedly because we nil-guard the mplusScore field.
      {
          version = 1,
          run = function(profile, addon)
              local data = _G.BobleLoot_Data
              if not data or type(data.characters) ~= "table" then return end

              local converted = 0
              for name, char in pairs(data.characters) do
                  if char.mplusScore ~= nil then
                      -- Preserve existing mplusDungeons if already present;
                      -- otherwise fall to 0 (unknown dungeon count).
                      if char.mplusDungeons == nil then
                          char.mplusDungeons = 0
                      end
                      char.mplusScore = nil
                      converted = converted + 1
                  end
              end

              if converted > 0 then
                  local msg = string.format(
                      "|cffffff00[BobleLoot]|r Migration v1: converted %d legacy "
                      .. "|cffffcc00mplusScore|r field(s) to |cffffcc00mplusDungeons = 0|r. "
                      .. "Regenerate BobleLoot_Data.lua with the latest wowaudit.py "
                      .. "to populate accurate dungeon counts.",
                      converted)
                  DEFAULT_CHAT_FRAME:AddMessage(msg)
              end
          end,
      },

      -- Future migrations go here.
      -- { version = 2, run = function(profile, addon) ... end },

  }

  -- ── Runner ───────────────────────────────────────────────────────────────

  --- Run all pending migrations against the active profile.
  -- Called once from Core:OnInitialize immediately after AceDB:New.
  -- @param addon  The BobleLoot AceAddon instance (for db.profile access).
  function Migrations:Run(addon)
      if not addon or not addon.db or not addon.db.profile then
          -- AceDB not yet initialised; skip silently.
          return
      end

      local profile = addon.db.profile

      -- dbVersion absent means this is a pre-2.7 install (treat as 0).
      local currentVersion = profile.dbVersion or 0

      for _, step in ipairs(self.STEPS) do
          if step.version > currentVersion then
              local ok, err = pcall(step.run, profile, addon)
              if ok then
                  profile.dbVersion = step.version
              else
                  -- Log the failure but continue so subsequent migrations still run.
                  DEFAULT_CHAT_FRAME:AddMessage(string.format(
                      "|cffff5555[BobleLoot]|r Migration v%d FAILED: %s",
                      step.version, tostring(err)))
              end
          end
      end
  end
  ```

- [ ] 2.2 Double-check: confirm that `Migrations.STEPS` has exactly one entry at `version = 1` after this task. The runner will write `profile.dbVersion = 1` on any install that has loaded at least one data file with characters.

**Verification:** After `/reload` on a clean install, `/bl config` opens without error. After a reload with an older `BobleLoot_Data.lua` containing `mplusScore` fields, the chat frame shows the migration warning once; a second `/reload` produces no warning (idempotency).

---

## Task 3 — Wire `Migrations:Run` into `Core:OnInitialize`

**Files:** `Core.lua`

The migration runner must fire after `AceDB:New` (so `self.db.profile` is available) but before `Sync:Setup` (which happens in `OnEnable`). `OnInitialize` is the right hook.

- [ ] 3.1 In `Core.lua`, inside `BobleLoot:OnInitialize`, add the `Migrations:Run` call immediately after `AceDB:New`:

  ```lua
  function BobleLoot:OnInitialize()
      self.db = AceDB:New("BobleLootDB", DB_DEFAULTS, true)

      -- Run schema migrations before any module reads db.profile.
      if ns.Migrations and ns.Migrations.Run then
          ns.Migrations:Run(self)
      end

      self:RegisterChatCommand("bl",       "OnSlashCommand")
      self:RegisterChatCommand("bobleloot","OnSlashCommand")

      if ns.SettingsPanel and ns.SettingsPanel.Setup then
          ns.SettingsPanel:Setup(self)
      end
  end
  ```

- [ ] 3.2 Add `dbVersion = 0` to `DB_DEFAULTS.profile` so AceDB initialises the field on a brand-new install (avoids a first-run nil that the runner has to special-case):

  ```lua
  local DB_DEFAULTS = {
      profile = {
          -- ... existing fields ...
          dbVersion = 0,   -- bumped by Migrations:Run; see Migrations.lua
          -- ...
      },
  }
  ```

  Place it near the end of the profile block, after `panelPos`, to keep diffs readable.

**Verification:** `/script print(BobleLootDB.profiles.Default.dbVersion)` in-game prints `1` (or `0` on a totally fresh install before data is loaded). The value persists across reloads.

---

## Task 4 — Implement the DATA sender-identity check in `Sync.lua`

**Files:** `Sync.lua`

The current `OnComm` handler accepts DATA from any peer as long as it advertises a newer `generatedAt`. SETTINGS and SCORES already gate on `UnitIsGroupLeader(sender)`. DATA must do the same, with a whitelist fallback.

- [ ] 4.1 In `Sync.lua`, add a module-level helper that evaluates whether a given sender is authorized to push a DATA payload. Place it in the helpers section, below `inGroup()` and above `encodeData`:

  ```lua
  -- Returns true if `sender` is permitted to push a DATA payload.
  -- Authorization hierarchy (first match wins):
  --   1. sender is the current group leader
  --   2. sender appears in BobleLootSyncDB.trustedSenders whitelist
  --   3. deny
  local function isAuthorizedDataSender(sender)
      -- Group leader always authorized.
      if UnitIsGroupLeader(sender) then return true end

      -- Whitelist check (see /bl trustedsender command).
      local db = _G.BobleLootSyncDB
      if db and type(db.trustedSenders) == "table" then
          local senderLower = sender:lower()
          for _, trusted in ipairs(db.trustedSenders) do
              if type(trusted) == "string" and trusted:lower() == senderLower then
                  return true
              end
          end
      end

      return false
  end
  ```

- [ ] 4.2 Inside `Sync:OnComm`, locate the `elseif msg.kind == KIND_DATA then` block (currently the last branch). At the very top of that block, before the `newerThan` version check, insert the authorization gate:

  ```lua
  elseif msg.kind == KIND_DATA then
      -- Authorization: only the group leader or a whitelisted sender
      -- may push a dataset (roadmap 2.5).
      if not isAuthorizedDataSender(sender) then
          if not self._loggedDataAuthWarn then self._loggedDataAuthWarn = {} end
          if not self._loggedDataAuthWarn[sender] then
              self._loggedDataAuthWarn[sender] = true
              DEFAULT_CHAT_FRAME:AddMessage(string.format(
                  "|cffff6666[BobleLoot]|r Dropped DATA from %s: not the group leader "
                  .. "and not in trustedSenders whitelist.",
                  sender))
              self:_recordWarning(sender, "DATA from unauthorized sender")
          end
          return
      end

      local mine = getDataVersion(addon:GetData())
      if not newerThan(msg.v, mine) then return end
      -- ... remainder of existing DATA handling unchanged ...
  ```

  The warning is logged once per sender per session (same throttle pattern as `_loggedProtoWarn`).

- [ ] 4.3 Add `_loggedDataAuthWarn = {}` to the session-scoped state block at the top of `Sync.lua`, alongside the existing `_loggedProtoWarn` and `_loggedAdlerWarn` declarations:

  ```lua
  Sync._loggedProtoWarn    = {}   -- [sender] = true; throttle proto-rejection logs
  Sync._loggedAdlerWarn    = {}   -- [sender] = true; throttle Adler32-rejection logs
  Sync._loggedDataAuthWarn = {}   -- [sender] = true; throttle DATA-auth rejection logs
  Sync._warnings           = {}   -- ring buffer; max WARNINGS_MAX entries
  ```

**Verification:** In a two-client test (one leader, one non-leader non-whitelisted), trigger a DATA send from the non-leader client. Confirm the leader client prints the rejection message in chat. Confirm `ns.Sync:GetRecentWarnings()` contains an entry with `reason = "DATA from unauthorized sender"`.

---

## Task 5 — Implement `trustedSenders` management helpers in `Sync.lua`

**Files:** `Sync.lua`

The whitelist lives in `BobleLootSyncDB.trustedSenders` (a plain array, initialized in `Sync:Setup`). Public helpers expose add/remove/list so `Core.lua` can wire them to the slash command.

- [ ] 5.1 In `Sync:Setup`, initialize `trustedSenders` if absent:

  ```lua
  function Sync:Setup(addon)
      _G.BobleLootSyncDB = _G.BobleLootSyncDB or {}

      -- Schema version (from Batch 1C, item 1.4).
      local sv = _G.BobleLootSyncDB.schemaVersion
      if not sv or sv < SCHEMA_VERSION then
          _G.BobleLootSyncDB.schemaVersion = SCHEMA_VERSION
      end

      -- Trusted senders whitelist (item 2.5): initialize if absent.
      if type(_G.BobleLootSyncDB.trustedSenders) ~= "table" then
          _G.BobleLootSyncDB.trustedSenders = {}
      end

      -- ... existing peer table and data restore logic unchanged ...
  end
  ```

- [ ] 5.2 Add the three public helpers after `Sync:Setup`:

  ```lua
  --- Add a character to the trustedSenders whitelist.
  -- @param name  "Name-Realm" string (case-insensitive match; stored as given).
  -- Returns true if added, false if already present.
  function Sync:AddTrustedSender(name)
      local db = _G.BobleLootSyncDB
      if not db or type(name) ~= "string" or name == "" then return false end
      local nameLower = name:lower()
      for _, existing in ipairs(db.trustedSenders) do
          if type(existing) == "string" and existing:lower() == nameLower then
              return false   -- already present
          end
      end
      table.insert(db.trustedSenders, name)
      return true
  end

  --- Remove a character from the trustedSenders whitelist.
  -- @param name  "Name-Realm" string (case-insensitive match).
  -- Returns true if removed, false if not found.
  function Sync:RemoveTrustedSender(name)
      local db = _G.BobleLootSyncDB
      if not db or type(name) ~= "string" then return false end
      local nameLower = name:lower()
      for i, existing in ipairs(db.trustedSenders) do
          if type(existing) == "string" and existing:lower() == nameLower then
              table.remove(db.trustedSenders, i)
              return true
          end
      end
      return false
  end

  --- Return a copy of the current trustedSenders list (for display only).
  function Sync:GetTrustedSenders()
      local db = _G.BobleLootSyncDB
      if not db or type(db.trustedSenders) ~= "table" then return {} end
      local copy = {}
      for _, v in ipairs(db.trustedSenders) do copy[#copy + 1] = v end
      return copy
  end
  ```

**Verification:** `/script BobleLoot:OnSlashCommand("trustedsender add Testchar-Realm")` — character appears in `BobleLootSyncDB.trustedSenders`. `/script BobleLoot:OnSlashCommand("trustedsender remove Testchar-Realm")` — list is empty again. Output persists across `/reload`.

---

## Task 6 — Add `/bl trustedsender` slash sub-command in `Core.lua`

**Files:** `Core.lua`

Follow the exact shape of the existing branches in `BobleLoot:OnSlashCommand`. The sub-command supports three verbs: `add`, `remove`, `list`.

- [ ] 6.1 In `BobleLoot:OnSlashCommand`, add a new `elseif` branch before the final `else` clause. Pattern: `input:match("^trustedsender ")`:

  ```lua
  elseif input:match("^trustedsender%s") then
      if not UnitIsGroupLeader("player") then
          self:Print("only the group leader can manage trusted senders.")
          return
      end
      local verb, name = input:match("^trustedsender%s+(%a+)%s*(.*)$")
      verb = verb and verb:lower() or ""
      name = name and name:trim() or ""

      if verb == "add" then
          if name == "" then
              self:Print("Usage: /bl trustedsender add <Name-Realm>")
              return
          end
          if ns.Sync and ns.Sync.AddTrustedSender then
              if ns.Sync:AddTrustedSender(name) then
                  self:Print(string.format("Added trusted sender: %s", name))
              else
                  self:Print(string.format("%s is already in the trusted senders list.", name))
              end
          end

      elseif verb == "remove" then
          if name == "" then
              self:Print("Usage: /bl trustedsender remove <Name-Realm>")
              return
          end
          if ns.Sync and ns.Sync.RemoveTrustedSender then
              if ns.Sync:RemoveTrustedSender(name) then
                  self:Print(string.format("Removed trusted sender: %s", name))
              else
                  self:Print(string.format("%s was not in the trusted senders list.", name))
              end
          end

      elseif verb == "list" then
          if ns.Sync and ns.Sync.GetTrustedSenders then
              local list = ns.Sync:GetTrustedSenders()
              if #list == 0 then
                  self:Print("Trusted senders list is empty.")
              else
                  self:Print(string.format("Trusted senders (%d):", #list))
                  for i, v in ipairs(list) do
                      self:Print(string.format("  [%d] %s", i, v))
                  end
              end
          end

      else
          self:Print("Usage: /bl trustedsender add|remove|list [<Name-Realm>]")
      end
  ```

- [ ] 6.2 Update the help string at the bottom of `OnSlashCommand` (the final `else` branch) to include the new sub-command:

  ```lua
  self:Print("Commands: /bl config | /bl minimap | /bl version | /bl broadcast | " ..
      "/bl transparency on|off | /bl checkdata | /bl lootdb | " ..
      "/bl debugchar <Name-Realm> | /bl test [N] | " ..
      "/bl score <itemID> <Name-Realm> | /bl syncwarnings | " ..
      "/bl trustedsender add|remove|list [<Name-Realm>]")
  ```

**Verification:** `/bl trustedsender list` prints the empty state. `/bl trustedsender add Boble-Silvermoon` adds. `/bl trustedsender list` shows the entry. `/bl trustedsender remove Boble-Silvermoon` removes. All commands when issued by a non-leader print the leader-only message.

---

## Task 7 — Register `PARTY_LEADER_CHANGED` and invalidate `_leaderScores`

**Files:** `Core.lua`

`addon._leaderScores` is a session table written by `Sync:OnComm` when a SCORES message arrives. It is keyed by `itemID`. On a leadership handoff, the new leader will broadcast fresh SCORES for the current item at the next voting-frame open, but until then the stale table misleads the transparency label.

- [ ] 7.1 In `BobleLoot:OnEnable`, register the event immediately after the existing event wiring in `Sync:Setup` (which already registers `GROUP_ROSTER_UPDATE` and `PLAYER_ENTERING_WORLD`). Add the registration in `OnEnable` rather than inside `Sync:Setup` to keep Core.lua the single owner of all AceEvent registrations:

  ```lua
  function BobleLoot:OnEnable()
      if ns.Sync and ns.Sync.Setup then
          ns.Sync:Setup(self)
      end
      if ns.RaidReminder and ns.RaidReminder.Setup then
          ns.RaidReminder:Setup(self)
      end
      if ns.LootHistory and ns.LootHistory.Setup then
          ns.LootHistory:Setup(self)
      end
      if ns.MinimapButton and ns.MinimapButton.Setup then
          ns.MinimapButton:Setup(self)
      end

      -- 2.6: Invalidate leader score cache when group leadership changes.
      self:RegisterEvent("PARTY_LEADER_CHANGED", "OnPartyLeaderChanged")

      -- Hook RCLootCouncil if present; otherwise wait for it to load.
      if not self:TryHookRC() then
          self:RegisterEvent("ADDON_LOADED", "OnAddonLoaded")
      end
  end
  ```

- [ ] 7.2 Add the handler method to `BobleLoot`:

  ```lua
  --- 2.6: Clear the stale leader-scores cache when leadership passes mid-raid.
  -- Transparency mode rebuilds the cache automatically on the next SCORES
  -- broadcast from the new leader.
  function BobleLoot:OnPartyLeaderChanged()
      if self._leaderScores then
          local count = 0
          for _ in pairs(self._leaderScores) do count = count + 1 end
          self._leaderScores = nil
          if count > 0 then
              -- Inform (once) so the outgoing leader knows their data was cleared.
              DEFAULT_CHAT_FRAME:AddMessage(string.format(
                  "|cffffff00[BobleLoot]|r Leader changed — cleared cached scores "
                  .. "for %d item(s). Transparency data will update on next item.",
                  count))
          end
      end

      -- Force a LootFrame refresh so the score column re-reads from the
      -- now-nil cache rather than showing a stale value.
      if ns.LootFrame and ns.LootFrame.Refresh then
          ns.LootFrame:Refresh()
      end
  end
  ```

- [ ] 7.3 Verify the event fires correctly by inspecting the WoW API: `PARTY_LEADER_CHANGED` fires on both leader-to-member and member-to-leader transitions. The handler should run on both because the outgoing leader also needs their local cache cleared.

**Verification:** In a two-client test (or using a /run script to simulate), set `addon._leaderScores = { [123] = { ["Player-Realm"] = 75 } }` on one client. Fire `PARTY_LEADER_CHANGED` via `/run BobleLoot:OnPartyLeaderChanged()`. Confirm the cache is `nil` and the chat message appears. A second call confirms the nil-guard doesn't error.

---

## Task 8 — Automatic `BobleLootSyncDB` prune in `Sync:Setup`

**Files:** `Sync.lua`

Two prune operations run at every startup:
1. Remove entries from `BobleLootSyncDB.data.characters` whose loot history entries are older than 90 days. (More precisely: prune the entire `BobleLootSyncDB.data` blob if its `generatedAt` timestamp is older than 90 days — we treat the whole snapshot as a unit, matching how `Setup` already restores it.)
2. Clear `BobleLootSyncDB.pendingChunks` (owned by plan 2C). At 2B ship time this table may not exist; the prune is a forward-compatibility measure.

- [ ] 8.1 Define the prune constants at the top of `Sync.lua`, alongside the protocol constants:

  ```lua
  local SCHEMA_VERSION        = 1
  local PROTO_VERSION         = 2
  local MIN_PROTO_VERSION     = 1
  local SYNCDB_PRUNE_DAYS     = 90   -- prune synced data older than this (item 2.7)
  local SYNCDB_PRUNE_SECONDS  = SYNCDB_PRUNE_DAYS * 86400
  ```

- [ ] 8.2 In `Sync:Setup`, after the `trustedSenders` init block (from Task 5.1) and before the data-restore logic, add the prune block:

  ```lua
  -- ── SyncDB prune (roadmap 2.7) ─────────────────────────────────────────
  -- 1. Remove stale data snapshots.
  local db = _G.BobleLootSyncDB
  local now = time()

  if db.data and db.data.generatedAt then
      -- generatedAt is an ISO-8601 string from wowaudit.py (e.g. "2026-01-15T22:00:00Z").
      -- We cannot parse ISO-8601 in vanilla Lua; instead we compare against the
      -- OS timestamp BobleLootSyncDB.dataStoredAt, which Sync writes when it
      -- first saves the data. Fall back to `now` (never prune) if absent.
      local storedAt = db.dataStoredAt
      if storedAt and type(storedAt) == "number" then
          if (now - storedAt) > SYNCDB_PRUNE_SECONDS then
              db.data      = nil
              db.dataStoredAt = nil
              DEFAULT_CHAT_FRAME:AddMessage(string.format(
                  "|cffffff00[BobleLoot]|r Pruned synced dataset older than %d days.",
                  SYNCDB_PRUNE_DAYS))
          end
      end
  end

  -- 2. Clear pendingChunks (plan 2C forward-compat).
  if db.pendingChunks ~= nil then
      db.pendingChunks = nil
  end
  ```

- [ ] 8.3 Ensure `dataStoredAt` is written whenever `BobleLootSyncDB.data` is updated via a received DATA message. In `Sync:OnComm`, locate both DATA write points (`_G.BobleLootSyncDB.data = data`) and add the timestamp immediately after each one:

  ```lua
  _G.BobleLootSyncDB.data      = data
  _G.BobleLootSyncDB.dataStoredAt = time()   -- for 90-day prune (item 2.7)
  ```

  There are two such write points in the existing `KIND_DATA` branch (one in the Adler32-verified path and one in the proto-1 fallback path). Both must be updated.

**Verification:** Manually set `BobleLootSyncDB.dataStoredAt = time() - (91 * 86400)` in a `/run` block, then `/reload`. Confirm the chat message "Pruned synced dataset..." appears. Confirm `BobleLootSyncDB.data` is nil post-reload. Confirm a second reload produces no prune message (nil data means nothing to prune).

---

## Task 9 — Add "Trusted senders" disclosure to the Data tab

**Files:** `UI/SettingsPanel.lua`

This is a read-only disclosure section — no drag-reorder or in-panel add/remove. The full management interface is the slash command. The panel shows the list so the leader can sanity-check without typing `/bl trustedsender list`.

- [ ] 9.1 In `BuildDataTab`, after the closing of the `transCard` / `transInner` block and before the `body:SetScript("OnShow", ...)` closure, insert a new card:

  ```lua
  -- ── Trusted senders card (item 2.5) ───────────────────────────────────
  -- Read-only display. Management via /bl trustedsender add|remove|list.
  local tsCard, tsInner = MakeSection(body, "Trusted senders")
  tsCard:SetPoint("TOPLEFT",     body, "BOTTOMLEFT",  6,  -4)  -- below transCard
  tsCard:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -6,  0)
  -- Note: adjust pixel offsets to fit within BODY_H after card layout is reviewed.

  local tsLbl = tsInner:CreateFontString(nil, "OVERLAY")
  tsLbl:SetFont(T.fontBody, T.sizeBody)
  tsLbl:SetTextColor(T.white[1], T.white[2], T.white[3])
  tsLbl:SetPoint("TOPLEFT", tsInner, "TOPLEFT", 4, -2)
  tsLbl:SetWidth(480)
  tsLbl:SetJustifyV("TOP")

  local tsHintLbl = tsInner:CreateFontString(nil, "OVERLAY")
  tsHintLbl:SetFont(T.fontBody, T.sizeSmall)
  tsHintLbl:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
  tsHintLbl:SetPoint("TOPLEFT", tsLbl, "BOTTOMLEFT", 0, -4)
  tsHintLbl:SetWidth(480)
  tsHintLbl:SetText("/bl trustedsender add|remove|list <Name-Realm>")
  ```

- [ ] 9.2 Inside `body:SetScript("OnShow", function() ... end)`, add the trusted-senders refresh block alongside the existing `updateInfoLabel()` call:

  ```lua
  -- Refresh trusted senders list.
  if ns.Sync and ns.Sync.GetTrustedSenders then
      local list = ns.Sync:GetTrustedSenders()
      if #list == 0 then
          tsLbl:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
          tsLbl:SetText("(none — leader and all group members are trusted by default)")
      else
          tsLbl:SetTextColor(T.white[1], T.white[2], T.white[3])
          tsLbl:SetText(table.concat(list, "\n"))
      end
  end
  ```

- [ ] 9.3 Sanity-check that the new card fits within `BODY_H = 360` pixels. If the existing three cards (infoCard, actCard, transCard) plus the new tsCard overflow, reduce `infoCard`'s height by 30px by adjusting its `BOTTOMRIGHT` anchor offset. Document the chosen offsets in a comment above the card.

**Verification:** Open `/bl config`, switch to the Data tab. With an empty whitelist, the label shows the muted placeholder text. After `/bl trustedsender add Testchar-Realm`, close and reopen the tab — the name appears in the list.

---

## Task 10 — Integration smoke test and final consistency pass

**Files:** All modified files

- [ ] 10.1 Reload the game client with all changes applied. Confirm no Lua errors appear in the system log (`/run print(GetErrorText and GetErrorText() or "no API")`).

- [ ] 10.2 Run the following in-game verification sequence:

  **Migration (2.7):**
  - `/script print(BobleLootDB.profiles.Default.dbVersion)` → should print `1` (or `0` on a fresh install with no data file).
  - If you have a data file with characters, confirm `mplusScore` fields are gone: `/script local c = next(BobleLoot_Data.characters); print(BobleLoot_Data.characters[c].mplusScore)` → should print `nil`.

  **SyncDB prune (2.7):**
  - `/run BobleLootSyncDB.dataStoredAt = time() - (91 * 86400)` then `/reload`. The chat should show the prune notice.
  - Confirm `BobleLootSyncDB.pendingChunks` is nil on startup even if you injected a value in the previous session.

  **DATA authorization (2.5):**
  - On a non-leader alt, attempt to trigger a DATACHUNK (or simulate via `/run ns.Sync:SendData(addon, UnitName("player"))`). Confirm the leader client shows the rejection warning in chat.
  - Add the alt to the whitelist: `/bl trustedsender add AltName-Realm`. Repeat the DATA send — this time it should be accepted.

  **Leader change (2.6):**
  - `/run addon._leaderScores = {[1]={"Player-Realm"=99}}` then `/run BobleLoot:OnPartyLeaderChanged()`. Confirm `addon._leaderScores` is nil and the chat notice appeared.

- [ ] 10.3 Confirm `BobleLoot.toc` loads `Migrations.lua` before `Scoring.lua`. Check by temporarily inserting a `print("Migrations loaded")` in `Migrations.lua` and verifying order of prints on login.

- [ ] 10.4 Grep the codebase for any remaining `mplusScore` references (excluding `Scoring.lua`'s backwards-compat comment and the migration's own nil-out line). There should be none in data-producing paths.

---

## Manual Verification Checklist

### 2.5 — DATA sender-identity check

| Scenario | Expected result |
|---|---|
| Non-leader, not whitelisted sends DATA | Rejected; chat warning printed once per sender per session; `GetRecentWarnings()` entry recorded |
| Non-leader, whitelisted sends DATA | Accepted if `generatedAt` is newer than local |
| Leader sends DATA | Accepted (existing behaviour, unchanged) |
| `/bl trustedsender add Name-Realm` from leader | Persists across `/reload`; entry visible in Data tab |
| `/bl trustedsender remove Name-Realm` from leader | Entry gone; sync reverts to leader-only |
| `/bl trustedsender add` from non-leader | "only the group leader can manage trusted senders." |
| `/bl trustedsender list` with multiple entries | Each entry printed on its own line |
| Same name added twice | Second add returns "already present" message |

### 2.6 — `_leaderScores` cache invalidation

| Scenario | Expected result |
|---|---|
| Leadership passes while transparency is on | `_leaderScores` cleared; chat message shows item count |
| `_leaderScores` is nil when `PARTY_LEADER_CHANGED` fires | No error; no chat message |
| LootFrame is open at leader-change moment | `LootFrame:Refresh()` called; score column re-renders from nil cache (shows `—` or zeroed state until new leader broadcasts SCORES) |
| Leadership restored to original leader | Second `PARTY_LEADER_CHANGED` fires; nil cache again (no double-free error) |

### 2.7 — DB migration + SyncDB prune

| Scenario | Expected result |
|---|---|
| Fresh install (no `dbVersion` key) | Runner sets `dbVersion = 1` after first load with character data |
| Install with `dbVersion = 1` already | Runner skips all steps; no migration messages |
| Data file contains `mplusScore` fields | Migration v1 nil-outs them; warning printed once; `mplusDungeons` set to 0 if absent |
| Migration v1 runs on data file with no `mplusScore` | Silent (no message); `dbVersion` still bumped to 1 |
| `BobleLootSyncDB.dataStoredAt` > 90 days old | Prune fires on next startup; data and timestamp cleared |
| `BobleLootSyncDB.dataStoredAt` missing (pre-2B install) | No prune; `dataStoredAt` will be written on next DATA receive |
| `BobleLootSyncDB.pendingChunks` exists at startup | Cleared unconditionally |

---

## Upgrade / Rollback

### Upgrade path (pre-2B → 2B)

On the first login after 2B is deployed:
1. AceDB initialises `dbVersion = 0` (from `DB_DEFAULTS`) for any profile that lacks the key.
2. `Migrations:Run` fires; step v1 runs if `BobleLoot_Data` is loaded with character data.
3. `Sync:Setup` initialises `trustedSenders = {}` if absent.
4. `Sync:Setup` checks `dataStoredAt`; absent means skip prune (safe default).
5. `PARTY_LEADER_CHANGED` is registered from `OnEnable` onward.

No manual steps required. The transition is transparent to the raid leader.

### Rollback

Migrations are **one-way and additive**. There is no data-level rollback. To revert 2B:

1. `git revert <2B-commit-hash>` and redeploy.
2. `BobleLootDB.profile.dbVersion` will remain at `1` in SavedVariables, but the runner table will be absent so no further migrations run. This is safe — the v1 migration only nils out `mplusScore` fields which are already gone from the data file after a fresh `wowaudit.py` run.
3. `BobleLootSyncDB.trustedSenders` will persist harmlessly; without the auth check code, the field is simply ignored.
4. `BobleLootSyncDB.dataStoredAt` persists; without the prune code, it is also ignored.

There is no scenario where a rollback corrupts the DB. Additive schema changes are safe to abandon in place.

---

## Coordination Notes

### Files touched by each Batch 2 plan

| File | 2A | 2B | 2C | 2D | 2E |
|---|---|---|---|---|---|
| `tools/wowaudit.py` | Owner | No | No | No | No |
| `Scoring.lua` | Owner | No | No | No | No |
| `Sync.lua` | No | Owner | Shared | No | No |
| `Core.lua` | No | Owner | No | No | No |
| `Migrations.lua` | No | Owner (new) | No | No | No |
| `UI/SettingsPanel.lua` | No | Additive | No | No | No |
| `UI/VotingFrame.lua` | No | No | No | Owner | Owner |
| `BobleLoot.toc` | No | Owner (new entry) | Shared | No | No |

### 2B ↔ 2C boundary (Sync.lua)

2C owns the `DATACHUNK` message kind, the `pendingChunks` accumulator, and the reassembly promotion logic. 2B's only 2C-touching line is the unconditional `db.pendingChunks = nil` clear in `Sync:Setup`.

**Protocol:** 2C must not add its prune logic to `Sync:Setup` — 2B already owns that slot. 2C's startup code should check `pendingChunks ~= nil` and assume 2B cleared it; any entries that arrive post-startup are written by 2C's chunk accumulator.

If 2B and 2C land in the same release, merge order in `Sync:Setup` must be: 2B prune block first, then 2C init block for `pendingChunks` (so a partial write from the just-cleared prune does not persist).

### 2B ↔ 2A boundary (wowaudit.py / Scoring.lua)

2A modifies `wowaudit.py` to emit `mainspec` and `role` fields and may update `Scoring.lua` for spec-aware sim selection. 2B's migration v1 converts `mplusScore` in `BobleLoot_Data.lua`; these are orthogonal fields. No conflict.

However: if 2A ships a new `BobleLoot_Data.lua` schema that removes `mplusScore` globally, migration v1 becomes a silent no-op (zero characters to convert), which is correct behaviour.

### 2B ↔ 2D / 2E boundary (UI)

2D (score explanation panel) and 2E (voting frame nits) are entirely within `VotingFrame.lua` and the new explanation frame. They do not read `_leaderScores` directly — they call `BobleLoot:GetScore` or read the SCORES broadcast result. The `_leaderScores` invalidation in 2B is transparent to them: the next SCORES broadcast from the new leader repopulates the cache, and the explanation panel will reflect the fresh data on its next open.
