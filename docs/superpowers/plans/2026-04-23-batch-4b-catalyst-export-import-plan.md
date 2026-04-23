# Batch 4B — Catalyst Tracking + Export/Import Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add synthetic loot-history entries for catalyst conversions and tier-token awards (items that bypass RC's own logging) and deliver a portable export/import pathway so a new raid leader can seed the addon with a full dataset on day one without Python or an API key.

**Architecture:** A new `CatalystTracker` section within `LootHistory.lua` hooks WoW item-acquisition events to detect catalyst conversions and tier-token awards, writing synthetic entries to `BobleLootDB.profile.synthHistory`. `LH:CountItemsReceived` is extended to merge these synthetic entries with RC's own history before computing totals, with a configurable weight (default `0.75x`). On the Python side, a new `--export` flag in `wowaudit.py` serialises the complete in-memory dataset to a portable JSON bundle (no secrets); on the Lua side, a `/bl importpaste` slash command opens a `StaticPopup` edit box where the raid leader pastes the JSON bundle, which is then parsed via `json.decode` (from a bundled lib or manual parser), loaded into `BobleLootSyncDB.data`, and broadcast to the raid via the existing `Sync:BroadcastNow` contract from Batch 1C.

**Tech Stack:** Python 3 (json, argparse, pytest), Lua (WoW 10.x), AceDB, AceEvent-3.0, WoW `StaticPopup` API, WoW item-acquisition events

**Roadmap items covered:**

> **4.2 `[Data]` Tier-token and catalyst item tracking**
>
> Catalyst conversions and tier-token awards bypass RC's normal logging.
> Hook `C_CurrencyInfo` vault/catalyst flows and `ITEM_CHANGED` to
> capture them. Weight separately (configurable, default 0.75x a normal
> drop).

> **4.3 `[Data]` Export / import for leader handoff**
>
> - `wowaudit.py --export <path.json>` writes a portable JSON bundle
>   (dataset + scoring config, no secrets).
> - `/bl import <path>` loads the JSON into `BobleLootSyncDB.data` and
>   re-broadcasts.
>
> Solves "I'm the new leader, I don't have Python or an API key on day one."

**Dependencies:**
- Batch 1C (`Sync.lua`): `Sync:BroadcastNow(addon)` is the contract `/bl importpaste` calls after loading the dataset. See Sync.lua line 279 for the current implementation: it calls `self:SendHello(addon)` which announces the version and triggers peers to REQ.
- Batch 2A (vault detection): `WEEKLY_REWARDS_ITEM_GRABBED` + `profile.vaultEntries` is 2A's mechanism for vault selections. This plan introduces a parallel `profile.synthHistory` table for catalyst/tier-token synthetic entries. The two tables are distinct: 2A's vault entries are produced by Great Vault interactions; 4.2's synthHistory entries are produced by the Catalyst UI and tier-token vendor interactions. The merge into `CountItemsReceived` is additive — both tables feed in.
- Batch 2B (Migrations.lua): `profile.synthHistory` needs initialisation. Migration step v2 (or the next available version in the sequential Migrations.STEPS table) initialises `profile.synthHistory = {}` if absent.
- Batch 3E (Toast system): import success and failure are surfaced via `addon:SendMessage("BobleLoot_ImportResult", ok, message)`. `UI/Toast.lua` listens for `BobleLoot_ImportResult` and shows green on success, red on failure. The event contract is defined in Task 6 of this plan.
- 4E (Empty/error states): the paste edit box must have defined empty and error states. See cross-coordination notes at the bottom of this plan.

---

## WoW API Research Findings

This section documents findings from WoW community wiki, AddOn developer forums, and comparison with RC's own event usage (RC's `LootHistory.lua` and `Core.lua` are established references for event patterns).

### Catalyst conversion detection

The Catalyst UI (item upgrade station in Amirdrassil/Aberrus/etc.) does **not** fire a standard `CHAT_MSG_LOOT` event because the player receives a transformed copy of an item they already owned — it is not a loot roll. The item is delivered to the player's bags, which fires:

- `BAG_UPDATE_DELAYED` — fires after any bag change; too broad to identify catalyst conversions specifically.
- `ITEM_PUSH` — fires when an item is pushed into the backpack from the bank or a loot roll. May fire on catalyst delivery. **TODO verify in-game.**
- `NEW_ITEM_ADDED` — fires when a brand-new item is added to the player's inventory, with arguments `(bagID, slotID)`. This is the most targeted event for "player just received an item not from a boss loot roll". **TODO verify in-game whether catalyst delivery fires this event.**
- `PLAYER_EQUIPMENT_CHANGED` — fires `(slotID, hasNewItem)` when a player equips an item. This fires when the player equips the catalysed piece, not when it arrives in bags. Useful as a secondary signal to cross-reference the item, but not the primary detection event.

The planned detection chain for catalyst conversions:
1. Register `NEW_ITEM_ADDED`. On fire, call `C_Item.GetItemInfo(bagID, slotID)` to get the item link.
2. Compare the item's `item:GetItemInfo()` flags — specifically check if the item has the "Catalyst" tooltip tag via `C_TooltipInfo.GetBagItem(bagID, slotID)`. **TODO verify: does the catalyst-converted item retain a "Catalyst" tooltip flag after delivery, or is the only signal the timing of item acquisition relative to the Catalyst UI frame being open (`_G.ItemInteractionFrame` or `_G.UIParent:GetChildren()` scan)?**
3. Alternative signal: `C_ItemInteraction.IsReady()` returns true when the Catalyst UI is open. Record `isInteracting = C_ItemInteraction.IsReady()` at the moment `NEW_ITEM_ADDED` fires. If true, mark the entry as a `catalyst` synthetic type. **TODO verify API name is `C_ItemInteraction` (not `C_CatalystUI`).**
4. If `NEW_ITEM_ADDED` is not reliable for catalyst delivery, fall back to `BAG_UPDATE_DELAYED` gated by `C_ItemInteraction.IsReady()`, capturing what changed in the last bag-update cycle.

**Assumption (document for executor):** The Catalyst UI interaction is the primary gate. If `C_ItemInteraction.IsReady()` is `true` at the moment of bag change, the arriving item is treated as a catalyst conversion. This is a heuristic, not a guaranteed signal — a simultaneous bag change (trading, looting) during a catalyst session would produce a false positive. Mitigation: only record one synthetic entry per catalyst session (track `_catalystSessionItem` and nil it after recording).

### Tier-token awards

Tier tokens (e.g., tokens from the Great Vault or boss drops that are exchanged at a vendor for tier set pieces) are traded for the actual tier piece at the token vendor. The token is consumed and a new item is delivered to bags. Events:

- `UNIT_SPELLCAST_SUCCEEDED` with the spell being the "Equip Item" or vendor transaction spell. Not reliable; spell IDs change per tier.
- `MERCHANT_CLOSED` or `VENDOR_SHOW`/`VENDOR_HIDE` events paired with bag change. If the player's bags change within the same event cycle as a vendor interaction, the new items were purchased/exchanged.
- `BAG_NEW_ITEMS_UPDATED` — a new event in 10.x that fires specifically when new items are added by name/ID-distinct from the previous bag state. **TODO verify: does this event exist in WoW 10.2+? Check with `/run print(C_EventUtils.GetEventInfo("BAG_NEW_ITEMS_UPDATED"))`.**
- `NEW_ITEM_ADDED` — same event as above; this is the most likely candidate for tier-token exchange as well.

