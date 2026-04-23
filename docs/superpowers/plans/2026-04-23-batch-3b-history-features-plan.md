# Batch 3B — Data-Side History Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the loot-history data layer with wasted-loot flagging (3.5), a `ComputeAll` API for bench-mode scoring (3.6), and per-night score-trend persistence and accessors (3.8) — giving downstream UI plans the reliable data contracts they need.

**Architecture:** Wasted-loot detection hooks `TRADE_CLOSED` in `Core.lua` and writes a `wasted = true` flag on the matching RC history entry in a lightweight pending-award table; `LootHistory:CountItemsReceived` skips flagged entries at aggregation time without restructuring the hybrid model. `Scoring:ComputeAll` iterates `_G.BobleLoot_Data.characters`, calls the existing `Scoring:Compute` for each, and returns a sorted array — no new scoring math. Score-trend storage writes a compact `{ ts, score, itemID }` record to `BobleLootDB.profile.scoreHistory[name]` after every successful `Compute` call, exposed via `Scoring:RecordScore`, `Scoring:GetScoreTrend`, and `Scoring:GetTrendSummary`.

**Tech Stack:** Lua (WoW 10.x), AceEvent for `TRADE_CLOSED`, AceDB for profile persistence, `GetTradePlayerItemInfo` / `GetTradeTargetItemInfo` for trade inspection, `C_Item.GetItemInfoInstant` for itemID resolution from item links

**Roadmap items covered:** 3.5, 3.6, 3.8

> **3.5 `[Data]` Wasted-loot flagging in history**
>
> Items that were awarded (logged in RC history) but later disenchanted
> or traded away should not count against the recipient's next score.
> Hook `TRADE_CLOSED` + inspect `GetTradePlayerItemInfo` to detect, and
> mark the history entry as 0-weight.

> **3.6 `[Data]` Bench-mode scoring data layer**
>
> Compute scores for all roster members (not just current session
> candidates). Expose `ns.Scoring:ComputeAll(itemID)` returning a sorted
> list. Consumed by Batch 3.13's UI surface.

> **3.8 `[Cross]` Historical score-trend tracking**
>
> Store per-night score-per-item for each player in `BobleLootDB`
> (leader-side, just the final float + itemID + timestamp). After four
> weeks, surface a sparkline or delta in the score tooltip
> ("Boble's score has dropped 12 points since tier start").
>
> Cross contract: data side stores and exposes the history; UI side
> renders the sparkline in the tooltip (1.7) and in the Explain panel
> (2.9).

**Dependencies:**
- Batch 1D — `ns.Scoring.COMPONENT_ORDER`, `ns.Scoring.COMPONENT_LABEL`, `Scoring:Compute(itemID, name, profile, data, opts)` returning `(score, breakdown)`.
- Batch 1E — `SettingsPanel.lua` tab/slider/checkbox helpers (`MakeSlider`, `MakeCheckButton`, `BuildTuningTab` pattern).
- Batch 2B — `Migrations.lua` framework; migration step v2 for `scoreHistory` and `wastedLoot` profile keys must be added as a new step in that file's `STEPS` table.
- Batch 2D — `UI/ExplainPanel.lua` is the natural consumer of `GetScoreTrend`; the cross-plan contract is documented in the Coordination Notes section below.

---

## File Structure

```
BobleLoot/
├── Core.lua                   -- TRADE_CLOSED event registration; pending-award
│                              --   table helpers; DB_DEFAULTS additions for
│                              --   scoreHistory, wastedLoot, trendHistoryDays,
│                              --   trackTrends; /bl wastedloot slash subcommand
├── Scoring.lua                -- ComputeAll(itemID); RecordScore(name,itemID,score);
│                              --   GetScoreTrend(name,itemID,days);
│                              --   GetTrendSummary(name)
├── LootHistory.lua            -- wasted-entry skip in CountItemsReceived;
│                              --   LH:MarkWasted(name,itemLink); no structural changes
├── Migrations.lua             -- NEW step v2: initialise profile.scoreHistory = {},
│                              --   profile.wastedLootMap = {}
└── UI/
    └── SettingsPanel.lua      -- BuildTuningTab addition: "Track score trends"
                               --   checkbox + "Trend window (days)" slider
```

### Key invariants

- `LootHistory:CountItemsReceived` is the **only** place entries are aggregated into `char.itemsReceived`. The wasted-flag skip is added there, one guard line, so the hybrid model is untouched.
- `Scoring:ComputeAll` is a read-only convenience wrapper. It calls `Scoring:Compute` — no weight redistribution logic lives in `ComputeAll`.
- `RecordScore` is called **after** every successful `Scoring:Compute` that returns a non-nil score, gated by `profile.trackTrends`. It must be cheap enough to call on every vote-frame refresh (it appends one record and prunes).
- `scoreHistory` is a leader-side concern. Non-leaders do not write to it. `ComputeAll` may be called on any client that holds the dataset.
- The `wastedLootMap` (`BobleLootDB.profile.wastedLootMap`) is a flat table keyed by a deterministic entry fingerprint (see Task 2). It is never read directly by Scoring or LootHistory callers — those modules call `LH:IsWasted(fingerprint)`.
- Pruning for `scoreHistory`: keep the last `trendHistoryDays` worth of records **per player** (not per player-item). The total number of records per player is bounded by `trendHistoryDays * avgItemsPerNight`; in practice < 200 entries per raider over 28 days.

