# Batch 1D — Score Cell Rendering and Tooltip Redesign

**Date:** 2026-04-22
**Target version:** 1.1.0
**Status:** Ready for implementation
**Plan series:** Batch 1, plan 4 of 5 (1A–1E)

---

## Goal

Overhaul the Score column cell rendering and both tooltip surfaces
(council-side in `VotingFrame.lua`, player-side in `LootFrame.lua`) to
distinguish missing-from-dataset from confirmed-zero, replace the hard-coded
colour thresholds with a raid-median-anchored gradient, add a dataset-age
freshness badge on the column header, and give the tooltip a scannable
four-column component layout with raid context in the footer.

---

## Architecture

Three concerns, three seams:

1. **`COMPONENT_ORDER` — single shared constant.** Currently duplicated
   between `VotingFrame.lua` (explicit ordered array, line 121) and
   `LootFrame.lua` (implicit via unordered `pairs()`, line 129). The constant
   moves to `Scoring.lua` as a module-level export. Both UI files consume
   `ns.Scoring.COMPONENT_ORDER`. This is the seam that fixes the ordering bug
   and enforces principle 8 ("one source of truth per concern").

2. **Colour mapping — `ns.Theme`.** All score-to-colour logic migrates to
   `Theme.ScoreColor(score)` (absolute, for the transparency label) and a new
   `Theme.ScoreColorRelative(score, median, max)` (session-anchored, for the
   voting frame). Both live in `UI/Theme.lua`, which is owned by plan 1E.
   Plan 1D calls them; plan 1E implements them.

3. **Tooltip builder — shared local function.** A new `buildComponentTooltip`
   function in `VotingFrame.lua` produces the four-column breakdown. `LootFrame.lua`
   gets its own equivalent (`buildPlayerTooltip`) that reuses the same
   per-component row format but omits the raid-context footer. Code is not
   literally shared across files (no new module) to avoid a cross-file
   dependency on a non-`ns` local; the two implementations are kept parallel
   and identically structured.

---

## Tech stack

- Lua 5.1 (WoW addon environment)
- `GameTooltip:AddDoubleLine` / `AddLine` for tooltip layout
- `ns.Scoring.COMPONENT_ORDER` — new export from `Scoring.lua`
- `ns.Theme.ScoreColor(score)` — owned by plan 1E
- `ns.Theme.ScoreColorRelative(score, median, max)` — new helper, owned by plan 1E
- `ns.Theme.muted`, `ns.Theme.warning`, `ns.Theme.danger` — colour constants, owned by plan 1E
- No new saved variables, no new config surface area

---

## Roadmap items covered

### Item 1.6 — `[UI]` Score cell: missing-vs-zero + raid-anchored gradient + freshness

> Today the score cell shows `0` or a blank for both "not in dataset" and
> "has data, genuine zero." These are opposite council situations.
>
> - `—` in muted grey for missing-from-dataset with tooltip:
>   `"<Name> is not in the BobleLoot dataset. Run tools/wowaudit.py
>   and /reload."`
> - `0` in the normal numeric style for confirmed-zero with tooltip
>   showing which components contributed zero.
> - Replace the hard 40/70 red/yellow/green threshold with a gradient
>   anchored to the current session's median and max — a score two
>   points below median reads differently from a score of 18.
> - Add a small corner badge when `_G.BobleLoot_Data.generatedAt` is
>   older than 72 hours (yellow) or older than 7 days (red).

### Item 1.7 — `[UI]` Tooltip hierarchy overhaul

> The current tooltip is dense but lacks scannable hierarchy. Target
> the Details! / BigWigs readability bar.
>
> - Bold title, separator, then a four-column row per component:
>   `[label] [raw stat, muted] [weight%] [normalized 0-1, blue] [= pts, white]`
> - Footer block with raid context: `Median 61 | Max 88 | This: 74`
> - Caveat line when renormalization is meaningful (2+ components
>   excluded): `"Score over [active weight sum]% of data"`
> - Both `VotingFrame.lua` and `LootFrame.lua` iterate a shared
>   `COMPONENT_ORDER` constant (fixes the quiet `pairs()` ordering bug
>   in `LootFrame.lua:attachLabel`).

---

## Dependency: Theme module (plan 1E)

**Plan 1D cannot ship without plan 1E's `UI/Theme.lua` being in place.**

Every colour reference in this plan calls into `ns.Theme`:

| Symbol used in 1D | Source |
|---|---|
| `ns.Theme.muted` | 1E constant — rgba array `{0.53, 0.53, 0.53, 1}` |
| `ns.Theme.warning` | 1E constant — rgba array `{1, 0.82, 0, 1}` |
| `ns.Theme.danger` | 1E constant — rgba array `{1, 0.31, 0.31, 1}` |
| `ns.Theme.success` | 1E constant — rgba array `{0.25, 1, 0.25, 1}` |
| `ns.Theme.white` | 1E constant — rgba array `{1, 1, 1, 1}` |
| `ns.Theme.ScoreColor(score)` | 1E helper — returns one of the above based on 40/70 absolute thresholds |
| `ns.Theme.ScoreColorRelative(score, median, max)` | New helper added to 1E's `Theme.lua` per Task 5 below |

**Release rule:** either (a) 1E merges first and 1D follows, or (b) both
plans land in the same release train commit. Do not merge 1D alone — the
`ns.Theme` nil reference will cause a Lua error on every score column render.

`Theme.ScoreColorRelative` is a new function not described in the 1E spec
because the spec was written before 1D was scoped. It must be added to
`UI/Theme.lua` as part of Task 5 of this plan. The function signature and
body are specified in Task 5. Co-ordinate with the 1E implementor before
merging.

---

## File structure

| File | Change type | Summary |
|---|---|---|
| `Scoring.lua` | Add export | Expose `COMPONENT_ORDER` and `COMPONENT_LABEL` as `ns.Scoring.COMPONENT_ORDER` / `ns.Scoring.COMPONENT_LABEL` at module level |
| `VotingFrame.lua` | Refactor + feature | Remove local `COMPONENT_ORDER`/`COMPONENT_LABEL`; consume from `ns.Scoring`. Rewrite `formatScore` for missing/zero/gradient. Compute session median/max per render pass. Add freshness badge. Rewrite `fillScoreTooltip` with four-column layout and raid-context footer. |
| `LootFrame.lua` | Refactor + feature | Rewrite `attachLabel`'s inline tooltip block to iterate `ns.Scoring.COMPONENT_ORDER`. Rewrite component rows to match four-column format. Add missing-from-dataset tooltip path. |
| `UI/Theme.lua` | Add helper | Add `Theme.ScoreColorRelative(score, median, max)` — coordinated with plan 1E implementor |