**Simplified detection heuristic for tier-token exchange:**
Track `_vendorOpen` boolean set true on `MERCHANT_SHOW` and false on `MERCHANT_CLOSED`. If `NEW_ITEM_ADDED` fires while `_vendorOpen` is true and the item is a tier-set piece (check `GetItemSetID(link) ~= nil` or check if the item's class/subclass is Armor and it belongs to a set via `C_Item.GetItemSetInfo`), record it as a `tiertoken` synthetic entry. **TODO verify: `C_Item.GetItemSetInfo(itemID)` — confirm this API returns non-nil for tier set pieces.**

### Great Vault selections

Batch 2A (plan `2026-04-23-batch-2a-scoring-maturity-plan.md`, Task 9) established `WEEKLY_REWARDS_ITEM_GRABBED` as the canonical event for Great Vault selections. That plan writes to `profile.vaultEntries`. This plan does **not** change that mechanism. The two systems coexist:

- `WEEKLY_REWARDS_ITEM_GRABBED` → `profile.vaultEntries` (Batch 2A, category: `vault`, weight: `0.5x`)
- Catalyst / tier-token detection → `profile.synthHistory` (this plan, categories: `catalyst`/`tiertoken`, weight: `0.75x` by default)

The distinction is intentional: vault items are "free" weekly selections (least lucky); catalyst items cost currency (moderately lucky — not as random as a boss drop); tier tokens may come from boss drops but require a second step (moderately lucky). Using the same category for all three would lose nuance. Using separate storage (`vaultEntries` vs `synthHistory`) keeps the two batch implementations decoupled.

**4.2 does NOT supersede 2A's vault detection.** It extends the overall synthetic-entry picture. The executor must ensure both tables are merged in `CountItemsReceived`.

### C_FileSystem feasibility

WoW's Lua sandbox does **not** expose a general-purpose file-read API for arbitrary user paths. `C_FileSystem.ReadFile(path)` was explored by the addon community but is not a public, documented, or accessible function in retail WoW as of 10.2. The only filesystem operations available are:

- Writing to SavedVariables (managed by the WoW client automatically on logout/reload).
- Reading the `WTF/` account directory indirectly via SavedVariables globals.
- `C_FileSystem.MakeDir` — exists but is write-only and restricted.

**Conclusion:** `/bl import <path>` reading an arbitrary file path is **not feasible** in retail WoW's Lua sandbox. The implementation uses `/bl importpaste` instead: a `StaticPopup` edit box where the leader pastes the JSON text. The executor must document this in the in-game slash command help string. The Python `--export` flag writes human-readable JSON the leader can open in any text editor, copy, and paste.

---

## File Structure

```
BobleLoot/
├── BobleLoot.toc                     -- no new file entries needed (LootHistory.lua
│                                     --   already loaded; CatalystTracker is a section
│                                     --   within it, not a new module)
├── Core.lua                          -- /bl importpaste slash subcommand
│                                     --   /bl synthhistory diagnostic subcommand
│                                     --   AceDB defaults: synthWeight, synthHistory
│                                     --   OnEnable: wire CatalystTracker:Setup
├── LootHistory.lua                   -- CatalystTracker section (new events, new APIs)
│                                     --   LH:CountItemsReceived merges synthHistory
│                                     --   LH:CountItemsReceivedAsync merges synthHistory
│                                     --   Migration init helper for profile.synthHistory
├── UI/SettingsPanel.lua              -- "Synthetic history weight" slider in Tuning tab
│                                     --   "Import dataset" button in Data tab
│                                     --   (button opens importpaste StaticPopup)
└── tools/
    ├── wowaudit.py                   -- --export <path.json> flag
    │                                 --   export_bundle() function
    └── tests/
        └── test_wowaudit.py          -- new TestExportBundle test class
```

**No new TOC entries required.** `LootHistory.lua` already loads in the correct position. The `CatalystTracker` section is appended within the same file, sharing the `LH` module table. `UI/SettingsPanel.lua` is already in the TOC; the import button and weight slider are additive changes.

---

## Tasks

---

### Task 1 — AceDB defaults and Migration init for `synthHistory`

**Files:** `Core.lua`, `Migrations.lua` (if Batch 2B has shipped; otherwise inline in `Core.lua`)

`BobleLootDB.profile.synthHistory` is a list of synthetic loot entries. `BobleLootDB.profile.synthWeight` is the per-entry multiplier (default `0.75`). Both must be present before `LootHistory.lua` references them.

#### Steps

- [ ] **1.1** Open `Core.lua`. In `DB_DEFAULTS.profile`, add two new keys after the existing `historyCap` line:

  ```lua
  synthWeight    = 0.75,   -- weight of synthetic (catalyst/tier-token) entries
                            -- relative to a normal RC drop (1.0). Configurable.
  synthHistory   = {},      -- list of synthetic loot entries:
                            --   { name, itemID, itemLink, t, synthType, weight }
                            --   synthType: "catalyst" | "tierttoken"
  ```

- [ ] **1.2** If `Migrations.lua` (Batch 2B) is present in the TOC, add a migration step. Open `Migrations.lua` and add a new step at the end of `Migrations.STEPS`:

  ```lua
  -- v2: Initialise profile.synthHistory table for 4.2 catalyst/tier-token tracking.
  -- Safe to run repeatedly: only writes when the key is absent.
  {
      version = 2,
      run = function(profile, _addon)
          if profile.synthHistory == nil then
              profile.synthHistory = {}
          end
          if profile.synthWeight == nil then
              profile.synthWeight = 0.75
          end
      end,
  },
  ```

  If `Migrations.lua` is not yet present (Batch 2B not shipped), the AceDB defaults in step 1.1 are sufficient — AceDB initialises missing profile keys from defaults on first load.

- [ ] **1.3** Verify:

  ```
  /reload
  /dump BobleLootDB.profile.synthHistory
  /dump BobleLootDB.profile.synthWeight
  ```

  Expected: `{}` and `0.75` respectively.

- [ ] **1.4** Commit:

  ```
  git add Core.lua
  git commit -m "Add synthHistory/synthWeight AceDB defaults for catalyst tracking (roadmap 4.2)"
  ```

---

### Task 2 — CatalystTracker event detection in `LootHistory.lua`

**Files:** `LootHistory.lua` — new `CatalystTracker` section appended at the bottom of the file (after `LH:Setup`).

This section registers the item-acquisition events and writes synthetic entries to `BobleLootDB.profile.synthHistory`. It is self-contained: all event registration is in `CatalystTracker:Setup(addon)`, called from `Core.lua:OnEnable` after `LootHistory:Setup`.

The detection heuristic uses `NEW_ITEM_ADDED` as the primary signal and `C_ItemInteraction.IsReady()` as the catalyst gate, with `_vendorOpen` (set by `MERCHANT_SHOW`/`MERCHANT_CLOSED`) as the tier-token gate. Both gates default to a no-op if the respective API does not exist (WoW version compat).

#### Steps

- [ ] **2.1** Append the following section to `LootHistory.lua` after the existing `LH:Setup` function:

  ```lua
  -- ─────────────────────────────────────────────────────────────────────────
  -- CatalystTracker: synthetic history for catalyst conversions and tier tokens
  -- Roadmap item 4.2.
  --
  -- Detection heuristics (see plan 2026-04-23-batch-4b for full rationale):
  --   Catalyst: NEW_ITEM_ADDED fires while C_ItemInteraction.IsReady() is true.
  --   Tier token: NEW_ITEM_ADDED fires while _vendorOpen is true AND the item
  --               belongs to a gear set (C_Item.GetItemSetInfo returns non-nil).
  --
  -- TODO verify in-game: NEW_ITEM_ADDED fires for catalyst delivery.
  -- TODO verify in-game: C_ItemInteraction.IsReady() name and availability.
  -- TODO verify in-game: C_Item.GetItemSetInfo availability and return shape.
  -- ─────────────────────────────────────────────────────────────────────────

  local CatalystTracker = {}
  ns.CatalystTracker = CatalystTracker

  -- Session state (not persisted).
  CatalystTracker._vendorOpen      = false
  CatalystTracker._lastCatalystItem = nil  -- dedup: itemID of last catalyst entry recorded

  local function isCatalystOpen()
      -- C_ItemInteraction.IsReady() returns true when the Catalyst frame is active.
      -- API existence guard: C_ItemInteraction may not exist on older clients.
      if C_ItemInteraction and C_ItemInteraction.IsReady then
          return C_ItemInteraction.IsReady() == true
      end
      return false
  end

  local function getItemSetID(link)
      -- C_Item.GetItemSetInfo(itemID) returns a table or nil.
      -- We only need to know if the item belongs to a set.
      if not C_Item or not C_Item.GetItemSetInfo then return nil end
      local itemID = link and tonumber(link:match("item:(%d+)"))
      if not itemID then return nil end
      local ok, info = pcall(C_Item.GetItemSetInfo, itemID)
      return (ok and type(info) == "table") and info or nil
  end

  -- Write a synthetic entry to BobleLootDB.profile.synthHistory.
  -- synthType: "catalyst" or "tierttoken"
  -- Deduplication: skip if an entry for the same (name, itemID) was recorded
  -- within the last 10 seconds (catches rapid bag-update bursts).
  function CatalystTracker:RecordEntry(addon, name, itemLink, itemID, synthType)
      local profile = addon.db.profile
      profile.synthHistory = profile.synthHistory or {}

      local now = time()
      -- Dedup: scan recent entries.
      for i = #profile.synthHistory, math.max(1, #profile.synthHistory - 5), -1 do
          local e = profile.synthHistory[i]
          if e and e.name == name and e.itemID == itemID and (now - (e.t or 0)) < 10 then
              return  -- duplicate within 10s window; discard
          end
      end

      local weight = (profile.synthWeight ~= nil) and profile.synthWeight or 0.75
      table.insert(profile.synthHistory, {
          name      = name,
          itemID    = itemID,
          itemLink  = itemLink or "",
          t         = now,
          synthType = synthType,
          weight    = weight,
      })

      -- Trigger a history re-apply so scores update immediately.
      C_Timer.After(1, function()
          if ns.LootHistory and ns.LootHistory.Apply then
              ns.LootHistory:Apply(addon)
          end
      end)

      if addon and addon.Print then
          addon:Print(string.format(
              "Synthetic loot recorded: %s received %s via %s (weight=%.2f)",
              name, tostring(itemLink or itemID), synthType, weight))
      end
  end

  function CatalystTracker:Setup(addon)
      self.addon = addon
      local playerName = UnitName("player") .. "-" .. GetRealmName()

      local f = CreateFrame("Frame")
      -- Tier-token gate: track vendor open/close state.
      f:RegisterEvent("MERCHANT_SHOW")
      f:RegisterEvent("MERCHANT_CLOSED")
      -- Primary item-acquisition signal.
      -- NEW_ITEM_ADDED fires (bagID, slotID) when a new item arrives in bags.
      -- TODO verify in-game: confirm this event fires for catalyst deliveries.
      f:RegisterEvent("NEW_ITEM_ADDED")

      f:SetScript("OnEvent", function(_, event, arg1, arg2)
          if event == "MERCHANT_SHOW" then
              CatalystTracker._vendorOpen = true
              return
          end
          if event == "MERCHANT_CLOSED" then
              CatalystTracker._vendorOpen = false
              return
          end
          if event == "NEW_ITEM_ADDED" then
              local bagID, slotID = arg1, arg2
              -- Determine detection path.
              local synthType = nil
              if isCatalystOpen() then
                  synthType = "catalyst"
              elseif CatalystTracker._vendorOpen then
                  -- Only record vendor-acquired items that are tier set pieces.
                  local link = C_Container and C_Container.GetContainerItemLink(bagID, slotID)
                               or GetContainerItemLink(bagID, slotID)
                  if link and getItemSetID(link) then
                      synthType = "tierttoken"
                  end
              end

              if not synthType then return end

              -- Get item info.
              local link = C_Container and C_Container.GetContainerItemLink(bagID, slotID)
                           or GetContainerItemLink(bagID, slotID)
              if not link then return end
              local itemID = tonumber(link:match("item:(%d+)"))
              if not itemID then return end

              CatalystTracker:RecordEntry(addon, playerName, link, itemID, synthType)
          end
      end)
  end
  ```

- [ ] **2.2** In `Core.lua:OnEnable`, after the `LootHistory:Setup` call, add:

  ```lua
  if ns.CatalystTracker and ns.CatalystTracker.Setup then
      ns.CatalystTracker:Setup(self)
  end
  ```

- [ ] **2.3** Verify the module loads without error:

  ```
  /reload
  /run print(tostring(ns.CatalystTracker ~= nil))
  ```

  Expected: `true`

- [ ] **2.4** Commit:

  ```
  git add LootHistory.lua Core.lua
  git commit -m "Add CatalystTracker event detection for catalyst/tier-token synthetic history (roadmap 4.2)"
  ```

---

### Task 3 — Merge `synthHistory` into `LH:CountItemsReceived`

**Files:** `LootHistory.lua` — extend `CountItemsReceived`, `CountItemsReceivedAsync`, and `processEntry`-level logic to also process `profile.synthHistory`.

The merge strategy: synthetic entries are pre-processed into the same `result[name]` row format as RC entries, with their `weight` field used directly (it was baked in at record-time). The cut-off filter (`lootHistoryDays`) and `minIlvl` filter are applied to synthetic entries the same way as RC entries: `t` field for time, `itemID` for ilvl lookup (we skip ilvl filtering for synthetic entries whose ilvl cannot be readily queried without an async `C_Item.RequestLoadItemDataByID` call — document this shortcut).

#### Steps

- [ ] **3.1** In `LootHistory.lua`, modify `LH:CountItemsReceived` to accept an optional `synthEntries` parameter and merge them:

  ```lua
  -- Synchronous version. synthEntries is optional (nil = no synthetic entries).
  -- synthEntries format: list of { name, itemID, itemLink, t, synthType, weight }
  function LH:CountItemsReceived(rcLootDB, days, weights, minIlvl, synthEntries)
      local cutoff = (days and days > 0) and (time() - days * 24 * 3600) or nil
      minIlvl = minIlvl or 0
      local result = {}
      if type(rcLootDB) ~= "table" then return result end
      for name, entries in pairs(rcLootDB) do
          if type(entries) == "table" then
              local row = newRow()
              for _, e in ipairs(entries) do
                  processEntry(e, row, cutoff, weights, minIlvl)
              end
              result[name] = row
          end
      end
      -- Merge synthetic entries (catalyst / tier-token).
      -- NOTE: ilvl filtering is skipped for synthetic entries because
      -- querying item level without an async API call is not reliable.
      -- Time-window filtering still applies.
      if type(synthEntries) == "table" then
          for _, e in ipairs(synthEntries) do
              if type(e) == "table" and type(e.name) == "string" then
                  local t = e.t
                  local timeOk = (not cutoff) or (not t) or t >= cutoff
                  if timeOk then
                      local row = result[e.name] or newRow()
                      result[e.name] = row
                      -- Synthetic entries carry their own pre-computed weight.
                      row.total = row.total + (e.weight or 0.75)
                      local cat = e.synthType or "mainspec"
                      row.counts[cat] = (row.counts[cat] or 0) + 1
                  end
              end
          end
      end
      return result
  end
  ```

- [ ] **3.2** Apply the same merge pattern to `LH:CountItemsReceivedAsync`. The async variant receives `synthEntries` and processes them in the final callback (not chunked — the synth list is always small):

  ```lua
  function LH:CountItemsReceivedAsync(rcLootDB, days, weights, minIlvl, onDone, synthEntries)
      -- ... (existing chunked walk, unchanged) ...
      -- In the final callback, after stripping _cursor fields:
      --   mergeSynthEntries(result, synthEntries, cutoff)
      --   onDone(result)
  end
  ```

  Add a local helper `mergeSynthEntries(result, synthEntries, cutoff)` that contains the synthetic merge logic extracted from step 3.1, so both the sync and async paths share identical logic.

- [ ] **3.3** In `LH:Apply`, pass `profile.synthHistory` when calling `CountItemsReceivedAsync`:

  ```lua
  self:CountItemsReceivedAsync(db, days, weights, minIlvl, function(rows)
      -- ... existing callback body ...
  end, profile.synthHistory or {})
  ```

- [ ] **3.4** In the `/bl lootdb` diagnostic output (Core.lua), ensure the printed summary notes synthetic entries. Add to `LH:Diagnose`:

  ```lua
  local synth = addon.db.profile.synthHistory or {}
  addon:Print(string.format("Synthetic history entries: %d", #synth))
  for i, e in ipairs(synth) do
      if i > 10 then addon:Print("  (truncated at 10)"); break end
      addon:Print(string.format("  [%d] %s %s %s",
          i, e.name or "?", e.synthType or "?",
          date("%Y-%m-%d", e.t or 0)))
  end
  ```

- [ ] **3.5** Verify:

  Manually insert a test synthetic entry then run lootdb:
  ```
  /run table.insert(BobleLootDB.profile.synthHistory, { name="TestChar-Realm", itemID=12345, t=time(), synthType="catalyst", weight=0.75 })
  /bl lootdb
  ```

  Expected: the lootdb output shows `Synthetic history entries: 1` and the entry details.

- [ ] **3.6** Commit:

  ```
  git add LootHistory.lua Core.lua
  git commit -m "Merge synthHistory into CountItemsReceived for catalyst/tier-token entries (roadmap 4.2)"
  ```

---

### Task 4 — `/bl synthhistory` diagnostic slash command

**Files:** `Core.lua` — add a diagnostic subcommand for the synthetic history table.

#### Steps

- [ ] **4.1** In `Core.lua:OnSlashCommand`, add a new `elseif` branch after the `lootdb` branch:

  ```lua
  elseif input == "synthhistory" or input == "synth" then
      local synth = self.db.profile.synthHistory or {}
      if #synth == 0 then
          self:Print("No synthetic loot entries recorded this session.")
      else
          self:Print(string.format("%d synthetic loot entr%s:",
              #synth, #synth == 1 and "y" or "ies"))
          for i, e in ipairs(synth) do
              self:Print(string.format("  [%d] %s | %s | %s | w=%.2f | %s",
                  i,
                  e.name or "?",
                  e.itemLink or tostring(e.itemID or "?"),
                  e.synthType or "?",
                  e.weight or 0,
                  date("%Y-%m-%d %H:%M", e.t or 0)))
          end
      end
  ```

- [ ] **4.2** Update the help string in the `else` branch to include `synthhistory`:

  ```lua
  self:Print("Commands: /bl config | /bl version | /bl broadcast | " ..
      "/bl transparency on|off | /bl checkdata | /bl lootdb | " ..
      "/bl synthhistory | /bl importpaste | " ..
      "/bl debugchar <Name-Realm> | /bl test [N] | " ..
      "/bl score <itemID> <Name-Realm> | /bl syncwarnings")
  ```

- [ ] **4.3** Verify:

  ```
  /bl synthhistory
  ```

  Expected: `No synthetic loot entries recorded this session.` (until a catalyst or tier-token event fires).

- [ ] **4.4** Commit:

  ```
  git add Core.lua
  git commit -m "Add /bl synthhistory diagnostic for synthetic loot entries (roadmap 4.2)"
  ```

---

### Task 5 — `wowaudit.py --export` flag and `export_bundle()` function

**Files:** `tools/wowaudit.py`

The `--export` flag is additive: it can be combined with any other flag. After the normal run completes (or after a convert-mode run, or even standalone with a `--load-bundle` round-trip), `export_bundle()` serialises the full in-memory dataset to a JSON file at the given path. No API key is embedded. The bundle format is defined here as the authoritative schema.

#### Bundle JSON schema

```json
{
  "schema": "bobleloot-export-v1",
  "exportedAt": "2026-04-23T12:00:00Z",
  "scoringConfig": {
    "simCap": 5.0,
    "mplusCap": 40,
    "historyCap": 5,
    "weights": {
      "sim": 0.40,
      "bis": 0.20,
      "history": 0.15,
      "attendance": 0.15,
      "mplus": 0.10
    }
  },
  "characters": {
    "Name-Realm": {
      "attendance": 0.95,
      "mplusDungeons": 30,
      "mainspec": "Holy",
      "role": "raider",
      "bis": [12345, 67890],
      "sims": { "12345": 2.9, "67890": 1.1 }
    }
  },
  "generatedAt": "2026-04-23T12:00:00Z",
  "teamUrl": "https://wowaudit.com/eu/draenor/voidstorm/dashboard"
}
```

The `scoringConfig` block captures the CLI-applied caps (not the profile values inside the addon). The recipient's addon reads `characters` and `generatedAt` directly; `scoringConfig` is informational (the importer does not apply it to the addon's profile — the profile is the leader's own AceDB settings, which may differ).

#### Steps

- [ ] **5.1** In `wowaudit.py`, add the `--export` argument to the `argparse` block:

  ```python
  ap.add_argument("--export", type=Path, default=None, metavar="PATH",
                  help="After building, write a portable JSON bundle to PATH "
                       "(no API key embedded). Use /bl importpaste in-game to load it.")
  ```

- [ ] **5.2** Add the `export_bundle()` function after `build_lua()`:

  ```python
  def export_bundle(
      rows: list[dict],
      bis: dict[str, list[int]],
      sim_cap: float,
      mplus_cap: int,
      history_cap: int,
      team_url: str | None = None,
      weights: dict | None = None,
  ) -> dict:
      """Build and return the portable export bundle as a Python dict.

      Args:
          rows:         Same row list used by build_lua().
          bis:          BiS mapping {name: [itemIDs]}.
          sim_cap:      Sim cap value used in this run.
          mplus_cap:    M+ cap value used in this run.
          history_cap:  History cap value used in this run.
          team_url:     Optional wowaudit team URL.
          weights:      Optional scoring weights dict (sim/bis/history/attendance/mplus).
                        If None, the BobleLoot defaults are used.

      Returns:
          A dict suitable for json.dumps() matching the bobleloot-export-v1 schema.
      """
      now_iso = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

      default_weights = {
          "sim": 0.40, "bis": 0.20, "history": 0.15,
          "attendance": 0.15, "mplus": 0.10,
      }

      sim_cols_set: set[str] = set()
      for r in rows:
          for c in r.keys():
              if c.startswith("sim_") and c[4:].isdigit():
                  sim_cols_set.add(c)

      characters: dict = {}
      for row in rows:
          name = (row.get("character") or "").strip()
          if not name:
              continue
          bis_ids = bis.get(name) or []
          sims: dict[int, float] = {}
          for col in sim_cols_set:
              val_raw = row.get(col)
              if val_raw not in (None, ""):
                  val = _to_float(val_raw, default=None)
                  if val is not None:
                      sims[int(col[4:])] = val
          char: dict = {
              "attendance":     _to_float(row.get("attendance")),
              "mplusDungeons":  _to_int(row.get("mplus_dungeons")),
              "bis":            [int(i) for i in bis_ids],
              "sims":           sims,
          }
          if row.get("mainspec"):
              char["mainspec"] = str(row["mainspec"])
          if row.get("role"):
              char["role"] = str(row["role"])
          characters[name] = char

      bundle = {
          "schema":        "bobleloot-export-v1",
          "exportedAt":    now_iso,
          "generatedAt":   now_iso,
          "scoringConfig": {
              "simCap":      sim_cap,
              "mplusCap":    mplus_cap,
              "historyCap":  history_cap,
              "weights":     weights or default_weights,
          },
          "characters":    characters,
      }
      if team_url:
          bundle["teamUrl"] = team_url
      return bundle
  ```

- [ ] **5.3** In `main()`, after the `build_lua()` call and the `args.out.write_text(...)` call, add export handling:

  ```python
  if args.export is not None:
      bundle = export_bundle(
          rows, bis,
          sim_cap=args.sim_cap,
          mplus_cap=mplus_cap,
          history_cap=args.history_cap,
          team_url=team_url,
      )
      args.export.parent.mkdir(parents=True, exist_ok=True)
      args.export.write_text(
          json.dumps(bundle, indent=2, ensure_ascii=False),
          encoding="utf-8",
      )
      print(f"Exported bundle to {args.export}: "
            f"{len(bundle['characters'])} characters.")
  ```

- [ ] **5.4** Verify (command line):

  ```bash
  cd tools
  python wowaudit.py --wowaudit sample_input/sample.csv --bis sample_input/bis.json \
      --export /tmp/test_bundle.json
  cat /tmp/test_bundle.json | python -m json.tool | head -30
  ```

  Expected: valid JSON with `schema: "bobleloot-export-v1"`, `characters` dict, `scoringConfig` block, no API key.

- [ ] **5.5** Commit:

  ```
  git add tools/wowaudit.py
  git commit -m "Add --export flag and export_bundle() for portable JSON handoff (roadmap 4.3)"
  ```

---

### Task 6 — pytest for `export_bundle()` round-trip

**Files:** `tools/tests/test_wowaudit.py` (create if not present; extend if present)

The test file may not yet exist on the current branch (no `tools/tests/` directory was found). Create it. It mirrors the style established in Batch 1A's plan.

#### Steps

- [ ] **6.1** Ensure `tools/tests/__init__.py` exists (empty file for pytest discovery):

  ```bash
  touch tools/tests/__init__.py
  ```

- [ ] **6.2** Create `tools/tests/test_wowaudit.py` (or append if already present). Add a `TestExportBundle` class:

  ```python
  """Tests for wowaudit.py — export_bundle() and --export flag."""
  import json
  import sys
  from pathlib import Path

  import pytest

  # Allow importing wowaudit from the tools/ directory.
  sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
  import wowaudit as wa


  SAMPLE_ROWS = [
      {
          "character": "Boble-Draenor",
          "attendance": "95",
          "mplus_dungeons": "30",
          "sim_12345": "2.9",
          "sim_67890": "1.1",
          "mainspec": "Holy",
          "role": "raider",
      },
      {
          "character": "Kotoma-Draenor",
          "attendance": "80",
          "mplus_dungeons": "15",
          "mainspec": "Protection",
          "role": "trial",
      },
  ]

  SAMPLE_BIS = {
      "Boble-Draenor": [12345, 67890],
      "Kotoma-Draenor": [],
  }


  class TestExportBundle:
      def test_schema_field_present(self):
          bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
          assert bundle["schema"] == "bobleloot-export-v1"

      def test_character_count(self):
          bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
          assert len(bundle["characters"]) == 2

      def test_bis_round_trip(self):
          bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
          char = bundle["characters"]["Boble-Draenor"]
          assert set(char["bis"]) == {12345, 67890}

      def test_sims_round_trip(self):
          bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
          char = bundle["characters"]["Boble-Draenor"]
          assert char["sims"][12345] == pytest.approx(2.9)
          assert char["sims"][67890] == pytest.approx(1.1)

      def test_mainspec_and_role_included(self):
          bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
          char = bundle["characters"]["Boble-Draenor"]
          assert char["mainspec"] == "Holy"
          assert char["role"] == "raider"

      def test_scoring_config_preserved(self):
          bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
          cfg = bundle["scoringConfig"]
          assert cfg["simCap"] == 5.0
          assert cfg["mplusCap"] == 40
          assert cfg["historyCap"] == 5

      def test_no_api_key_in_bundle(self):
          """The exported bundle must never contain API credentials."""
          bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
          bundle_str = json.dumps(bundle)
          assert "api_key" not in bundle_str.lower()
          assert "authorization" not in bundle_str.lower()
          assert "WOWAUDIT_API_KEY" not in bundle_str

      def test_empty_rows_produces_empty_characters(self):
          bundle = wa.export_bundle([], {}, 5.0, 40, 5)
          assert bundle["characters"] == {}

      def test_team_url_optional(self):
          without = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
          assert "teamUrl" not in without

          with_url = wa.export_bundle(
              SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5,
              team_url="https://wowaudit.com/eu/test"
          )
          assert with_url["teamUrl"] == "https://wowaudit.com/eu/test"

      def test_json_serialisable(self):
          """The bundle must be serialisable to JSON without errors."""
          bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
          result = json.dumps(bundle)
          reloaded = json.loads(result)
          assert reloaded["schema"] == "bobleloot-export-v1"

      def test_character_missing_sims_still_included(self):
          """Characters without sim columns must still appear with empty sims."""
          bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
          char = bundle["characters"]["Kotoma-Draenor"]
          assert char["sims"] == {}

      def test_export_flag_writes_file(self, tmp_path):
          """Integration: passing rows directly to export_bundle and writing JSON."""
          out = tmp_path / "bundle.json"
          bundle = wa.export_bundle(SAMPLE_ROWS, SAMPLE_BIS, 5.0, 40, 5)
          out.write_text(json.dumps(bundle, indent=2), encoding="utf-8")
          loaded = json.loads(out.read_text(encoding="utf-8"))
          assert loaded["schema"] == "bobleloot-export-v1"
          assert "Boble-Draenor" in loaded["characters"]
  ```

- [ ] **6.3** Run the test suite:

  ```bash
  cd "E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot"
  python -m pytest tools/tests/test_wowaudit.py -v
  ```

  Expected: all `TestExportBundle` tests pass.

- [ ] **6.4** Commit:

  ```
  git add tools/tests/test_wowaudit.py tools/tests/__init__.py
  git commit -m "Add pytest TestExportBundle class for export_bundle() round-trip (roadmap 4.3)"
  ```

---

### Task 7 — In-game JSON parser (minimal, inline)

**Files:** `Core.lua` — a minimal JSON-to-Lua-table parser for the import paste path.

WoW's Lua environment does not include a JSON library. The bundle produced by `--export` must be parseable in-game. Two options:

**Option A:** Bundle a Lua JSON library (e.g., a single-file `json.lua`). Requires a new TOC entry and a library file.

**Option B:** Write a minimal inline parser that handles only the subset of JSON the export bundle produces (no arbitrary nesting beyond two levels, no exotic escapes, no `null` in values the addon cares about).

**Decision: Option A using a battle-tested single-file library.** The export bundle contains nested objects and integer keys (from the `sims` table). A hand-rolled parser risks correctness bugs that would silently import wrong data. The WoW addon community has established `dkjson.lua` (public domain, single file, ~500 lines) as the standard embedded JSON library. It is also used by WeakAuras and DBM. Alternatively, `LibJSON` exists as a LibStub-compatible wrapper. Either approach: one file added to `Libs/`, one TOC entry, no external dependencies.

**Recommendation:** Embed `dkjson.lua` (public domain, no license burden) as `Libs/dkjson.lua`. Add `Libs\dkjson.lua` to `embeds.xml` or directly to `BobleLoot.toc` before `Core.lua`.

The executor should:
1. Download `dkjson.lua` from https://dkolf.de/src/dkjson-lua.fsl/wiki?name=Documentation or copy from an existing addon (it is public domain).
2. Confirm the version is 2.5 or later (has `dkjson.use_lpeg = false` near the top to disable LPeg dependency).
3. Place at `Libs/dkjson.lua`.
4. Add `Libs\dkjson.lua` to `BobleLoot.toc` immediately before `Core.lua`.
5. In `Core.lua`, access via the global `dkjson` (it registers as a global, not via LibStub).

For this plan, the JSON decoding call is:

```lua
local ok, result = pcall(dkjson.decode, pastedText)
```

**TODO verify in-game:** Confirm `dkjson.lua` loads without errors under WoW's Lua 5.1 runtime. The `pcall` wrapper in the import code ensures any parse errors are surfaced cleanly rather than crashing the addon.

#### Steps

- [ ] **7.1** Obtain `dkjson.lua` (public domain, version 2.5+). Place at:

  `E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/Libs/dkjson.lua`

- [ ] **7.2** Open `BobleLoot.toc`. Add `Libs\dkjson.lua` before `Core.lua`:

  ```
  embeds.xml
  Libs\dkjson.lua

  Data\BobleLoot_Data.lua

  Core.lua
  ```

- [ ] **7.3** Verify:

  ```
  /reload
  /run print(type(dkjson))
  /run local t = dkjson.decode('{"hello":1}'); print(t.hello)
  ```

  Expected: `table` and `1`.

- [ ] **7.4** Commit:

  ```
  git add Libs/dkjson.lua BobleLoot.toc
  git commit -m "Embed dkjson.lua for in-game JSON parsing (needed by /bl importpaste)"
  ```

---

### Task 8 — `/bl importpaste` slash command and StaticPopup

**Files:** `Core.lua`

The `importpaste` command opens a `StaticPopup` with a multi-line `EditBox` where the leader pastes the bundle JSON. On confirm, the text is decoded with `dkjson.decode`, validated against the expected schema, loaded into `BobleLootSyncDB.data` and `_G.BobleLoot_Data`, and then `Sync:BroadcastNow(self)` is called.

**Empty-state and error-state contract (see 4E coordination notes):**
- Empty paste (confirm with blank box): show error toast "Import failed: paste is empty."
- Invalid JSON: show error toast "Import failed: JSON parse error."
- Valid JSON but missing `characters` key: show error toast "Import failed: not a BobleLoot bundle."
- Valid schema but zero characters: show warning toast "Imported bundle has 0 characters — check the export."
- Success: show success toast "Imported N characters from bundle. Broadcasting..."

All feedback uses `addon:SendMessage("BobleLoot_ImportResult", ok, message)` which is consumed by `UI/Toast.lua` (Batch 3E's toast system). If Toast is not yet loaded, fall back to `addon:Print()`.

#### Steps

- [ ] **8.1** At the top of `Core.lua` (module level, outside any function), add the StaticPopup definition:

  ```lua
  -- StaticPopup for /bl importpaste.
  -- Defined at module level so it is registered once during addon load.
  StaticPopupDialogs["BOBLELOOT_IMPORT_PASTE"] = {
      text = "Paste BobleLoot export JSON below:",
      button1 = "Import",
      button2 = "Cancel",
      hasEditBox = true,
      editBoxWidth = 500,
      maxLetters = 0,           -- no limit; JSON bundles can be large
      OnAccept = function(self)
          -- Implementation wired in BobleLoot:DoImportPaste() below.
          local text = self.editBox:GetText()
          BobleLoot:DoImportPaste(text)
      end,
      OnCancel = function() end,
      timeout = 0,
      whileDead = true,
      hideOnEscape = true,
      preferredIndex = 3,
  }
  ```

  Note: `BobleLoot` is referenced by name here (the global `_G.BobleLoot` set in `Core.lua`). This is safe because `StaticPopupDialogs` are invoked at player interaction time, long after addon initialization.

- [ ] **8.2** Add `BobleLoot:DoImportPaste(text)` as a method on the addon object:

  ```lua
  function BobleLoot:DoImportPaste(text)
      local function fireResult(ok, msg)
          -- Route through 3E toast system if available; fall back to Print.
          if self.SendMessage then
              self:SendMessage("BobleLoot_ImportResult", ok, msg)
          end
          self:Print((ok and "|cff00ff00" or "|cffff5555") .. msg .. "|r")
      end

      text = text and text:trim() or ""
      if text == "" then
          fireResult(false, "Import failed: paste is empty.")
          return
      end

      -- Parse JSON.
      if not dkjson then
          fireResult(false, "Import failed: dkjson library not loaded.")
          return
      end
      local ok, bundle = pcall(dkjson.decode, text)
      if not ok or type(bundle) ~= "table" then
          fireResult(false, "Import failed: JSON parse error.")
          return
      end

      -- Schema validation.
      if bundle.schema ~= "bobleloot-export-v1" then
          fireResult(false, "Import failed: not a BobleLoot bundle (schema mismatch).")
          return
      end
      if type(bundle.characters) ~= "table" then
          fireResult(false, "Import failed: bundle missing 'characters' table.")
          return
      end

      local charCount = 0
      for _ in pairs(bundle.characters) do charCount = charCount + 1 end
      if charCount == 0 then
          fireResult(false, "Imported bundle has 0 characters — check the export.")
          return
      end

      -- Build a data table in the same shape Sync.lua and Scoring.lua expect.
      -- The bundle's `characters` map already matches BobleLoot_Data.characters.
      local data = {
          characters  = bundle.characters,
          generatedAt = bundle.generatedAt or bundle.exportedAt or "imported",
          teamUrl     = bundle.teamUrl,
          simCap      = bundle.scoringConfig and bundle.scoringConfig.simCap or 5.0,
          mplusCap    = bundle.scoringConfig and bundle.scoringConfig.mplusCap or 40,
          historyCap  = bundle.scoringConfig and bundle.scoringConfig.historyCap or 5,
          _imported   = true,   -- flag so diagnostics can distinguish imported data
      }

      -- Load into the live globals and SyncDB.
      _G.BobleLoot_Data = data
      _G.BobleLootSyncDB = _G.BobleLootSyncDB or {}
      _G.BobleLootSyncDB.data = data

      -- Re-apply loot history against the new dataset.
      if ns.LootHistory and ns.LootHistory.Apply then
          C_Timer.After(0.5, function() ns.LootHistory:Apply(self) end)
      end

      -- Broadcast to the raid (Batch 1C contract: BroadcastNow -> SendHello).
      if ns.Sync and ns.Sync.BroadcastNow then
          ns.Sync:BroadcastNow(self)
          fireResult(true, string.format(
              "Imported %d characters from bundle. Broadcasting to raid...", charCount))
      else
          fireResult(true, string.format(
              "Imported %d characters from bundle (sync not available).", charCount))
      end
  end
  ```

- [ ] **8.3** Add the `importpaste` branch to `BobleLoot:OnSlashCommand`:

  ```lua
  elseif input == "importpaste" or input == "import" then
      if not UnitIsGroupLeader("player") then
          self:Print("Only the raid/group leader should import a dataset.")
          -- Allow anyway; the user may be testing solo.
      end
      StaticPopup_Show("BOBLELOOT_IMPORT_PASTE")
  ```

  Note: `/bl import <path>` (filesystem) is not supported (see WoW API research section). If the user types `/bl import something`, it still opens the paste dialog and ignores the path argument; the help string clarifies this.

- [ ] **8.4** Verify (solo, no group required):

  ```
  /bl importpaste
  ```

  Expected: A dialog box appears with a multi-line edit box and Import/Cancel buttons.

  Paste a minimal valid bundle JSON:
  ```json
  {"schema":"bobleloot-export-v1","exportedAt":"2026-04-23T00:00:00Z","generatedAt":"2026-04-23T00:00:00Z","scoringConfig":{"simCap":5.0,"mplusCap":40,"historyCap":5,"weights":{"sim":0.40,"bis":0.20,"history":0.15,"attendance":0.15,"mplus":0.10}},"characters":{"TestChar-Draenor":{"attendance":0.9,"mplusDungeons":20,"bis":[],"sims":{}}}}
  ```

  Click Import. Expected: print line "Imported 1 characters from bundle. Broadcasting to raid..." (or the sync-not-available variant if solo). `/dump BobleLoot_Data.characters` should show `TestChar-Draenor`.

- [ ] **8.5** Test error states:

  Open `/bl importpaste` again. Leave the box empty and click Import. Expected: error print "Import failed: paste is empty."

  Open `/bl importpaste`. Type `{"bad":"json"}` and click Import. Expected: error print "Import failed: not a BobleLoot bundle (schema mismatch)."

- [ ] **8.6** Commit:

  ```
  git add Core.lua
  git commit -m "Add /bl importpaste command with StaticPopup paste-box and JSON import (roadmap 4.3)"
  ```

---

### Task 9 — `UI/SettingsPanel.lua` additions

**Files:** `UI/SettingsPanel.lua`

Two additions to the existing settings panel (from Batch 1E's UI overhaul):
1. A "Synthetic history weight" slider in the Tuning tab.
2. An "Import dataset from JSON" button in the Data tab that triggers the paste dialog.

These are UI-side additions coordinated with the data-side contract above. The data side (this plan) defines the profile key (`synthWeight`) and the slash command (`importpaste`). The UI side exposes them as panel controls.

If `UI/SettingsPanel.lua` does not exist yet (Batch 1E not shipped), skip this task and add a `-- TODO: add synthWeight slider and import button once 1E ships` comment in Core.lua. Document the skip.

#### Steps

- [ ] **9.1** Open `UI/SettingsPanel.lua`. Locate `BuildTuningTab` (the function that builds the Tuning tab sliders). After the last existing weight slider (likely the `vault` slider from Batch 2A), add a separator and the synthetic weight slider:

  ```lua
  -- Synthetic history weight (catalyst / tier-token entries). Roadmap 4.2.
  local synthLabel = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  synthLabel:SetPoint("TOPLEFT", lastSlider, "BOTTOMLEFT", 0, -16)
  synthLabel:SetText("Synth (Catalyst/Token) Weight")

  local synthSlider = CreateFrame("Slider", "BobleLootSynthWeightSlider", tab, "OptionsSliderTemplate")
  synthSlider:SetPoint("TOPLEFT", synthLabel, "BOTTOMLEFT", 0, -8)
  synthSlider:SetMinMaxValues(0, 2.0)
  synthSlider:SetValueStep(0.05)
  synthSlider:SetObeyStepOnDrag(true)
  synthSlider:SetValue(addon.db.profile.synthWeight or 0.75)
  _G[synthSlider:GetName() .. "Low"]:SetText("0")
  _G[synthSlider:GetName() .. "High"]:SetText("2.0")
  _G[synthSlider:GetName() .. "Text"]:SetText(
      string.format("%.2f", addon.db.profile.synthWeight or 0.75))
  synthSlider:SetScript("OnValueChanged", function(s, val)
      addon.db.profile.synthWeight = val
      _G[s:GetName() .. "Text"]:SetText(string.format("%.2f", val))
  end)
  ```

  Adjust the anchor (`lastSlider`) to point to whatever the actual last slider variable is named in the existing Tuning tab implementation.

- [ ] **9.2** Locate `BuildDataTab` (the Data tab builder). Add an "Import dataset" button after any existing data-tab controls:

  ```lua
  -- Import dataset from JSON bundle. Roadmap 4.3.
  local importBtn = CreateFrame("Button", nil, tab, "UIPanelButtonTemplate")
  importBtn:SetSize(180, 26)
  importBtn:SetPoint("TOPLEFT", lastControl, "BOTTOMLEFT", 0, -16)
  importBtn:SetText("Import Dataset (Paste JSON)")
  importBtn:SetScript("OnClick", function()
      StaticPopup_Show("BOBLELOOT_IMPORT_PASTE")
  end)

  -- Tooltip explaining the workflow.
  importBtn:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine("Import Dataset from JSON", 1, 1, 1)
      GameTooltip:AddLine(
          "Opens a paste box. Run wowaudit.py --export bundle.json on any machine,\n" ..
          "copy the file contents, and paste here. No API key required.",
          0.8, 0.8, 0.8, true)
      GameTooltip:Show()
  end)
  importBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  ```

- [ ] **9.3** Verify the settings panel opens and shows both the new slider and the import button:

  ```
  /bl config
  ```

  Navigate to the Tuning tab — "Synth (Catalyst/Token) Weight" slider visible.
  Navigate to the Data tab — "Import Dataset (Paste JSON)" button visible and clickable.

- [ ] **9.4** Commit:

  ```
  git add UI/SettingsPanel.lua
  git commit -m "Add synthWeight slider and Import Dataset button to SettingsPanel (roadmap 4.2/4.3)"
  ```

---

### Task 10 — Toast event wiring for import result

**Files:** `UI/Toast.lua` (Batch 3E), `Core.lua`

This task is **conditional**: it only applies if Batch 3E's `UI/Toast.lua` has shipped. If it has not, `DoImportPaste` already falls back to `addon:Print()` — no work needed. This task adds the Toast listener.

#### Steps

- [ ] **10.1** Open `UI/Toast.lua`. In `Toast:Setup(addonArg)`, register the `BobleLoot_ImportResult` AceEvent:

  ```lua
  addonArg:RegisterMessage("BobleLoot_ImportResult", function(_, ok, msg)
      Toast:Show(msg, ok and "success" or "error")
  end)
  ```

  The event signature is `(event_name, ok, message)` where `ok` is a boolean and `message` is a human-readable string.

- [ ] **10.2** Verify:

  ```
  /bl importpaste
  ```

  Paste valid JSON and confirm. Expected: a green toast appears at the top-centre of the screen with the success message (not just a chat print).

  Paste empty text. Expected: a red toast with "Import failed: paste is empty."

- [ ] **10.3** Commit:

  ```
  git add UI/Toast.lua
  git commit -m "Wire BobleLoot_ImportResult into Toast:Show for import feedback (roadmap 4.3 / 3E)"
  ```

---

### Task 11 — Final integration commit and diagnostic pass

**Files:** `Core.lua` — version bump and final help-string audit.

#### Steps

- [ ] **11.1** In `Core.lua`, update `BobleLoot.version` to reflect the v2.0 milestone:

  ```lua
  BobleLoot.version = "2.0.0"
  ```

  (Coordinate with the release manager; if v2.0 is not yet imminent, use `"2.0.0-dev"` to distinguish the development build.)

- [ ] **11.2** Run the full pytest suite to confirm no regressions:

  ```bash
  python -m pytest tools/ -v
  ```

  Expected: all tests pass including the new `TestExportBundle` class.

- [ ] **11.3** In-game smoke test: load the addon, open `/bl config`, navigate to both the Tuning and Data tabs. Run `/bl synthhistory`. Confirm no Lua errors in the system log.

- [ ] **11.4** Commit:

  ```
  git add Core.lua
  git commit -m "Version bump to 2.0.0-dev after 4.2/4.3 catalyst tracking and export/import (roadmap Batch 4B)"
  ```

---

## Manual Verification Checklist

Complete all items in order before marking Batch 4B as shipped.

### Catalyst conversion detection (4.2)

| # | Step | Expected |
|---|---|---|
| C1 | `/reload`; `/run print(ns.CatalystTracker ~= nil)` | `true` |
| C2 | `/dump BobleLootDB.profile.synthHistory` | Empty table `{}` on first load |
| C3 | `/dump BobleLootDB.profile.synthWeight` | `0.75` |
| C4 | Navigate to the Catalyst station; use a catalyst charge on an item | `NEW_ITEM_ADDED` fires; addon prints "Synthetic loot recorded: YourName-Realm item via catalyst" |
| C5 | `/bl synthhistory` | Shows 1 entry with `synthType=catalyst` |
| C6 | `/bl lootdb` | Output shows `Synthetic history entries: 1` |
| C7 | Open the voting frame for any item | The character's history component includes the catalyst entry in the weighted total |

### Tier-token exchange detection (4.2)

| # | Step | Expected |
|---|---|---|
| T1 | Visit the tier-token vendor with a tier token in bags | `MERCHANT_SHOW` fires; `_vendorOpen = true` |
| T2 | Exchange the token for a tier piece | `NEW_ITEM_ADDED` fires; addon detects tier set item; prints "Synthetic loot recorded: YourName-Realm [item] via tierttoken" |
| T3 | `/bl synthhistory` | Shows a `tierttoken` entry |
| T4 | Leave the vendor | `MERCHANT_CLOSED` fires; `_vendorOpen = false`; no false positives on subsequent bag changes |

### Export bundle (4.3)

| # | Step | Expected |
|---|---|---|
| E1 | `python tools/wowaudit.py --wowaudit sample --bis bis.json --export /tmp/bundle.json` | Exits cleanly; prints "Exported bundle to /tmp/bundle.json: N characters." |
| E2 | `cat /tmp/bundle.json \| python -m json.tool` | Valid JSON; `schema` is `"bobleloot-export-v1"`; `characters` is a dict; no API key present |
| E3 | `python -m pytest tools/ -v` | All TestExportBundle tests pass |

### Import paste (4.3)

| # | Step | Expected |
|---|---|---|
| I1 | `/bl importpaste` | StaticPopup dialog appears with multi-line edit box |
| I2 | Click Import with empty box | Error: "Import failed: paste is empty." (chat print + toast if 3E shipped) |
| I3 | Paste `{"bad":"json","schema":"wrong"}` and click Import | Error: "Import failed: not a BobleLoot bundle (schema mismatch)." |
| I4 | Paste valid 1-character bundle JSON and click Import | Success: "Imported 1 characters from bundle. Broadcasting to raid..." |
| I5 | `/dump BobleLoot_Data.characters` | Shows the imported character(s) |
| I6 | `/dump BobleLoot_Data._imported` | `true` (distinguishes from file-loaded data) |
| I7 | `/dump BobleLootSyncDB.data.generatedAt` | Matches `generatedAt` from the pasted bundle |
| I8 | In a raid group: import on leader's client | Peers receive HELLO and request DATA; peers' BobleLoot_Data updates |
| I9 | Settings panel Data tab | "Import Dataset (Paste JSON)" button visible and functional |
| I10 | Settings panel Tuning tab | "Synth (Catalyst/Token) Weight" slider visible at 0.75 default |

---

## WoW API Verification TODOs

The following items must be confirmed in-game by the executor. Each is marked with the task that depends on the finding. If a TODO resolves to "API does not exist or behaves differently," document the workaround and update the task accordingly.

| # | API / Event | Question | Task |
|---|---|---|---|
| V1 | `NEW_ITEM_ADDED` | Does this event fire when a catalyst-converted item is delivered to bags? Fire args: `(bagID, slotID)` — confirm this signature. | Task 2 |
| V2 | `C_ItemInteraction.IsReady()` | Is this the correct API name to detect when the Catalyst UI frame is open? Or is it `C_ItemInteraction.IsAtInteractionDistance()`? Check with `/run print(C_ItemInteraction and type(C_ItemInteraction.IsReady))`. | Task 2 |
| V3 | `C_Item.GetItemSetInfo(itemID)` | Does this API exist and return non-nil for tier set pieces? Check with a known tier item ID. `/run local info = C_Item.GetItemSetInfo(212459); print(type(info))` (212459 = Amirdrassil Druid tier helm). | Task 2 |
| V4 | `BAG_NEW_ITEMS_UPDATED` | Does this event exist in WoW 10.2+? If yes, is it more reliable than `NEW_ITEM_ADDED` for detecting new bag arrivals? `/run print(C_EventUtils and C_EventUtils.GetEventInfo and C_EventUtils.GetEventInfo("BAG_NEW_ITEMS_UPDATED"))`. | Task 2 (fallback) |
| V5 | `ITEM_PUSH` | Does this event fire for catalyst item delivery? Would it be a better signal than `NEW_ITEM_ADDED`? | Task 2 (fallback) |
| V6 | Catalyst item tooltip flag | Does a catalyst-converted item retain any tooltip flag or item meta-data identifying it as a catalyst product (e.g., `TOOLTIP_TYPE_CATALYST`)? Check via `C_TooltipInfo.GetBagItem(0, 1)` immediately after catalyst delivery. | Task 2 (enhancement) |
| V7 | `dkjson.lua` WoW Lua 5.1 compat | Confirm `dkjson.lua` 2.5+ loads under WoW's Lua 5.1 with `dkjson.use_lpeg = false`. Run `/run print(dkjson.version)` after adding to TOC. | Task 7 |
| V8 | StaticPopup multi-line edit box | Confirm `hasEditBox = true` with `maxLetters = 0` produces an edit box large enough for a typical export bundle (2-5 KB of JSON). If not, investigate `hasWideEditBox` or custom AceGUI frame. | Task 8 |
| V9 | `MERCHANT_SHOW` / `MERCHANT_CLOSED` | Confirm these events fire reliably at vendor interaction open/close. Some vendor frames use `GOSSIP_SHOW` instead. | Task 2 |

---

## Coordination Notes

### 2A vault detection overlap

Batch 2A (plan `2026-04-23-batch-2a-scoring-maturity-plan.md`) uses `WEEKLY_REWARDS_ITEM_GRABBED` to populate `profile.vaultEntries` (category: `vault`, weight: `0.5x`). Batch 4B uses `NEW_ITEM_ADDED` + heuristics to populate `profile.synthHistory` (categories: `catalyst`/`tierttoken`, weight: `0.75x`).

The two tables are merged independently inside `LH:CountItemsReceived`. The merge call in `LH:Apply` passes `profile.synthHistory` as the `synthEntries` parameter introduced in Task 3. Separately, the 2A vault merge (via `extraEntries` in the 2A plan's Task 9.3) remains unchanged. The executor must confirm both merges coexist in `CountItemsReceivedAsync` without double-counting. They do not conflict: they operate on different source tables and different character keys (vault entries are only for the local player; synth entries are also only for the local player; RC entries span all raid members).

**4.2 does NOT supersede 2A.** 2A handles Great Vault (weekly free selection). 4.2 handles Catalyst (currency-purchased upgrade) and tier tokens (vendor exchange). These are three distinct acquisition paths with distinct "luck" levels:
- Great Vault: 0.5x (free, weekly, narrowly targeted — least lucky as a loot surprise)
- Catalyst/tier-token: 0.75x (costs currency or requires a token, but is still player-directed rather than RNG boss drop)
- Normal RC boss drop: 1.0x (full loot RNG)

### 3E toast contract

Batch 3E defines `UI/Toast.lua` with the AceEvent listener pattern. This plan defines one new event:

```
"BobleLoot_ImportResult"  args: (ok: boolean, message: string)
```

The toast level maps as: `ok=true` → `"success"` (green); `ok=false` → `"error"` (red). There is no `"warning"` level for import results — a partial import is either success (with a warning message embedded in the string) or failure.

If Batch 3E has not shipped when this plan is executed, `DoImportPaste` uses `addon:Print()` as fallback. The `SendMessage` call in `DoImportPaste` is guarded with `if self.SendMessage then` so it is a no-op on older builds.

### 4A Python pipeline maturity

Batch 4A (separate scope, not yet planned at time of writing) covers Python pipeline maturity. The `--export` flag added in Task 5 of this plan is **additive** to `wowaudit.py`'s existing `main()` flow and does not conflict with any 4A scope. The `export_bundle()` function is a pure data-transformation function with no side effects; 4A can extend or call it without modification.

The export bundle schema (`bobleloot-export-v1`) is defined in this plan. If 4A needs to extend the schema (e.g., adding `scoreOverrides` from item 4.7), the schema version should be bumped to `bobleloot-export-v2` in the 4A plan, and the import code in `DoImportPaste` should be updated to accept both versions.

### 4E empty/error states

Batch 4E (item 4.12) performs a full audit of empty and error states across all UI surfaces. The import paste dialog introduces these states:

| State | Trigger | Designed response |
|---|---|---|
| Empty paste | User clicks Import with blank edit box | Error toast/print: "Import failed: paste is empty." Edit box remains open. |
| JSON parse error | Paste is not valid JSON | Error toast/print: "Import failed: JSON parse error." |
| Schema mismatch | Valid JSON but wrong `schema` field | Error toast/print: "Import failed: not a BobleLoot bundle (schema mismatch)." |
| Zero characters | Valid bundle but `characters` is empty | Warning toast/print: "Imported bundle has 0 characters — check the export." Dialog closes (not an error — the import succeeded technically). |
| Success | Valid bundle with N > 0 characters | Success toast/print: "Imported N characters from bundle. Broadcasting to raid..." Dialog closes. |
| Sync unavailable | `ns.Sync` is nil (solo, no group) | Success print with "(sync not available)" suffix. Not a failure. |

Batch 4E must reference this table and verify that each state is covered. The executor of 4E should not change the error message strings without updating the pytest tests in `TestExportBundle` and the manual checklist in this plan.

### 4C RC version-compat

Batch 4C (item 4.8) is unrelated to 4B. No coordination needed. The catalyst tracker does not read from `RCLootCouncilLootDB`.

### 4D UI polish

Batch 4D (item 4.11, colorblind palette) is unrelated to 4B. The synthetic weight slider and import button in `UI/SettingsPanel.lua` should use whatever palette `ns.Theme` provides at that time. If 4D ships after 4B, the slider and button colors will be updated automatically if they use `ns.Theme` APIs rather than hard-coded color values.