---

## Task 1 — DB_DEFAULTS additions and new profile keys (`Core.lua`)

**Files:** `Core.lua`

Add four new keys to `DB_DEFAULTS.profile`. AceDB merges defaults on every login, so Batch 2B's migration step (v2 below) is the authoritative path for installs that already have a `BobleLootDB` file; the defaults handle fresh installs.

- [ ] 1.1 Locate the `DB_DEFAULTS` table in `Core.lua`. After the existing `panelPos` entry, append:

  ```lua
  -- 3.8 score-trend tracking
  trackTrends      = true,        -- leader-side toggle; non-leaders ignore
  trendHistoryDays = 28,          -- rolling window kept in scoreHistory
  scoreHistory     = {},          -- [charName] = { {ts,score,itemID}, ... }
  -- 3.5 wasted-loot
  wastedLootMap    = {},          -- [fingerprint] = true
  ```

- [ ] 1.2 Verify with `/run print(BobleLoot.db.profile.trackTrends)` in-game after `/reload` — should print `true`.

**Commit:** `feat(Core): add scoreHistory, wastedLootMap, trackTrends, trendHistoryDays to DB_DEFAULTS`

---

## Task 2 — Migration step v2 in `Migrations.lua`

**Files:** `Migrations.lua`

Batch 2B's `Migrations.STEPS` table already contains step v1 (mplusScore cleanup). Append step v2 here so existing installs have their profile initialised correctly. The step is idempotent: it only sets keys that are missing.

- [ ] 2.1 Open `Migrations.lua`. Locate the closing `}` of `Migrations.STEPS`. Append **before** that closing brace:

  ```lua
  -- v2: Initialise 3.5 wastedLootMap and 3.8 scoreHistory/trend keys.
  -- Safe to run on any profile version < 2; idempotent because we only
  -- set keys that are nil (AceDB will have supplied defaults on fresh
  -- installs, but old installs pre-3B won't have them).
  {
      version = 2,
      run = function(profile, addon)
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
          if addon and addon.Print then
              addon:Print("Migration v2: initialised scoreHistory and wastedLootMap.")
          end
      end,
  },
  ```

- [ ] 2.2 Verify: on a character whose `dbVersion` is 1 (post-Batch-2B), the migration runner should print the v2 message once on first login after the patch. Subsequent `/reload`s should not re-print it.

**Commit:** `feat(Migrations): add step v2 for scoreHistory and wastedLootMap init`

---

## Task 3 — Wasted-loot pending-award table and `TRADE_CLOSED` hook (`Core.lua`)

**Files:** `Core.lua`

The core detection strategy is a **short-window pending-award table**: when RC awards an item, `LootHistory:Apply` is triggered shortly after via `CHAT_MSG_LOOT`. We record the `(recipientName, itemID, timestamp)` in a module-level table (`BobleLoot._pendingAwards`) with a 300-second TTL. When `TRADE_CLOSED` fires, we inspect what the local player gave away and match against pending awards. If the local player is the recipient who trades the item out, or if the local player is an observer and the trader is the recipient, we call `LH:MarkWasted`.

**Detection strategy rationale:**

| Approach | Pro | Con |
|---|---|---|
| `TRADE_CLOSED` + `GetTradePlayerItemInfo` | Works for trades without needing server-side data | Only fires on the client doing the trading or observing the trade; non-present clients miss it. Leader must be present or trust the honor system. |
| Inventory-loss detection on RC award tick | No trade window needed | WoW does not expose a reliable "item removed from bag" event at the moment of looting; `BAG_UPDATE` is noisy and fires for consumables, vendor purchases, etc. Not viable. |
| Manual `/bl wasteloot <name> <link>` command | Always works; explicit | Adds ceremony; relies on leader remembering to do it post-trade. |

Decision: implement `TRADE_CLOSED` as the primary path. Add `/bl wasteloot <name> <link>` as the manual fallback (Task 4). Document both in the `/bl help` output. Do not attempt inventory-loss detection.

- [ ] 3.1 Add a module-level pending-award table near the top of `Core.lua`'s `OnEnable` wiring area (not inside any function, so it persists across calls):

  ```lua
  -- Pending awards: { [fingerprint] = { name, itemID, ts } }
  -- Populated by LH:RegisterPendingAward (called from LH:Setup event handlers).
  -- Pruned by BobleLoot:PrunePendingAwards.
  BobleLoot._pendingAwards = BobleLoot._pendingAwards or {}
  ```

- [ ] 3.2 Add `BobleLoot:PrunePendingAwards()` — removes entries older than 300 seconds:

  ```lua
  function BobleLoot:PrunePendingAwards()
      local now = time()
      for fp, entry in pairs(self._pendingAwards) do
          if now - entry.ts > 300 then
              self._pendingAwards[fp] = nil
          end
      end
  end
  ```

- [ ] 3.3 Register `TRADE_CLOSED` in `BobleLoot:OnEnable`. AceEvent is already mixed in via `"AceEvent-3.0"`:

  ```lua
  self:RegisterEvent("TRADE_CLOSED", "OnTradeClosed")
  ```