**Files explicitly not touched:** `Config.lua`, `UI/SettingsPanel.lua`,
`Sync.lua`, `Core.lua`, `LootHistory.lua`, `RaidReminder.lua`,
`TestRunner.lua`, any file under `tools/`.

---

## Task 1 — Export `COMPONENT_ORDER` from `Scoring.lua`

**Goal:** establish the single source of truth for component ordering.
No behavioural change — pure refactor seam.

**Files:**
- `E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/Scoring.lua`
  — lines 73–76 (the "Public" section preamble, just before `Scoring:Compute`)
- `E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/VotingFrame.lua`
  — lines 121–128 (local `COMPONENT_ORDER` and `COMPONENT_LABEL` declarations)

**Steps:**

- [ ] 1.1 In `Scoring.lua`, insert the following block immediately before the
  `-- Public` comment (after `mplusComponent`, before `Scoring:Compute`):

  ```lua
  -- Ordered list of component keys for UI iteration. Both VotingFrame.lua
  -- and LootFrame.lua consume this so ordering is always consistent.
  ns.Scoring.COMPONENT_ORDER = { "sim", "bis", "history", "attendance", "mplus" }

  -- Human-readable label for each component key.
  ns.Scoring.COMPONENT_LABEL = {
      sim        = "Sim upgrade",
      bis        = "BiS",
      history    = "Loot received",
      attendance = "Attendance",
      mplus      = "M+ dungeons",
  }
  ```

- [ ] 1.2 In `VotingFrame.lua`, delete the local `COMPONENT_ORDER` and
  `COMPONENT_LABEL` declarations at lines 121–128:

  ```lua
  -- DELETE these two local declarations:
  local COMPONENT_ORDER = { "sim", "bis", "history", "attendance", "mplus" }
  local COMPONENT_LABEL = {
      sim        = "Sim upgrade",
      bis        = "BiS",
      history    = "Loot received",
      attendance = "Attendance",
      mplus      = "M+ dungeons",
  }
  ```

- [ ] 1.3 In `VotingFrame.lua`, add a file-top alias immediately after the
  `local SCORE_COL = "blScore"` line (line 17) so the rest of the file uses
  short locals without reaching into `ns.Scoring` on every call:

  ```lua
  -- Resolved after Scoring.lua loads; both modules are in the same TOC frame.
  local function getComponentOrder() return ns.Scoring.COMPONENT_ORDER end
  local function getComponentLabel() return ns.Scoring.COMPONENT_LABEL end
  ```

- [ ] 1.4 In `VotingFrame.lua`, update every reference to `COMPONENT_ORDER`
  in `fillScoreTooltip` (lines 195 and 214) and `formatRaw` (no direct
  reference there, it receives `key` as argument) to call `getComponentOrder()`.
  Since this task makes no other behavioural change, a simple find-and-replace
  of the two `ipairs(COMPONENT_ORDER)` occurrences with
  `ipairs(getComponentOrder())` and one `COMPONENT_LABEL[key]` with
  `getComponentLabel()[key]` is sufficient.

  Verify there are no remaining bare references to the deleted locals.

- [ ] 1.5 In-game verification: `/reload`, open a test session via
  `ns.TestRunner:Run(ns.addon, 3, true)`, hover a score cell, confirm the
  tooltip still renders components in the expected order (sim, bis, history,
  attendance, mplus). No Lua errors in chat.

- [ ] 1.6 Commit:
  `git commit -m "refactor: export COMPONENT_ORDER from Scoring.lua as shared constant"`

---

## Task 2 — Fix `LootFrame.lua:attachLabel` ordering (UI debt #2)

**Goal:** replace `pairs(ctx.breakdown)` with ordered iteration over
`ns.Scoring.COMPONENT_ORDER` in the transparency-mode tooltip.