- [ ] 3.4 Add `BobleLoot:OnTradeClosed()`. This fires after a trade window closes successfully (items exchanged). Inspect both sides of the trade — the player's given items and the target's given items — to detect outbound awards.

  ```lua
  function BobleLoot:OnTradeClosed()
      -- TRADE_CLOSED fires for both successful trades and cancellations.
      -- GetTradePlayerItemInfo returns nil link on cancellation, so nil-
      -- guards below handle that transparently.
      self:PrunePendingAwards()
      local profile = self.db and self.db.profile
      if not profile then return end

      -- Inspect items the local player gave away (up to 7 trade slots).
      for slot = 1, 7 do
          local _, _, _, _, link = GetTradePlayerItemInfo(slot)
          if link then
              local itemID = C_Item and C_Item.GetItemInfoInstant and
                  select(2, C_Item.GetItemInfoInstant(link))
              if itemID then
                  -- The local player is trading this item out.
                  -- Check if the local player has a pending award for it
                  -- (meaning they were the RC recipient and are now giving it away).
                  local playerName = UnitName("player")
                  if playerName then
                      local fp = ns.LootHistory and
                          ns.LootHistory:MakeFingerprint(playerName, itemID)
                      if fp and self._pendingAwards[fp] then
                          ns.LootHistory:MarkWasted(playerName, itemID, profile)
                          self._pendingAwards[fp] = nil
                          self:Print(string.format(
                              "BobleLoot: marked item %d as wasted for %s (traded away).",
                              itemID, playerName))
                      end
                  end
              end
          end
      end

      -- Inspect items the trade target gave the local player — not relevant
      -- for wasted-loot detection (we care about outbound awards). Skipped.
  end
  ```

- [ ] 3.5 Verify: in a test session, have the local player receive an RC award and immediately trade it away within 5 minutes. The chat log should print `"BobleLoot: marked item <id> as wasted for <name> (traded away)."`. Confirm `BobleLootDB.profile.wastedLootMap` has the fingerprint set to `true` after the trade.

**Commit:** `feat(Core): register TRADE_CLOSED, add pending-award table and OnTradeClosed handler`

---

## Task 4 — `LH:RegisterPendingAward`, `LH:MakeFingerprint`, `LH:MarkWasted`, `LH:IsWasted` (`LootHistory.lua`)

**Files:** `LootHistory.lua`

These four functions are the public API surface for wasted-loot detection. They do not touch `CountItemsReceived`'s aggregation loop yet (Task 5 does that).

- [ ] 4.1 Add `LH:MakeFingerprint(name, itemID)` — deterministic string key used in `wastedLootMap`:

  ```lua
  -- Deterministic fingerprint for a (recipient, itemID) pair.
  -- Deliberately excludes timestamp so the key is stable across Apply calls.
  function LH:MakeFingerprint(name, itemID)
      return tostring(name) .. ":" .. tostring(itemID)
  end
  ```

- [ ] 4.2 Add `LH:RegisterPendingAward(addon, name, itemID)`. This is called from the `CHAT_MSG_LOOT` handler in `LH:Setup` when an RC award is detected:

  ```lua
  -- Record a fresh RC award in Core's pending-awards table so TRADE_CLOSED
  -- can match against it within the 5-minute window.
  function LH:RegisterPendingAward(addon, name, itemID)
      if not addon or not addon._pendingAwards then return end
      local fp = self:MakeFingerprint(name, itemID)
      addon._pendingAwards[fp] = { name = name, itemID = itemID, ts = time() }
  end
  ```

- [ ] 4.3 Add `LH:MarkWasted(name, itemID, profile)`. Writes to `profile.wastedLootMap`:

  ```lua
  -- Flag a (name, itemID) pair as wasted in the persistent profile map.
  -- Safe to call multiple times for the same pair (idempotent).
  function LH:MarkWasted(name, itemID, profile)
      if not profile or not profile.wastedLootMap then return end
      local fp = self:MakeFingerprint(name, itemID)
      profile.wastedLootMap[fp] = true
  end
  ```

- [ ] 4.4 Add `LH:IsWasted(name, itemID, profile)`:

  ```lua
  function LH:IsWasted(name, itemID, profile)
      if not profile or not profile.wastedLootMap then return false end
      local fp = self:MakeFingerprint(name, itemID)
      return profile.wastedLootMap[fp] == true
  end
  ```

- [ ] 4.5 Hook `LH:Setup` to call `LH:RegisterPendingAward` when `CHAT_MSG_LOOT` fires after an RC session. Because the CHAT_MSG_LOOT handler already calls `C_Timer.After(2, Apply)`, we add a parallel `C_Timer.After(0, ...)` to register the award before Apply runs. The RC session's most recently awarded candidate name and item link are read from `RCLootCouncil:GetCurrentSession()` (guarded) or the last `CHAT_MSG_LOOT` text parse. Keep this lightweight:

  ```lua
  -- Inside the existing f:SetScript("OnEvent", ...) in LH:Setup,
  -- in the branch that handles CHAT_MSG_LOOT, BEFORE the C_Timer.After(2, Apply):
  -- (Add after the existing `if self.lastApply ...` guard)

  -- Register the most recent RC award as a pending wasted-loot candidate.
  -- RC does not fire a dedicated addon event here, so we read the active
  -- session's last award from the RC addon object if available.
  local RC = LibStub and LibStub("AceAddon-3.0"):GetAddon("RCLootCouncil", true)
  if RC then
      local session = RC:GetCurrentSession and RC:GetCurrentSession()
      if session then
          for _, candidate in pairs(session) do
              if candidate.awarded and candidate.name and candidate.link then
                  local iid = C_Item and C_Item.GetItemInfoInstant and
                      select(2, C_Item.GetItemInfoInstant(candidate.link))
                  if iid then
                      self:RegisterPendingAward(self.addon, candidate.name, iid)
                  end
              end
          end
      end
  end
  ```

  Note: `RC:GetCurrentSession()` shape varies across RC versions. This call is fully guarded. If it returns nil or lacks the expected fields, `RegisterPendingAward` is simply not called and the trade-detection path degrades gracefully to the manual `/bl wasteloot` fallback.

- [ ] 4.6 Add the `/bl wasteloot <Name-Realm> <link>` slash subcommand in `Core.lua:OnSlashCommand` (manual override path for non-present leaders or undetected trades):

  ```lua
  elseif input:match("^wasteloot%s+") then
      local name, link = input:match("^wasteloot%s+(%S+)%s+(|?.*)")
      if name and link and link ~= "" then
          local itemID = C_Item and C_Item.GetItemInfoInstant and
              select(2, C_Item.GetItemInfoInstant(link))
          if itemID and ns.LootHistory then
              ns.LootHistory:MarkWasted(name, itemID, self.db.profile)
              self:Print(string.format("Marked item %d wasted for %s.", itemID, name))
          else
              self:Print("Could not resolve item from link. Paste the item link directly.")
          end
      else
          self:Print("Usage: /bl wasteloot <Name-Realm> <itemlink>")
      end
  ```

- [ ] 4.7 Update the help string in `OnSlashCommand` to include `| /bl wasteloot <Name-Realm> <link>`.

**Commit:** `feat(LootHistory): add wasted-loot API: MakeFingerprint, RegisterPendingAward, MarkWasted, IsWasted`

---

## Task 5 — Skip wasted entries in `LH:CountItemsReceived` (`LootHistory.lua`)

**Files:** `LootHistory.lua`

This is the only change to the aggregation model. The hybrid relative-to-max-with-soft-floor logic is untouched. We add one guard inside the per-entry loop.

- [ ] 5.1 `CountItemsReceived` receives `rcLootDB, days, weights, minIlvl`. We need the profile to call `IsWasted`. Add `profile` as a fifth parameter (callers already pass it through `Apply`):

  Change the signature:
  ```lua
  function LH:CountItemsReceived(rcLootDB, days, weights, minIlvl, profile)
  ```

- [ ] 5.2 Inside the per-entry loop, after `if cat then` and the existing `timeOk`/`ilvlOk` guards, add the wasted check. Extract the `itemID` from the entry link — RC entries store the item link in `e.lootWon` or `e.link`:

  ```lua
  -- Inside the `if cat then` block, before row.total is incremented:
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
  ```

  Remove the original `if timeOk and ilvlOk then` lines (replaced by the combined guard above).

- [ ] 5.3 Update `LH:Apply` to pass `profile` to `CountItemsReceived`:

  ```lua
  local rows = self:CountItemsReceived(db, days, weights, minIlvl, profile)
  ```

- [ ] 5.4 Verify: award an item via RC in a test session, mark it wasted with `/bl wasteloot <name> <link>`, then `/bl lootdb`. The scored total for that player should not include the wasted item's weight.

**Commit:** `feat(LootHistory): skip wasted entries in CountItemsReceived`

---

## Task 6 — `Scoring:ComputeAll(itemID)` (`Scoring.lua`)

**Files:** `Scoring.lua`

`ComputeAll` is a pure data layer function. It reads `_G.BobleLoot_Data.characters`, calls `Scoring:Compute` for each character, collects results, sorts by score descending, and returns the array. It does not mutate state.

- [ ] 6.1 Add `Scoring:ComputeAll(itemID, profile, opts)` after the existing `Scoring:Compute` function:

  ```lua
  -- Compute scores for all characters in the loaded data file for a given
  -- itemID. Returns a sorted array:
  --   { { name = "...", score = 74.2, breakdown = {...} }, ... }
  -- Characters with nil scores (missing sim data when sim weight > 0,
  -- or no character entry at all) are excluded from the result.
  -- `profile` defaults to addon.db.profile if ns.addon is available.
  -- `opts` is forwarded to Compute unchanged (simReference, historyReference, etc).
  function Scoring:ComputeAll(itemID, profile, opts)
      local data = _G.BobleLoot_Data
      if not data or not data.characters then return {} end

      if not profile then
          local addon = ns.addon
          profile = addon and addon.db and addon.db.profile
      end
      if not profile then return {} end

      local results = {}
      for name, _ in pairs(data.characters) do
          local score, breakdown = self:Compute(itemID, name, profile, data, opts)
          if score ~= nil then
              results[#results + 1] = { name = name, score = score, breakdown = breakdown }
          end
      end

      table.sort(results, function(a, b)
          return (a.score or 0) > (b.score or 0)
      end)

      return results
  end
  ```

- [ ] 6.2 Verify: `/run local r = ns.Scoring:ComputeAll(12345) print(#r, r[1] and r[1].name or "none")` — should print a count > 0 and the top-ranked name for a known itemID in the dataset. Use an itemID from `BobleLoot_Data` during testing.

**Commit:** `feat(Scoring): add ComputeAll returning sorted score list for all roster members`

---