**Files:**
- `E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/LootFrame.lua`
  — lines 117–138 (`attachLabel`'s `OnEnter` hook)

**Current code at lines 128–136:**

```lua
        if ctx.breakdown then
            GameTooltip:AddLine(" ")
            for k, v in pairs(ctx.breakdown) do
                GameTooltip:AddDoubleLine(
                    k,
                    string.format("%.2f x %.0f%%", v.value,
                        (v.effectiveWeight or v.weight) * 100),
                    0.9, 0.9, 0.9, 1, 1, 1)
            end
        end
```

**Steps:**

- [ ] 2.1 Replace the `pairs(ctx.breakdown)` block with an ordered loop.
  The replacement is a drop-in; component label lookup now uses
  `ns.Scoring.COMPONENT_LABEL`:

  ```lua
          if ctx.breakdown then
              GameTooltip:AddLine(" ")
              local order = ns.Scoring.COMPONENT_ORDER
              local labels = ns.Scoring.COMPONENT_LABEL
              for _, key in ipairs(order) do
                  local v = ctx.breakdown[key]
                  if v then
                      GameTooltip:AddDoubleLine(
                          labels[key] or key,
                          string.format("%.2f x %.0f%%", v.value,
                              (v.effectiveWeight or v.weight) * 100),
                          0.9, 0.9, 0.9, 1, 1, 1)
                  end
              end
          end
  ```

- [ ] 2.2 In-game verification: as a player (not leader), hover the
  transparency score label on multiple consecutive items. Confirm that
  the component order is identical on every hover: sim / bis / history /
  attendance / mplus. Before this change the order was random across hovers;
  after it should be stable.

- [ ] 2.3 Commit:
  `git commit -m "fix: iterate COMPONENT_ORDER in LootFrame tooltip (fixes pairs() ordering bug)"`

---

## Task 3 — `isInDataset` helper + `—` for missing characters

**Goal:** display `—` in `Theme.muted` when a candidate has no entry in
`_G.BobleLoot_Data.characters`. Distinguish this case from a computed score
of zero.

**Files:**
- `E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/VotingFrame.lua`
  — lines 109–118 (`formatScore` function) and lines 231–274 (`doCellUpdate`)

**Steps:**

- [ ] 3.1 Add a module-level helper function in `VotingFrame.lua` just before
  `formatScore` (after `formatRaw`, before `fillScoreTooltip`):

  ```lua
  -- Returns true when `name` has an entry in the current dataset.
  local function isInDataset(addon, name)
      local data = addon:GetData()
      if not data or not data.characters then return false end
      return data.characters[name] ~= nil
  end
  ```

- [ ] 3.2 The current `formatScore` at lines 109–118:

  ```lua
  local function formatScore(score)
      if not score then return "|cff666666-|r" end
      local color
      if score >= 70 then     color = "|cff40ff40"
      elseif score >= 40 then color = "|cffffd040"
      else                    color = "|cffff5050"
      end
      return string.format("%s%d|r", color, math.floor(score + 0.5))
  end
  ```

  Change the signature to accept the addon reference and candidate name so
  it can distinguish missing from scored. Replace the function body:

  ```lua
  -- score    : number | nil   (nil = Scoring:Compute returned nil)
  -- inDataset: bool           (true = character row exists in dataset)
  -- median   : number | nil   (session median across all scored candidates)
  -- max      : number | nil   (session maximum across all scored candidates)
  local function formatScore(score, inDataset, median, max)
      if not inDataset then
          -- Character is not in the dataset at all.
          local m = ns.Theme and ns.Theme.muted or {0.53, 0.53, 0.53, 1}
          return string.format("|cff%02x%02x%02x\xe2\x80\x94|r",
              math.floor(m[1]*255), math.floor(m[2]*255), math.floor(m[3]*255))
      end
      if not score then
          -- In dataset but Scoring:Compute returned nil (sim-weight=0 and
          -- no other data, or literally all components missing).
          return "|cff666666?|r"
      end
      -- score is a real number (including 0.0).
      local c = (ns.Theme and ns.Theme.ScoreColorRelative)
                and ns.Theme.ScoreColorRelative(score, median, max)
                or  (ns.Theme and ns.Theme.ScoreColor and ns.Theme.ScoreColor(score))
      if c then
          return string.format("|cff%02x%02x%02x%d|r",
              math.floor(c[1]*255), math.floor(c[2]*255), math.floor(c[3]*255),
              math.floor(score + 0.5))
      end
      -- Fallback if Theme not yet loaded (should not happen in practice).
      local hex
      if score >= 70 then     hex = "40ff40"
      elseif score >= 40 then hex = "ffd040"
      else                    hex = "ff5050"
      end
      return string.format("|cff%s%d|r", hex, math.floor(score + 0.5))
  end
  ```

  Note: `\xe2\x80\x94` is the UTF-8 encoding of the em dash `—`. WoW's
  font renderer handles UTF-8; this avoids a literal non-ASCII byte in the
  source file.

- [ ] 3.3 Update the `doCellUpdate` call site (currently line 250) to pass
  the new arguments. The session median/max will be computed in Task 5; for
  now pass `nil, nil` as placeholders — the function's fallback branch handles
  them:

  ```lua
  local inDs = isInDataset(addon, name)
  cellFrame.text:SetText(formatScore(score, inDs, nil, nil))
  ```

  Also update the score-to-text call inside the transparency broadcast loop
  (lines 257–263) — that loop only cares about the numeric score, not the
  formatted string, so it is unaffected.

- [ ] 3.4 Update `fillScoreTooltip` (currently lines 177–229) to guard
  the missing-from-dataset case at the top:

  ```lua
  local function fillScoreTooltip(tt, addon, itemID, name, simRef, histRef,
                                   sessionMedian, sessionMax)
      local inDs = isInDataset(addon, name)
      if not inDs then
          tt:AddLine("|cffddddddBoble Loot|r")
          tt:AddLine(" ")
          tt:AddLine(string.format(
              "|cffaaaaaa%s is not in the BobleLoot dataset.|r", name or "?"))
          tt:AddLine("|cff888888Run tools/wowaudit.py and /reload.|r")
          return
      end
      -- ... rest of tooltip (rewritten in Task 7) ...
  end
  ```

  The rest of `fillScoreTooltip` is rewritten in Task 7; for now leave the
  existing body after the guard.

- [ ] 3.5 In-game verification: using `TestRunner.lua`, set up a scenario
  where one candidate name does not appear in `_G.BobleLoot_Data.characters`
  (easiest: rename a character key in the dataset temporarily, or use `/bl debugchar`
  with a fake name). Hover that candidate's score cell and confirm:
  - Cell shows `—` in a muted grey colour.
  - Tooltip shows the explanatory text, not a component breakdown.
  - Other candidates in the same session still show numeric scores.

- [ ] 3.6 Commit:
  `git commit -m "feat: show em-dash for candidates missing from dataset (1.6)"`

---

## Task 4 — Confirmed-zero display

**Goal:** when a candidate is in the dataset but `Scoring:Compute` returns
`0` (all active components evaluated to zero), display `0` in normal numeric
style rather than the `—` used for missing candidates. The tooltip breakdown
still renders so the council can see why.

**Files:**
- `E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/VotingFrame.lua`
  — `formatScore` (updated in Task 3)

**Steps:**

- [ ] 4.1 Confirm that the `formatScore` function written in Task 3 already
  handles this correctly: when `inDataset = true` and `score = 0`, the
  function enters the `c = ScoreColorRelative(0, median, max)` branch and
  renders `0` in colour. The confirmed-zero case is therefore already covered
  by the Task 3 rewrite — this task is a verification and documentation
  checkpoint only.

- [ ] 4.2 Confirm that `Scoring:Compute` can actually return `(0, breakdown)`
  rather than `nil`. Reading `Scoring.lua` lines 116–141: if `totalWeight > 0`
  and all `c.value` are `0`, then `weighted = 0` and `score = 0 / totalWeight * 100 = 0`.
  The function returns `(0, breakdown)` in this case. The breakdown will
  contain entries for each component that had `value = 0` and `weight > 0`.
  This is distinct from the `totalWeight <= 0` path that returns `nil`.

- [ ] 4.3 In `TestRunner.lua`, add a comment block documenting how to exercise
  the zero-score case manually. No code change needed — this is a testing note:

  Insert this comment near the `FALLBACK_ITEMS` block (after line 36):

  ```lua
  -- To exercise the confirmed-zero score case:
  --   1. In _G.BobleLoot_Data.characters, find any character entry.
  --   2. Set char.sims = {} (empty, so simComponent returns nil).
  --   3. Set char.bis = {} (not on BiS list -> partialBiSValue, e.g. 0.25).
  --   4. Set char.itemsReceived = 999 (so historyComponent returns ~0).
  --   5. Set char.attendance = 0, char.mplusDungeons = 0.
  --   6. Run a test session; that character should show "0" not "-".
  -- If weights.sim > 0 Scoring returns nil (excluded), so set weights.sim = 0
  -- in db.profile.weights when testing this path.
  ```

- [ ] 4.4 In-game verification: manufacture the conditions from the comment
  above in a live session (or via the TestRunner's dataset manipulation).
  Confirm the score cell shows `0` in a coloured style (likely danger/red
  since 0 is below median), and hovering shows a breakdown with components
  listing zero values rather than the missing-dataset message.

- [ ] 4.5 Commit:
  `git commit -m "docs: document confirmed-zero score test path in TestRunner.lua"`

---

## Task 5 — Session median/max computation + `Theme.ScoreColorRelative`

**Goal:** replace the hard 40/70 threshold in `formatScore` with a gradient
anchored to the current voting session's median and max across all scored
candidates.

**Files:**
- `E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/VotingFrame.lua`
  — `doCellUpdate` (lines 231–273) and `sortFn` (lines 275–290)
- `E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/UI/Theme.lua`
  — add `ScoreColorRelative` helper (coordinate with 1E implementor)

**Steps:**

- [ ] 5.1 Add `Theme.ScoreColorRelative` to `UI/Theme.lua`. This function
  must be added by the 1E implementor as part of their `Theme.lua` deliverable.
  The specification for the function is:

  ```lua
  -- Returns an rgba array {r, g, b, 1} for `score` relative to the current
  -- session's `median` and `max`. Falls back to absolute ScoreColor when
  -- median/max are nil.
  --
  -- Gradient logic:
  --   score >= max                      -> success (green)
  --   score >= median                   -> lerp from warning to success
  --   score >= median * 0.5             -> lerp from danger to warning
  --   score < median * 0.5              -> danger (red)
  --
  -- When median == max (all candidates tied) or either is nil, fall through
  -- to Theme.ScoreColor(score).
  function ns.Theme.ScoreColorRelative(score, median, max)
      if not median or not max or median == max then
          return ns.Theme.ScoreColor(score)
      end
      local function lerp(a, b, t)
          t = math.max(0, math.min(1, t))
          return {
              a[1] + (b[1]-a[1])*t,
              a[2] + (b[2]-a[2])*t,
              a[3] + (b[3]-a[3])*t,
              1,
          }
      end
      local s = ns.Theme.success
      local w = ns.Theme.warning
      local d = ns.Theme.danger
      if score >= max then
          return s
      elseif score >= median then
          local t = (score - median) / (max - median)
          return lerp(w, s, t)
      elseif score >= median * 0.5 then
          local t = (score - median * 0.5) / (median * 0.5)
          return lerp(d, w, t)
      else
          return d
      end
  end
  ```

- [ ] 5.2 Add a module-level cache table and a helper function in
  `VotingFrame.lua` to compute session scores for all current candidates.
  Insert this after the `isInDataset` function added in Task 3:

  ```lua
  -- Per-render-pass cache for session median and max. Recomputed whenever
  -- doCellUpdate is called for row 1 (the first row triggers the full pass).
  -- Keyed by session number so stale data from a previous item is evicted.
  local _sessionStats = {}   -- { session = N, median = X, max = Y }

  local function computeSessionStats(rcVoting, addon, session, tableData)
      -- Return cached value if same session.
      if _sessionStats.session == session
         and _sessionStats.median ~= nil then
          return _sessionStats.median, _sessionStats.max
      end

      local itemID  = getItemIDForSession(rcVoting, session)
      local names   = bidderNames(rcVoting, session, tableData)
      local simRef  = simReferenceFor(addon, itemID, names)
      local histRef = historyReferenceFor(addon, names)

      local scores = {}
      local data = addon:GetData()
      if data and data.characters and names then
          for _, n in ipairs(names) do
              local s = computeScoreForRow(rcVoting, addon, session, n, simRef, histRef)
              if s then scores[#scores + 1] = s end
          end
      end

      local median, max
      if #scores > 0 then
          table.sort(scores)
          max = scores[#scores]
          local mid = math.floor(#scores / 2)
          if #scores % 2 == 1 then
              median = scores[mid + 1]
          else
              median = (scores[mid] + scores[mid + 1]) / 2
          end
      end

      _sessionStats = { session = session, median = median, max = max }
      return median, max
  end
  ```

- [ ] 5.3 Update `doCellUpdate` to compute and pass median/max. Replace the
  existing call (installed in Task 3 step 3.3):

  ```lua
  -- Before (Task 3 placeholder):
  local inDs = isInDataset(addon, name)
  cellFrame.text:SetText(formatScore(score, inDs, nil, nil))
  ```

  With:

  ```lua
  local inDs           = isInDataset(addon, name)
  local median, max    = computeSessionStats(rcVoting, addon, session, data)
  cellFrame.text:SetText(formatScore(score, inDs, median, max))
  ```

  Also update the `fillScoreTooltip` call inside the `OnEnter` script
  (currently line 269) to pass the session stats:

  ```lua
  cellFrame:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      local med, mx = computeSessionStats(rcVoting, addon, session, data)
      fillScoreTooltip(GameTooltip, addon, itemID, name, simRef, histRef, med, mx)
      GameTooltip:Show()
  end)
  ```

- [ ] 5.4 Evict the session cache on session change. At the top of
  `doCellUpdate`, after the `local session = ...` line, add:

  ```lua
  -- Evict stats cache when the session number changes.
  if _sessionStats.session ~= session then
      _sessionStats = {}
  end
  ```

- [ ] 5.5 In-game verification: run a test session with 5+ candidates,
  all of whom are in the dataset. Observe that score colours are distributed
  relative to the group — the top scorer is green, those near median are
  yellow, those well below median are red — regardless of absolute values.
  Compare two scenarios: one where all scores cluster around 60, one where
  they spread from 20 to 90. In both cases the top scorer should be green.

- [ ] 5.6 Commit:
  `git commit -m "feat: raid-anchored score colour gradient via Theme.ScoreColorRelative (1.6)"`

---

## Task 6 — Freshness badge on the Score column header

**Goal:** add a small visual indicator to the Score column header in the
voting frame when `_G.BobleLoot_Data.generatedAt` is older than 72 hours
(warning yellow) or 7 days (danger red). Hovering the badge shows an
explanatory tooltip.

**Files:**
- `E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/VotingFrame.lua`
  — `VF:Hook` function (lines 292–355)

**Design decision:** `generatedAt` is stored as a human-readable string
(e.g. `"2026-04-20 14:32:00"`). We compare against the WoW client time
`time()` (Unix epoch). The data file must also store a Unix timestamp for
the freshness check to work without a date parser. Looking at the codebase,
`generatedAt` is the string written by `wowaudit.py`. Since the Python tool
owns the data file (and plan 1E does not change this), we need a companion
field. The plan will read `_G.BobleLoot_Data.generatedAtTimestamp` — a Unix
epoch integer written by `wowaudit.py`. If the field is absent, the badge
is suppressed (do not show a false-positive warning for older data files).
This is a note for the data-side implementor: `wowaudit.py` must emit
`generatedAtTimestamp = os.time.time_int()` alongside `generatedAt`. No
config surface area is added for the badge thresholds.

**Steps:**

- [ ] 6.1 Add a helper function in `VotingFrame.lua` after `computeSessionStats`:

  ```lua
  local FRESHNESS_WARN_SECS  = 72 * 3600   -- 72 hours
  local FRESHNESS_DANGER_SECS = 7 * 24 * 3600  -- 7 days

  -- Returns nil (fresh), "warning", or "danger" based on dataset age.
  local function datasetFreshnessState()
      local d = _G.BobleLoot_Data
      if not d or not d.generatedAtTimestamp then return nil end
      local age = time() - d.generatedAtTimestamp
      if age >= FRESHNESS_DANGER_SECS then return "danger" end
      if age >= FRESHNESS_WARN_SECS   then return "warning" end
      return nil
  end

  -- Format age in a human-readable string: "3 days 4 hours" etc.
  local function formatAge(secs)
      local days  = math.floor(secs / 86400)
      local hours = math.floor((secs % 86400) / 3600)
      if days > 0 then
          return string.format("%d day%s %d hour%s",
              days,  days  == 1 and "" or "s",
              hours, hours == 1 and "" or "s")
      end
      return string.format("%d hour%s", hours, hours == 1 and "" or "s")
  end
  ```

- [ ] 6.2 In `VF:Hook`, after the frame-widening block (after line 345),
  add the badge creation and refresh logic:

  ```lua
  -- Freshness badge on the Score column header.
  -- We find the header row of the lib-st table and attach a FontString
  -- to the cell that corresponds to our SCORE_COL column.
  local function refreshFreshnessBadge()
      local state = datasetFreshnessState()
      local badge = VF._freshnessBadge
      if not badge then return end

      if not state then
          badge:SetText("")
          badge:SetScript("OnEnter", nil)
          badge:SetScript("OnLeave", nil)
          return
      end

      local t  = ns.Theme
      local c  = (state == "danger") and (t and t.danger or {1, 0.31, 0.31, 1})
                                      or  (t and t.warning or {1, 0.82, 0, 1})
      badge:SetText(string.format("|cff%02x%02x%02x!|r",
          math.floor(c[1]*255), math.floor(c[2]*255), math.floor(c[3]*255)))

      badge:SetScript("OnEnter", function(self)
          local d   = _G.BobleLoot_Data
          local age = d and d.generatedAtTimestamp
                      and formatAge(time() - d.generatedAtTimestamp)
                      or  "unknown time"
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          GameTooltip:AddLine("Boble Loot — dataset age")
          GameTooltip:AddLine(string.format(
              "Dataset generated %s ago.", age), 1, 1, 1)
          GameTooltip:AddLine(
              "Run tools/wowaudit.py to refresh.", 0.7, 0.7, 0.7)
          GameTooltip:Show()
      end)
      badge:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end

  -- Attach badge FontString to the st header frame if accessible.
  -- lib-st exposes the header row as st.header; each cell is st.header.cols[i].
  local st = rcVoting.frame and rcVoting.frame.st
  if st and st.header then
      -- Find which column index is ours.
      local colIdx
      for i, col in ipairs(rcVoting.scrollCols) do
          if col.colName == SCORE_COL then colIdx = i; break end
      end
      if colIdx and st.header.cols and st.header.cols[colIdx] then
          local headerCell = st.header.cols[colIdx]
          local badge = headerCell:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
          badge:SetPoint("TOPRIGHT", headerCell, "TOPRIGHT", 0, 0)
          badge:SetText("")
          VF._freshnessBadge = badge
          refreshFreshnessBadge()
      end
  end

  -- Store refreshFreshnessBadge so it can be called after data reloads.
  VF.refreshFreshnessBadge = refreshFreshnessBadge
  ```

- [ ] 6.3 In-game verification: test three states.
  - Fresh data (0 hours old): badge is absent. Hover the Score header:
    no BobleLoot tooltip appears (the header's default RC tooltip, if any,
    is unchanged).
  - Simulate 72h+ old data: set `_G.BobleLoot_Data.generatedAtTimestamp = time() - 80*3600`
    in the chat via `/run _G.BobleLoot_Data.generatedAtTimestamp = time() - 80*3600`
    then call `ns.VotingFrame.refreshFreshnessBadge()`. Badge appears yellow
    with `!`. Hover shows `"Dataset generated 80 hours 0 minutes ago."`.
  - Simulate 7d+ old: `time() - 8*24*3600`. Badge turns red.

- [ ] 6.4 Commit:
  `git commit -m "feat: freshness badge on Score column header with 72h/7d thresholds (1.6)"`

---

## Task 7 — Redesign council tooltip (`VotingFrame.lua`)

**Goal:** replace `fillScoreTooltip` with a four-column component layout,
raid-context footer, and conditional renormalization caveat.

**Files:**
- `E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/VotingFrame.lua`
  — lines 177–229 (`fillScoreTooltip`)

**Layout target per the spec:**

```
Boble Loot                                  (bold title line)
────────────────────────────────────────    (separator)
Playername                    74.0 / 100    (name + total, gold)
                                            (blank line)
Sim upgrade   3.21% upg     30%  0.64   =  19.2   (component row)
BiS           on BiS list   25%  1.00   =  25.0
Loot received 2.1 items     20%  0.58   =  11.6
Attendance    87.0% raids   15%  0.87   =  13.1
M+ dungeons   28 dungeons   10%  0.70   =   7.0
                                            (blank line)
Excluded (no data): Sim upgrade             (only if 2+ excluded)
Score over 70% of weights                   (renorm caveat, conditional)
                                            (blank line)
Median 61 | Max 88 | This: 74              (raid context footer)
```

The spec says the row format is `[label] [raw stat, muted] [weight%] [normalized 0-1, blue] [= pts, white]`. `GameTooltip:AddDoubleLine` renders a left string and a right string; we fit the five logical columns into two halves with careful spacing.

Left half: `label  (raw stat, muted)`
Right half: `weight%  norm  =  pts`

**Steps:**

- [ ] 7.1 Replace `fillScoreTooltip` in its entirety with the following:

  ```lua
  local function fillScoreTooltip(tt, addon, itemID, name, simRef, histRef,
                                   sessionMedian, sessionMax)
      local inDs = isInDataset(addon, name)
      if not inDs then
          tt:AddLine("|cffddddddBoble Loot|r")
          tt:AddLine(" ")
          tt:AddLine(string.format(
              "|cffaaaaaa%s is not in the BobleLoot dataset.|r", name or "?"))
          tt:AddLine("|cff888888Run tools/wowaudit.py and /reload.|r")
          return
      end

      local s, breakdown = addon:GetScore(itemID, name, {
          simReference     = simRef,
          historyReference = histRef,
      })

      -- Title + separator
      tt:AddLine("|cffddddddBoble Loot|r")
      tt:AddLine("|cff444444" .. string.rep("\xe2\x80\x94", 26) .. "|r")

      -- Name + total score
      tt:AddDoubleLine(
          name or "?",
          s and string.format("%.1f / 100", s) or "|cffff7070no data|r",
          1, 0.82, 0,   1, 1, 1)

      if not s then
          tt:AddLine("|cffff7070No scoreable components for this candidate/item.|r")
          return
      end

      tt:AddLine(" ")

      -- Column header row (muted)
      tt:AddDoubleLine(
          "|cff666666Component           (raw stat)|r",
          "|cff666666wt%    norm   =  pts|r",
          1, 1, 1,  1, 1, 1)

      local sumContrib   = 0
      local activeCount  = 0
      local totalConfigW = 0
      local order  = ns.Scoring.COMPONENT_ORDER
      local labels = ns.Scoring.COMPONENT_LABEL
      local weights = addon.db and addon.db.profile and addon.db.profile.weights or {}

      for _, key in ipairs(order) do
          totalConfigW = totalConfigW + (weights[key] or 0)
      end

      for _, key in ipairs(order) do
          local e = breakdown[key]
          if e then
              activeCount  = activeCount + 1
              sumContrib   = sumContrib + (e.contribution or 0)
              local rawStr = formatRaw(key, e)
              local left   = string.format("%s |cff666666(%s)|r",
                                 labels[key] or key, rawStr)
              local right  = string.format(
                  "|cffcccccc%2.0f%%|r  |cff6699ff%.2f|r  |cff888888=|r  |cffffffff%4.1f|r",
                  (e.effectiveWeight or 0) * 100,
                  e.value or 0,
                  e.contribution or 0)
              tt:AddDoubleLine(left, right, 0.9, 0.9, 0.9, 1, 1, 1)
          end
      end

      -- Excluded components
      local excluded = {}
      for _, key in ipairs(order) do
          if not breakdown[key] then
              table.insert(excluded, labels[key] or key)
          end
      end

      tt:AddLine(" ")

      -- Renormalization caveat: show only when 2+ components are excluded.
      if #excluded >= 2 then
          tt:AddLine("|cff808080Excluded (no data): "
              .. table.concat(excluded, ", ") .. "|r")
          -- activeWeightSum = sum of configured weights for active components
          local activeWeightSum = 0
          for _, key in ipairs(order) do
              if breakdown[key] then
                  activeWeightSum = activeWeightSum + (weights[key] or 0)
              end
          end
          if totalConfigW > 0 and activeWeightSum < totalConfigW then
              local pct = math.floor(activeWeightSum / totalConfigW * 100 + 0.5)
              tt:AddLine(string.format(
                  "|cff808080Score over %d%% of configured weights.|r", pct))
          end
      elseif #excluded == 1 then
          -- One excluded: mention it but no caveat line.
          tt:AddLine("|cff666666Excluded (no data): "
              .. table.concat(excluded, ", ") .. "|r")
      end

      -- Raid context footer
      if sessionMedian or sessionMax then
          tt:AddLine(" ")
          local parts = {}
          if sessionMedian then
              table.insert(parts,
                  string.format("Median |cffffffff%d|r", math.floor(sessionMedian + 0.5)))
          end
          if sessionMax then
              table.insert(parts,
                  string.format("Max |cffffffff%d|r", math.floor(sessionMax + 0.5)))
          end
          if s then
              table.insert(parts,
                  string.format("This: |cffffffff%d|r", math.floor(s + 0.5)))
          end
          tt:AddLine("|cffaaaaaa" .. table.concat(parts, " | ") .. "|r")
      end
  end
  ```

- [ ] 7.2 In `doCellUpdate`'s `OnEnter` script, confirm the
  `fillScoreTooltip` call already passes `med, mx` from Task 5 step 5.3.
  No additional change needed here.

- [ ] 7.3 In-game verification: hover a scored candidate with 4 active
  components and 1 excluded (e.g. sim excluded). Confirm:
  - Title line renders.
  - Separator line (em-dashes) renders below the title.
  - Name + total on one line.
  - Four component rows in order: bis / history / attendance / mplus.
  - One excluded line (no caveat since only 1 excluded).
  - Raid context footer: `Median X | Max Y | This: Z`.
  - Now configure 2 components disabled. Confirm caveat line appears.

- [ ] 7.4 Commit:
  `git commit -m "feat: four-column tooltip with raid context footer (1.7)"`

---

## Task 8 — Redesign transparency tooltip (`LootFrame.lua`)

**Goal:** apply the same four-column component layout to the player-side
transparency tooltip in `LootFrame.lua`. Omit the raid-context footer
(player sees only their own score; median/max are leader-side data).

**Files:**
- `E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/LootFrame.lua`
  — lines 117–139 (`attachLabel`'s `OnEnter` hook)

**Steps:**

- [ ] 8.1 Replace the `OnEnter` inline script in `attachLabel` with the
  new layout. The current code (lines 117–139) becomes:

  ```lua
      entryFrame:HookScript("OnEnter", function(self)
          local ctx = self[SCORE_FRAME_KEY .. "_ctx"]
          if not ctx or not ctx.score then return end
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")

          -- Title + separator
          GameTooltip:AddLine("|cffddddddBoble Loot — your score|r")
          GameTooltip:AddLine(
              "|cff444444" .. string.rep("\xe2\x80\x94", 26) .. "|r")

          -- Score line
          GameTooltip:AddDoubleLine("Score",
              string.format("%.1f / 100", ctx.score),
              1, 0.82, 0,  1, 1, 1)

          if ctx.fromLeader then
              GameTooltip:AddLine(
                  "|cff80c0ffSent by raid leader (authoritative).|r")
          end

          -- Component breakdown
          if ctx.breakdown then
              GameTooltip:AddLine(" ")
              -- Column header (muted)
              GameTooltip:AddDoubleLine(
                  "|cff666666Component           (raw stat)|r",
                  "|cff666666wt%    norm   =  pts|r",
                  1, 1, 1,  1, 1, 1)

              local order  = ns.Scoring.COMPONENT_ORDER
              local labels = ns.Scoring.COMPONENT_LABEL
              local weights = ns.addon and ns.addon.db
                              and ns.addon.db.profile
                              and ns.addon.db.profile.weights or {}
              local totalConfigW = 0
              for _, key in ipairs(order) do
                  totalConfigW = totalConfigW + (weights[key] or 0)
              end

              local excluded = {}
              for _, key in ipairs(order) do
                  local v = ctx.breakdown[key]
                  if v then
                      local rawStr
                      -- Use VotingFrame's formatRaw if accessible, else fallback.
                      -- LootFrame is in the same addon namespace, so we delegate
                      -- to a shared helper exposed on ns.VotingFrame.
                      rawStr = ns.VotingFrame and ns.VotingFrame.formatRaw
                               and ns.VotingFrame.formatRaw(key, v)
                               or  string.format("%.2f", v.value or 0)
                      local left  = string.format("%s |cff666666(%s)|r",
                                        labels[key] or key, rawStr)
                      local right = string.format(
                          "|cffcccccc%2.0f%%|r  |cff6699ff%.2f|r  |cff888888=|r  |cffffffff%4.1f|r",
                          (v.effectiveWeight or 0) * 100,
                          v.value or 0,
                          v.contribution or 0)
                      GameTooltip:AddDoubleLine(left, right, 0.9, 0.9, 0.9, 1, 1, 1)
                  else
                      table.insert(excluded, labels[key] or key)
                  end
              end

              -- Renormalization caveat (2+ excluded)
              if #excluded >= 2 then
                  GameTooltip:AddLine(" ")
                  GameTooltip:AddLine("|cff808080Excluded: "
                      .. table.concat(excluded, ", ") .. "|r")
                  local activeW = 0
                  for _, key in ipairs(order) do
                      if ctx.breakdown[key] then
                          activeW = activeW + (weights[key] or 0)
                      end
                  end
                  if totalConfigW > 0 and activeW < totalConfigW then
                      local pct = math.floor(activeW / totalConfigW * 100 + 0.5)
                      GameTooltip:AddLine(string.format(
                          "|cff808080Score over %d%% of configured weights.|r", pct))
                  end
              elseif #excluded == 1 then
                  GameTooltip:AddLine(" ")
                  GameTooltip:AddLine("|cff666666Excluded: "
                      .. table.concat(excluded, ", ") .. "|r")
              end
          end

          GameTooltip:Show()
      end)
  ```

- [ ] 8.2 Expose `formatRaw` on `ns.VotingFrame` so `LootFrame.lua` can
  delegate to it without duplicating the logic. In `VotingFrame.lua`, after
  the local `formatRaw` function definition (currently lines 131–175), add:

  ```lua
  -- Expose for LootFrame.lua's transparency tooltip.
  VF.formatRaw = formatRaw
  ```

- [ ] 8.3 In-game verification: as a raid member (transparency enabled by
  leader), hover the "Your score" label on the loot frame. Confirm:
  - Title and separator render.
  - Score line shows the numeric value.
  - "Sent by raid leader" line appears when the score came via sync.
  - Component rows appear in the canonical order with four-column layout.
  - No raid-context footer (only the council sees median/max).

- [ ] 8.4 Commit:
  `git commit -m "feat: four-column transparency tooltip in LootFrame (1.7)"`

---

## Task 9 — Dataset-missing handling in the transparency tooltip

**Goal:** when the player themselves is not in the dataset, show the
explanatory message in the transparency tooltip rather than leaving it blank
or showing a confusing empty breakdown.

**Files:**
- `E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/LootFrame.lua`
  — `renderEntry` function (lines 144–192) and `attachLabel`'s `OnEnter`
  hook (modified in Task 8)

**Steps:**

- [ ] 9.1 In `renderEntry`, the current early-return at lines 157–162 fires
  when `lookupChar(data)` returns nil — meaning no dataset entry was found
  for the local player. When this happens the label text is cleared and
  `_ctx` is set to nil, so the `OnEnter` hook in `attachLabel` does nothing
  (guard `if not ctx or not ctx.score then return end` fires).

  We want the explanatory tooltip to appear even when the player is not in
  the dataset. Store a flag in the context:

  ```lua
  -- After the lookupChar check at line 155, replace:
  --   if not key or not iid then
  --       fs:SetText("")
  --       entryFrame[SCORE_FRAME_KEY .. "_ctx"] = nil
  --       return
  --   end

  -- With:
  if not iid then
      fs:SetText("")
      entryFrame[SCORE_FRAME_KEY .. "_ctx"] = nil
      return
  end
  if not key then
      -- Player is not in dataset. Show muted label + explanatory tooltip.
      local m = ns.Theme and ns.Theme.muted or {0.53, 0.53, 0.53, 1}
      fs:SetText(string.format("|cff%02x%02x%02xBL: \xe2\x80\x94|r",
          math.floor(m[1]*255), math.floor(m[2]*255), math.floor(m[3]*255)))
      entryFrame[SCORE_FRAME_KEY .. "_ctx"] = { notInDataset = true }
      return
  end
  ```

- [ ] 9.2 Update the `OnEnter` hook in `attachLabel` to handle the
  `notInDataset` flag. At the top of the hook (before the `not ctx or not ctx.score`
  guard), add:

  ```lua
          local ctx = self[SCORE_FRAME_KEY .. "_ctx"]
          if not ctx then return end
          if ctx.notInDataset then
              local playerName = UnitName("player") or "?"
              GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
              GameTooltip:AddLine("|cffddddddBoble Loot|r")
              GameTooltip:AddLine(" ")
              GameTooltip:AddLine(string.format(
                  "|cffaaaaaa%s is not in the BobleLoot dataset.|r", playerName))
              GameTooltip:AddLine(
                  "|cff888888Run tools/wowaudit.py and /reload.|r")
              GameTooltip:Show()
              return
          end
          if not ctx.score then return end
          -- ... rest of tooltip ...
  ```

- [ ] 9.3 In-game verification: temporarily remove the local player's name
  from the dataset (`/run _G.BobleLoot_Data.characters["YourName-Realm"] = nil`)
  and trigger a loot frame render (either a real item or a test session).
  Confirm:
  - The score label shows `BL: —` in muted grey instead of a numeric score.
  - Hovering shows the explanatory missing-dataset message with the player's
    own name.
  - Reloading the UI (which restores the dataset from disk) returns to normal
    numeric display.

- [ ] 9.4 Commit:
  `git commit -m "feat: missing-dataset state in transparency label and tooltip (1.6)"`

---

## Task 10 — Manual verification pass

**Goal:** confirm all new states work together in a live or near-live
environment before marking the plan complete.

**Files:** read-only pass — no code changes in this task.

**Steps:**

- [ ] 10.1 **Council-side (leader perspective):** open a test session via
  `ns.TestRunner:Run(ns.addon, 5, true)`.
  - Confirm score cells show colours distributed relative to session median
    (not absolute 40/70 thresholds).
  - Confirm at least one candidate shows `—` if possible (add a fake name
    to RC's candidate list that is not in the dataset).
  - Hover each score cell; confirm the four-column tooltip renders with
    correct component order, muted raw stat, blue normalized value, white
    contribution points, and raid-context footer.
  - Confirm the renormalization caveat appears when 2+ components are
    excluded.

- [ ] 10.2 **Transparency-side (raider perspective):** in a party with a
  leader who has transparency enabled, open the loot frame.
  - Confirm the score label shows the numeric value in a relative colour.
  - Hover and confirm the four-column breakdown without a raid-context footer.
  - Confirm "Sent by raid leader (authoritative)." appears when the score
    was synced.

- [ ] 10.3 **Not-in-dataset character (council-side):** use
  `/run _G.BobleLoot_Data.characters["Fake-Realm"] = nil` (if the name was
  previously in the dataset) or do a fresh test session where one candidate
  name is fabricated. Confirm `—` in muted grey, and the explanatory tooltip.

- [ ] 10.4 **Not-in-dataset player (transparency-side):** remove own name
  from dataset as in Task 9 step 9.3. Confirm `BL: —` label and explanatory
  tooltip.

- [ ] 10.5 **Freshness badge — three states:**
  - Fresh: `/run _G.BobleLoot_Data.generatedAtTimestamp = time() - 3600`
    then `ns.VotingFrame.refreshFreshnessBadge()`. Badge absent.
  - Warning: `/run _G.BobleLoot_Data.generatedAtTimestamp = time() - 80*3600`
    then refresh. Badge shows yellow `!`. Hover gives age message.
  - Danger: `/run _G.BobleLoot_Data.generatedAtTimestamp = time() - 9*24*3600`
    then refresh. Badge turns red.

- [ ] 10.6 **Confirmed-zero score:** manufacture a zero-score candidate as
  described in Task 4 step 4.3. Confirm cell shows `0` in a coloured style
  (not `—`), and tooltip shows a breakdown.

- [ ] 10.7 **Component ordering stability:** hover the transparency tooltip
  on three different items in rapid succession. Confirm component order is
  always sim / bis / history / attendance / mplus, never random.

- [ ] 10.8 **No Lua errors:** throughout all verification steps, keep the
  WoW error frame visible (`/console scriptErrors 1`). Zero new errors is
  the acceptance criterion.

---

## Dependency: Theme module (plan 1E)

Plan 1D calls the following symbols that plan 1E must deliver:

| Symbol | Usage in 1D |
|---|---|
| `ns.Theme.muted` | `formatScore` (em-dash colour), `LootFrame` missing label |
| `ns.Theme.warning` | Freshness badge 72h state |
| `ns.Theme.danger` | Freshness badge 7d state |
| `ns.Theme.success` | `ScoreColorRelative` lerp target |
| `ns.Theme.ScoreColor(score)` | Absolute fallback in `formatScore` |
| `ns.Theme.ScoreColorRelative(score, median, max)` | Session-anchored cell colour |

`Theme.ScoreColorRelative` is specified in Task 5 of this plan. It is a new
addition to 1E's deliverable — the 1E implementor must include it.

All colour references in 1D include a defensive fallback: if `ns.Theme` is
nil (e.g., Theme.lua not yet loaded), the old hard-coded hex values are used.
This means 1D degrades gracefully during development if 1E is not yet merged,
but the fallback must be removed before final release so that the palette is
truly centralised in one file.

---

## Manual verification checklist

The following states must all be confirmed before tagging v1.1:

**Score cell states**

- [ ] `—` muted for character not in `_G.BobleLoot_Data.characters`
- [ ] `0` in colour for confirmed-zero score (in dataset, all components zero)
- [ ] Numeric value in gradient colour for normal scores
- [ ] Top scorer in session is green regardless of absolute value
- [ ] Score near session median is yellow-ish
- [ ] Score well below median is red-ish
- [ ] Two different sessions with different score distributions show different
      colour distributions

**Freshness badge**

- [ ] Badge absent when data is < 72h old
- [ ] Badge yellow `!` when data is 72h–7d old
- [ ] Badge red `!` when data is > 7d old
- [ ] Badge hover tooltip shows human-readable age and refresh instruction
- [ ] Badge absent when `generatedAtTimestamp` field is missing (older data file)

**Council tooltip (`VotingFrame.lua`)**

- [ ] Title line renders in muted white
- [ ] Separator line (em-dashes) below title
- [ ] Name + total score on one line (gold name, white score)
- [ ] Column header row (muted)
- [ ] Per-component rows in order: sim / bis / history / attendance / mplus
- [ ] Each row: label (grey), raw stat (muted), weight% (muted), normalized [0–1] (blue), points (white)
- [ ] Missing component(s) listed in excluded line
- [ ] Renormalization caveat appears only when 2+ components excluded
- [ ] Caveat shows correct percentage of active weights
- [ ] Raid-context footer: `Median N | Max N | This: N`
- [ ] Missing-from-dataset candidate: shows explanatory tooltip only (no component rows)

**Transparency tooltip (`LootFrame.lua`)**

- [ ] Same four-column layout as council tooltip
- [ ] "Sent by raid leader (authoritative)." line when score was synced
- [ ] No raid-context footer (player sees only their own score)
- [ ] Renormalization caveat same logic as council tooltip
- [ ] Component order stable across multiple hovers
- [ ] Missing-from-dataset player: `BL: —` label + explanatory tooltip

**No regressions**

- [ ] Zero Lua errors in chat during any of the above scenarios
- [ ] Sort by Score column still works correctly (sortFn unchanged)
- [ ] Transparency mode on/off toggle still works
- [ ] TestRunner still starts a test session without errors

---

## Rollback

Each task ends with a single focused commit. Revert order (reverse of commit
order) is safe:

| Task | Commit message prefix | Revert impact |
|---|---|---|
| 1 | `refactor: export COMPONENT_ORDER` | `COMPONENT_ORDER` and `COMPONENT_LABEL` return to locals in VotingFrame; LootFrame reverts to `pairs()` ordering |
| 2 | `fix: iterate COMPONENT_ORDER in LootFrame` | Ordering bug returns but no crash |
| 3 | `feat: show em-dash for missing dataset` | Missing candidates show old `-` style |
| 4 | `docs: document confirmed-zero test path` | Comment removed; no behaviour change |
| 5 | `feat: raid-anchored score colour gradient` | Colour reverts to absolute 40/70 threshold |
| 6 | `feat: freshness badge on Score column header` | Badge disappears; no crash |
| 7 | `feat: four-column tooltip VotingFrame` | Council tooltip reverts to old dense layout |
| 8 | `feat: four-column transparency tooltip` | Transparency tooltip reverts to old `pairs()` layout |
| 9 | `feat: missing-dataset transparency state` | Player not in dataset silently shows no label |

Each commit is independently revertible with `git revert <sha>` because the
changes are layered — later tasks depend on earlier ones only for the
`COMPONENT_ORDER` constant (Task 1), which is the most foundational and the
most trivial to re-inline if needed.