## Task 7 — `Scoring:RecordScore`, `Scoring:GetScoreTrend`, `Scoring:GetTrendSummary` (`Scoring.lua`)

**Files:** `Scoring.lua`

These three functions form the 3.8 storage and accessor layer. They operate on `BobleLootDB.profile.scoreHistory` which is a table keyed by character name, each value being an array of `{ ts, score, itemID }` triplets sorted oldest-first.

- [ ] 7.1 Add `Scoring:RecordScore(name, itemID, score, profile)`. Called after each successful `Compute` on the leader's client:

  ```lua
  -- Append a score observation to the rolling history for `name`.
  -- Prunes entries older than profile.trendHistoryDays before appending
  -- so the table stays bounded.
  -- This function is a no-op when profile.trackTrends is false.
  function Scoring:RecordScore(name, itemID, score, profile)
      if not profile or not profile.trackTrends then return end
      if score == nil then return end

      local history = profile.scoreHistory
      if type(history) ~= "table" then return end

      local days    = profile.trendHistoryDays or 28
      local cutoff  = time() - days * 24 * 3600
      local entries = history[name]
      if type(entries) ~= "table" then
          entries = {}
          history[name] = entries
      end

      -- Prune stale entries (linear, but arrays are small).
      local i = 1
      while i <= #entries do
          if (entries[i].ts or 0) < cutoff then
              table.remove(entries, i)
          else
              i = i + 1
          end
      end

      -- Append new record.
      entries[#entries + 1] = { ts = time(), score = score, itemID = itemID }
  end
  ```

- [ ] 7.2 Add `Scoring:GetScoreTrend(name, itemID, days, profile)`. Returns an array of `{ ts, score }` pairs for one player + item combination over the last `days` days, sorted oldest-first. The UI can use this to draw a sparkline.

  ```lua
  -- Return per-observation records for (name, itemID) within the last `days`.
  -- Returns: { { ts = <unix>, score = <float> }, ... } sorted oldest-first.
  -- Returns {} if no data exists.
  function Scoring:GetScoreTrend(name, itemID, days, profile)
      if not profile then
          local addon = ns.addon
          profile = addon and addon.db and addon.db.profile
      end
      if not profile then return {} end

      local history = profile.scoreHistory
      if type(history) ~= "table" then return {} end

      local entries = history[name]
      if type(entries) ~= "table" then return {} end

      days = days or (profile.trendHistoryDays or 28)
      local cutoff = time() - days * 24 * 3600
      local result = {}
      for _, e in ipairs(entries) do
          if (e.ts or 0) >= cutoff and e.itemID == itemID then
              result[#result + 1] = { ts = e.ts, score = e.score }
          end
      end
      -- Already appended in chronological order (RecordScore always appends).
      return result
  end
  ```

- [ ] 7.3 Add `Scoring:GetTrendSummary(name, profile)`. Returns a concise summary across all items for the tooltip/Explain panel use-case: the first score, the last score, and the delta over the configured window.

  ```lua
  -- Return a one-line summary of overall score movement for `name`
  -- across all items in the trend window.
  -- Returns: { first = float, last = float, delta = float, count = int }
  --   or nil if fewer than 2 observations exist.
  function Scoring:GetTrendSummary(name, profile)
      if not profile then
          local addon = ns.addon
          profile = addon and addon.db and addon.db.profile
      end
      if not profile then return nil end

      local history = profile.scoreHistory
      if type(history) ~= "table" then return nil end

      local entries = history[name]
      if type(entries) ~= "table" or #entries < 2 then return nil end

      local days   = profile.trendHistoryDays or 28
      local cutoff = time() - days * 24 * 3600
      local valid  = {}
      for _, e in ipairs(entries) do
          if (e.ts or 0) >= cutoff then
              valid[#valid + 1] = e
          end
      end
      if #valid < 2 then return nil end

      local first = valid[1].score
      local last  = valid[#valid].score
      return {
          first = first,
          last  = last,
          delta = last - first,
          count = #valid,
      }
  end
  ```

- [ ] 7.4 Wire `RecordScore` into `Core.lua:GetScore`. `GetScore` is the thin public wrapper that the voting frame calls. After the score is computed, call `RecordScore` if the addon is the group leader (trend tracking is leader-side):

  ```lua
  function BobleLoot:GetScore(itemID, candidateName, opts)
      if not ns.Scoring then return nil end
      local score, breakdown = ns.Scoring:Compute(
          itemID, candidateName, self.db.profile, self:GetData(), opts)
      -- Record for trend history (leader-side only; UnitIsGroupLeader guard).
      if score ~= nil and UnitIsGroupLeader("player") and ns.Scoring.RecordScore then
          ns.Scoring:RecordScore(candidateName, itemID, score, self.db.profile)
      end
      return score, breakdown
  end
  ```

- [ ] 7.5 Verify: open a voting session for a known item on the leader client. After the frame closes, run `/run local s = ns.Scoring:GetTrendSummary("Name-Realm", BobleLoot.db.profile) if s then print(s.last, s.delta) end`. Should print the last recorded score and delta (delta will be 0 if only one session's data exists yet).

**Commit:** `feat(Scoring): add RecordScore, GetScoreTrend, GetTrendSummary for 3.8 trend tracking`

---

## Task 8 — SettingsPanel additions: trend toggle and window slider (`UI/SettingsPanel.lua`)

**Files:** `UI/SettingsPanel.lua`

Add two controls at the bottom of the existing `BuildTuningTab` section. Use the established `MakeCheckButton` and `MakeSlider` helpers.

- [ ] 8.1 Locate `BuildTuningTab` in `SettingsPanel.lua`. At the end of the function body, after the last existing control, append:

  ```lua
  -- ── Score trend tracking (3.8) ────────────────────────────────────────
  local yTrend = <last_y_offset> - 50   -- adjust to clear the last existing control

  MakeCheckButton(scrollChild, {
      label  = "Track per-night score trends (leader only)",
      x      = 16,
      y      = yTrend,
      get    = function() return addon.db.profile.trackTrends end,
      set    = function(v) addon.db.profile.trackTrends = v end,
      tooltip = "When enabled, the leader's client records each player's computed " ..
                "score after every voting session. Used to show score trends in " ..
                "tooltips and the Explain panel after four or more weeks of data.",
  })

  MakeSlider(scrollChild, {
      label  = "Trend window (days)",
      x      = 16,
      y      = yTrend - 44,
      min    = 7,
      max    = 90,
      step   = 1,
      width  = 220,
      get    = function() return addon.db.profile.trendHistoryDays or 28 end,
      set    = function(v) addon.db.profile.trendHistoryDays = math.floor(v) end,
  })
  ```

  Replace `<last_y_offset>` with the actual Y value of the control immediately above (read from the file). The pattern is negative Y from TOPLEFT, so subtract ~50 per control.

- [ ] 8.2 Verify: open `/bl config`, switch to the Tuning tab. The "Track per-night score trends" checkbox and "Trend window (days)" slider should appear at the bottom. Toggling the checkbox should update `BobleLoot.db.profile.trackTrends` immediately (verify with `/run print(BobleLoot.db.profile.trackTrends)`).

**Commit:** `feat(SettingsPanel): add trend tracking toggle and window slider to Tuning tab`

---

## Task 9 — `/bl wastedloot list` diagnostic subcommand and help string update (`Core.lua`)

**Files:** `Core.lua`

Give the leader a way to inspect the wasted-loot map without opening SavedVariables.

- [ ] 9.1 Add a `wastedloot list` branch to `OnSlashCommand` (below the existing `wasteloot` mark branch):

  ```lua
  elseif input == "wastedloot list" or input == "wasteloot list" then
      local map = self.db.profile.wastedLootMap
      if not map or not next(map) then
          self:Print("No wasted-loot entries recorded.")
      else
          local count = 0
          for fp, _ in pairs(map) do
              self:Print("  wasted: " .. fp)
              count = count + 1
          end
          self:Print(string.format("Total: %d wasted entry(s).", count))
      end
  ```

- [ ] 9.2 Add `wastedloot clear` for cleaning up incorrect marks:

  ```lua
  elseif input == "wastedloot clear" or input == "wasteloot clear" then
      self.db.profile.wastedLootMap = {}
      self:Print("Wasted-loot map cleared.")
  ```

- [ ] 9.3 Update the help string to include the new subcommands:

  ```lua
  "/bl wasteloot <Name-Realm> <link> | /bl wastedloot list | /bl wastedloot clear"
  ```

**Commit:** `feat(Core): add wastedloot list/clear diagnostic subcommands`

---

## Task 10 — TOC load order: ensure `Migrations.lua` precedes `Scoring.lua` and `LootHistory.lua`

**Files:** `BobleLoot.toc`

Batch 2B added `Migrations.lua` after `Core.lua`. Verify that load order is intact — `Migrations.lua` must load before `Scoring.lua` because `Core:OnInitialize` (which calls `Migrations:Run`) fires after all files load, but we want `ns.Migrations` available at that point. No reordering should be needed if Batch 2B is merged; this task is a guard check.

- [ ] 10.1 Read `BobleLoot.toc`. Confirm the order is:
  ```
  Core.lua
  Migrations.lua
  Scoring.lua
  LootHistory.lua
  ```
  If `Migrations.lua` is missing (Batch 2B not yet merged), add it now. If it's present but after `Scoring.lua`, move it before.

- [ ] 10.2 No code change is expected if Batch 2B is merged. Document the check result in the commit message.

**Commit:** `chore(toc): verify Migrations.lua load order precedes Scoring.lua (3B guard)`

---

## Task 11 — Wired integration test: full award-to-wasted cycle

This is a manual verification task, not a code task. Document the expected behavior for whoever runs the first in-game test.

**Files:** none

- [ ] 11.1 Scenario A — automatic trade detection:
  1. As raid leader, open an RC loot session for any item (use Test mode if needed).
  2. Award the item to a specific candidate ("Sprinty-Doomhammer").
  3. Within 5 minutes, have that player open a trade with the leader and put the item in the trade window. Complete the trade.
  4. Observe the leader's chat: expect `"BobleLoot: marked item <id> as wasted for Sprinty-Doomhammer (traded away)."`.
  5. Run `/bl wastedloot list` — confirm the fingerprint appears.
  6. Run `/bl lootdb` — confirm the apply re-runs and the recipient's `itemsReceived` does not include the wasted item's weight.

- [ ] 11.2 Scenario B — manual override:
  1. Award an item and wait longer than 5 minutes (pending-award TTL expires).
  2. The trade detection fires but `_pendingAwards` has no entry. Trade is not flagged automatically.
  3. Run `/bl wasteloot Sprinty-Doomhammer |item:12345::...|` (paste the item link directly).
  4. Observe confirmation message. Run `/bl wastedloot list` — entry should appear.
  5. Run `/bl lootdb` — the next Apply excludes the wasted item.

- [ ] 11.3 Scenario C — trend data accumulation:
  1. Open several voting sessions (use Test mode) on the leader client for the same `itemID`.
  2. After three sessions, run: `/run local t = ns.Scoring:GetScoreTrend("Name-Realm", 12345, 28, BobleLoot.db.profile) print(#t)` — should print 3 or more.
  3. Check the raw SavedVariables shape (see Schema Notes below).

- [ ] 11.4 Scenario D — `ComputeAll`:
  1. Run: `/run local r = ns.Scoring:ComputeAll(12345) print(#r, r[1] and r[1].name, r[1] and string.format("%.1f", r[1].score))`.
  2. Expect a sorted list with the highest-scoring roster member first.

---

## Manual Verification Checklist

### 3.5 Wasted-loot flagging

- [ ] `LH:MakeFingerprint("Sprinty-Doomhammer", 12345)` returns `"Sprinty-Doomhammer:12345"` (consistent, no nils).
- [ ] `LH:MarkWasted` writes to `BobleLootDB.profile.wastedLootMap`; key survives a `/reload`.
- [ ] `LH:IsWasted` returns `true` for a flagged entry, `false` for an unknown one.
- [ ] `TRADE_CLOSED` handler calls `MarkWasted` within the 5-minute TTL window; prints confirmation.
- [ ] After a wasted entry is marked, `/bl lootdb` (which triggers `Apply`) excludes the entry — the player's `itemsReceived` total is lower than it would be without the flag.
- [ ] `/bl wasteloot list` shows all flagged fingerprints.
- [ ] `/bl wasteloot clear` empties the map; subsequent `/bl lootdb` restores full credit.
- [ ] A trade of a non-pending-award item produces no spurious wasted-loot message.
- [ ] `CountItemsReceived` signature change (`profile` fifth param) does not break any existing callers (only `Apply` calls it, and `Apply` is updated in Task 5.3).

### 3.6 Bench-mode scoring

- [ ] `Scoring:ComputeAll(itemID)` returns an array, not nil, even when called with an itemID not in any character's sim data (returns [] for missing, not an error).
- [ ] Array is sorted descending by score.
- [ ] Characters with nil scores (no sim data + sim weight > 0) are excluded from the result (consistent with `Compute` behavior).
- [ ] The result array entries each have `name`, `score`, and `breakdown` keys populated.
- [ ] `ComputeAll` does not mutate `BobleLoot_Data.characters` or any other shared state.
- [ ] Calling `ComputeAll` on a non-leader client with a synced dataset works identically (no leader-only guard needed).

### 3.8 Historical score-trend tracking

- [ ] `RecordScore` is a no-op when `profile.trackTrends = false`; no entries accumulate.
- [ ] `RecordScore` prunes entries older than `trendHistoryDays` before appending.
- [ ] `GetScoreTrend(name, itemID, days)` returns only entries matching the given `itemID`.
- [ ] `GetTrendSummary(name)` returns `nil` when fewer than 2 observations exist.
- [ ] After 4+ simulated nights of data, `GetTrendSummary` returns `{ first, last, delta, count }` with a meaningful delta.
- [ ] `scoreHistory` entries are not recorded on non-leader clients (`UnitIsGroupLeader` guard in `GetScore`).
- [ ] The "Track score trends" checkbox in the Tuning tab persists across `/reload`.
- [ ] The "Trend window (days)" slider range is 7–90; values outside this range are never written.
- [ ] Migration v2 fires once on the first login post-patch; `dbVersion` increments to 2 in SavedVariables.

---

## Schema Notes

### `scoreHistory` persistence shape

```lua
BobleLootDB = {
  profiles = {
    Default = {
      scoreHistory = {
        ["Sprinty-Doomhammer"] = {
          { ts = 1745352000, score = 72.4, itemID = 12345 },
          { ts = 1745438400, score = 69.1, itemID = 12345 },
          { ts = 1745438400, score = 81.3, itemID = 67890 },
          -- ...
        },
        -- per-character arrays, one entry per Compute call that returned
        -- a non-nil score, on the leader client only.
      },
    },
  },
}
```

**Pruning strategy:** Entries are pruned by `RecordScore` at write time, not at read time. Each call to `RecordScore` for a given character removes entries older than `trendHistoryDays * 86400` seconds before appending the new record. This keeps the work O(n) per character per call, where n is the number of entries — bounded by roughly `trendHistoryDays * avgItemsPerSession * sessionsPerDay`. For a 28-day window, a raid that processes 10 items per session and raids 3 times per week, that is at most `28 * 10 * 3 / 7 = 120` entries per raider. At ~40 bytes per entry (ts=8, score=8, itemID=4, table overhead ~20), this is under 5 KB per raider and well under 200 KB for a 20-person roster.

**No explicit "one per night" deduplication.** `RecordScore` is called once per `GetScore` call, which fires per candidate per session. If a leader opens the voting frame for the same item twice in one night, two records are appended. This is intentional: `GetScoreTrend` returns all matching entries, and the UI consumer decides whether to average within a day or show individual points. The storage cost of duplicates within one night is negligible.

**Pruning on login is not performed** (no startup prune). The TTL-at-write approach avoids an O(all characters) walk on every login. If a leader skips several raids, stale entries in other characters' arrays are pruned the next time `RecordScore` is called for that character.

### `wastedLootMap` persistence shape

```lua
BobleLootDB = {
  profiles = {
    Default = {
      wastedLootMap = {
        ["Sprinty-Doomhammer:12345"] = true,
        ["Boble-Doomhammer:67890"]   = true,
      },
    },
  },
}
```

**No TTL on wasted entries.** A traded-away item should be excluded from history indefinitely, not just for the current tier. If the leader later determines the flag was incorrect (player returned the item), `/bl wastedloot clear` removes all flags; there is no per-entry removal command in this plan (scope-bounded for 3B). A per-entry removal command (`/bl wasteloot remove <fp>`) is a natural extension in Batch 4 if demand surfaces.

---

## Coordination Notes

### 3D (Comparison Popout) and 3E (History Viewer, Bench UI) — downstream consumers of `ComputeAll`

Both 3D and 3E are UI-side plans that consume `ns.Scoring:ComputeAll(itemID)`. The contract is:

- **Return type:** `table` (never nil). An empty array `{}` is a valid return when no roster data is loaded.
- **Element shape:** `{ name: string, score: float 0-100, breakdown: table }` where `breakdown` matches the existing `Scoring:Compute` breakdown shape (componentName -> `{ value, raw, weight, effectiveWeight, contribution, ... }`).
- **Sort order:** Descending by `score`. Stable across equal scores only by name (Lua `table.sort` is not guaranteed stable — if 3D needs stable sort on ties, it must do a secondary sort itself).
- **Threading:** `ComputeAll` is synchronous and runs on the game thread. It iterates all `data.characters` entries; for a 30-person roster it runs in well under 1 ms. No async callback needed.
- **Mutation safety:** `ComputeAll` does not write to `data.characters` or any global. Callers may iterate the result array freely.

3E's Batch 3.13 bench UI uses `ComputeAll` to populate a scrolling table via `/bl benchscore`. The 3B data layer is complete when this plan is merged; 3E does not need to wait for any additional 3B deliverables.

### Batch 2D (Explain Panel) — consumer of `GetScoreTrend` and `GetTrendSummary`

The Explain Panel (`UI/ExplainPanel.lua`) from Batch 2D is the primary UI surface for score trends. The contract:

- `ns.Scoring:GetScoreTrend(name, itemID, days, profile)` → array of `{ ts, score }` sorted oldest-first. The UI renders this as a sparkline (series of points). If the array has 0 or 1 entries, the UI should show "Not enough data" rather than a flat line.
- `ns.Scoring:GetTrendSummary(name, profile)` → `{ first, last, delta, count }` or `nil`. When non-nil, the Explain Panel may render `"Score trend: +7.2 over 28 days"` or `"Score trend: -12.0 over 28 days"`. When nil, show nothing (no trend line).
- Both functions are safe to call on non-leader clients — they simply return empty results when `scoreHistory` is empty (non-leaders don't write to it).
- The sparkline format is points-only; the X axis is time (unix timestamp). The Explain Panel owns the rendering logic (axis labels, color ramp). 3B does not render any UI.

### 3C (RC Schema-Drift Detection) — `LootHistory.lua` read path

3C adds `LH:DetectSchemaVersion(db)` which reads the same `RCLootCouncilLootDB` that `LH:Apply` reads. Both plans touch `LootHistory.lua` but in non-overlapping sections:

- 3B adds: `MakeFingerprint`, `RegisterPendingAward`, `MarkWasted`, `IsWasted`, and the `wastedOk` guard in `CountItemsReceived`.
- 3C adds: `DetectSchemaVersion` and the `rcSchemaDetected` counter.
- Neither plan modifies `mergeFactionRealms`, `getRCLootDB`, `classify`, or the entry-time/ilvl helpers.
- The `CountItemsReceived` signature change (adding `profile` as fifth param) is 3B's. 3C must not add a conflicting fifth param. If 3C needs per-call profile access in its own new functions, it should accept `profile` as a separate parameter on those functions.
- **Merge order:** 3B should be merged before 3C to establish the `CountItemsReceived(rcLootDB, days, weights, minIlvl, profile)` signature. 3C's author should rebase onto 3B's branch.

### Batch 2B (Migrations framework) — prerequisite

This plan assumes `Migrations.lua` exists with a `STEPS` table and that `ns.Migrations:Run(addon)` is called from `Core:OnInitialize`. Task 2 of this plan adds step v2 to that table. If Batch 2B has not been merged when 3B is implemented, Task 2 must also create the `Migrations.lua` scaffolding (replicating Batch 2B Task 2). Document the dependency clearly in the PR description if that situation arises.

### Non-leader clients

- `RecordScore` and the `TRADE_CLOSED` handler both guard on `UnitIsGroupLeader("player")` to prevent non-leader clients from polluting `scoreHistory` or `wastedLootMap` with their own local state. The profile keys exist on all clients (AceDB syncs defaults), but they remain empty on non-leaders.
- `ComputeAll`, `GetScoreTrend`, and `GetTrendSummary` are read-only and may be called on any client. Non-leaders will see empty trend data until they become leader and accumulate a session's worth of records.
