# Batch 2E — Voting Frame + Transparency Nits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render a `~` conflict prefix on score cells when two candidates are within a configurable point threshold, and shorten the transparency label from `"Your score: 74"` to `"BL: 74"` with a per-character opt-out toggle.

**Architecture:** Both items piggyback on Batch 1D's existing per-render infrastructure — the conflict prefix computation extends `_sessionStats` in `VotingFrame.lua` rather than adding a second traversal, and the label change is a single `SetText` call in `LootFrame.lua:renderEntry`. Two new `DB_DEFAULTS.profile` keys (`conflictThreshold` and `suppressTransparencyLabel`) follow the exact AceDB pattern established by Batch 1E; the opt-out flag is profile-scoped (per-character) because suppressing a UI element is a local player preference that must not affect what the leader or other raiders see.

**Tech Stack:** Lua, AceDB (existing profile pattern)

**Roadmap items covered:**

> **2.10 `[UI]` Conflict indicator `~` prefix**
> When two candidates' scores are within a configurable threshold (default 5 points), prefix both with `~` in the column: `~74` / `~71`. Signals to the council that the score is not decisive and they should apply judgment. Threshold lives in the new Settings panel under a Display group.

> **2.11 `[UI]` Transparency-mode compact label + player-side opt-out**
> The current `"Your score: 74"` transparency label on the RC loot frame is verbose. Change to `"BL: 74"`; tooltip already explains the rest. Add a player-side opt-out (profile key, independent of leader toggle) so a player can always suppress the label on their own screen even when the leader enables transparency mode.

**Dependencies:** Batch 1D (voting frame per-render pass, `_sessionStats`, `formatScore`, LootFrame `attachLabel`/`renderEntry`), Batch 1E (SettingsPanel `BuildTuningTab`/`BuildDataTab`, `MakeSlider`/`MakeToggle` helpers, `DB_DEFAULTS` pattern, `SP:Refresh`).

---

## File Structure

Files modified (all on the `release/v1.1.0` branch — this plan targets the Batch 2 working branch that diverges from there):

```
VotingFrame.lua          — extend _sessionStats with conflict set; modify formatScore caller in doCellUpdate
LootFrame.lua            — change label format; honor suppressTransparencyLabel
UI/SettingsPanel.lua     — add "Display" section to BuildTuningTab; add opt-out toggle to BuildDataTab
Core.lua                 — add conflictThreshold = 5 and suppressTransparencyLabel = false to DB_DEFAULTS
```

No new files. No new tabs.

---

## Design decision: where does the "Display" group live?

The plan adds `conflictThreshold` under a **new "Display" section inside `BuildTuningTab`**, not as a new tab.

Rationale:
- The threshold is a rendering preference that the raid leader adjusts alongside partial-BiS credit and cap overrides — it belongs with the other scoring/display tuning knobs.
- A sixth tab would make the tab bar exceed the panel width at the current 560px panel width (each tab is `PANEL_W / #TAB_NAMES` wide). Adding a tab requires widening the panel, which is scope creep.
- The Tuning tab already has vertical scroll room: the deepest existing slider sits at `y = -220` inside the card inner frame, and the card is anchored bottom-right to the body. A new section card below it costs roughly 80px, which fits inside `BODY_H = 360` with the existing scroll frame.

`suppressTransparencyLabel` lives in **`BuildDataTab`** inside the existing Transparency card. That card already contains the leader-facing enable toggle; the player opt-out is a natural companion label directly below it, with hint text explaining that the opt-out is per-character and independent of the leader's global setting.

---

## Tasks

### Task 1 — `Core.lua`: add `DB_DEFAULTS` profile keys

**Files:** `Core.lua`

- [ ] 1. Open `Core.lua` on the working branch. Locate the `DB_DEFAULTS.profile` table.
- [ ] 2. Add `conflictThreshold = 5` immediately after the existing `historyCap = 5` line (thematically grouped with other numeric tuning values):

```lua
        conflictThreshold = 5,   -- 2.10: ~prefix when top-two gap <= this
```

- [ ] 3. Add `suppressTransparencyLabel = false` immediately after the `minimap` sub-table and before `panelPos` (grouped with other per-character display preferences):

```lua
        suppressTransparencyLabel = false,  -- 2.11: player hides BL label even when leader enables transparency
```

- [ ] 4. Verify the entire `DB_DEFAULTS` table has no duplicate keys and parses without error by searching for both new keys:
  - Grep `conflictThreshold` in `Core.lua` — exactly one hit.
  - Grep `suppressTransparencyLabel` in `Core.lua` — exactly one hit.

**Verification:** `/reload` in-game; `/bl config` opens the panel without Lua error. Both keys are accessible as `addon.db.profile.conflictThreshold` and `addon.db.profile.suppressTransparencyLabel`.

---

### Task 2 — `VotingFrame.lua`: extend `_sessionStats` with conflict set

**Files:** `VotingFrame.lua`

Context: `computeSessionStats` already computes a sorted `scores` list to derive `median` and `max`. The conflict detection needs to know, for any given candidate score `s`, whether there exists another candidate score within `threshold` points. The most efficient approach is to mark the full sorted list on the stats object and do a binary-proximity check in `doCellUpdate` — no second traversal.

- [ ] 1. In `computeSessionStats`, after `_sessionStats = { session = session, itemID = itemID, median = median, max = max }`, extend the stored table to also carry the sorted scores list and a per-name score map:

```lua
    -- Build a name->score map for O(1) lookup in doCellUpdate.
    local nameToScore = {}
    if data and names then
        local simRef2  = simReferenceFor(addon, itemID, names)
        local histRef2 = historyReferenceFor(addon, names)
        for _, n in ipairs(names) do
            local s = computeScoreForRow(rcVoting, addon, session, n, simRef2, histRef2)
            if s then nameToScore[n] = s end
        end
    end

    _sessionStats = {
        session     = session,
        itemID      = itemID,
        median      = median,
        max         = max,
        sortedScores = scores,       -- already sorted ascending
        nameToScore  = nameToScore,
    }
```

  Note: `simRef` and `histRef` are already computed in the same function scope; use the local variables directly rather than re-calling `simReferenceFor`/`historyReferenceFor`. The refactor looks like:

```lua
    -- (existing code that builds scores[] from names using simRef/histRef)
    -- ...after the existing loop that populates scores[]:

    local nameToScore = {}
    if names then
        for _, n in ipairs(names) do
            local s = computeScoreForRow(rcVoting, addon, session, n, simRef, histRef)
            if s then nameToScore[n] = s end
        end
    end

    _sessionStats = {
        session      = session,
        itemID       = itemID,
        median       = median,
        max          = max,
        sortedScores = scores,
        nameToScore  = nameToScore,
    }
```

  This reuses the already-computed scores from the existing loop — no second pass over names.

- [ ] 2. Add a module-level helper `isConflict(stats, score, threshold)` that returns `true` when any *other* score in `stats.sortedScores` is within `threshold` points of `score`:

```lua
-- Returns true when `score` is within `threshold` of any other score
-- in the sorted list. Uses a linear scan from the score's insertion
-- point — O(k) where k = number of candidates within threshold, which
-- is nearly always 0-2 in practice.
local function isConflict(stats, score, threshold)
    if not stats or not stats.sortedScores or #stats.sortedScores < 2 then
        return false
    end
    for _, s in ipairs(stats.sortedScores) do
        if s ~= score and math.abs(s - score) <= threshold then
            return true
        end
    end
    return false
end
```

  Note: The sorted list may contain duplicate scores (two players with identical computed scores). `s ~= score` uses numeric inequality, which correctly handles `score == s` for the *same* candidate (we do not want a candidate to conflict with itself). However, if two *different* candidates share the same numeric score, they will each detect the other as a conflict — which is correct: a tie is the most decisive form of conflict.

- [ ] 3. In `doCellUpdate`, after `local score, inDs, median, max = ...` are computed, add the conflict check and modify `cellFrame.text:SetText(...)`:

```lua
    -- 2.10: conflict prefix
    local threshold = (addon.db and addon.db.profile and addon.db.profile.conflictThreshold) or 5
    local stats     = _sessionStats
    local conflict  = score and isConflict(stats, score, threshold) or false

    cellFrame.text:SetText(formatScore(score, inDs, median, max, conflict))
```

- [ ] 4. Modify `formatScore` to accept and apply the `conflict` flag. The `~` prefix is rendered in `Theme.muted` color, prepended before the gradient-colored number. The signature becomes:

```lua
local function formatScore(score, inDataset, median, max, conflict)
```

  Inside the branch `if not score then ... end` and the final numeric branch, add the prefix:

```lua
    -- Inside the "score is a real number" branch, before return:
    local prefix = ""
    if conflict then
        local m = ns.Theme and ns.Theme.muted or {0.55, 0.55, 0.55, 1}
        prefix = string.format("|cff%02x%02x%02x~|r",
            math.floor(m[1]*255), math.floor(m[2]*255), math.floor(m[3]*255))
    end

    if c then
        return prefix .. string.format("|cff%02x%02x%02x%d|r",
            math.floor(c[1]*255), math.floor(c[2]*255), math.floor(c[3]*255),
            math.floor(score + 0.5))
    end
    -- Fallback path:
    return prefix .. string.format("|cff%s%d|r", hex, math.floor(score + 0.5))
```

  The existing call sites that pass only four arguments (`formatScore(score, inDs, median, max)`) are only in `doCellUpdate`. The function is module-local so no external callers exist. Update the one call site in step 3 to pass `conflict` as the fifth argument.

- [ ] 5. Verify cache eviction still works: the `_sessionStats` eviction guard at the top of `doCellUpdate` checks `_sessionStats.session ~= session or _sessionStats.itemID ~= itemID` and resets to `{}`. This evicts `nameToScore` and `sortedScores` correctly since `{}` has neither field.

**Verification (manual):** Run RC test session with 5 candidates whose scores span more than 5 points in most pairs but two are within 5. Confirm those two cells show `~74` / `~71` in muted-prefixed color while others render plain. Confirm the tooltip is unaffected (it calls `fillScoreTooltip` directly, not `formatScore`).

---

### Task 3 — `VotingFrame.lua`: threshold from profile, not hard-coded

**Files:** `VotingFrame.lua`

Task 2 step 3 already reads the threshold from `addon.db.profile.conflictThreshold`. This task verifies no magic constant remains and adds a nil-safety guard.

- [ ] 1. Confirm the `threshold` line in `doCellUpdate` uses a `or 5` default so a missing profile key (fresh install before DB init) does not break rendering.
- [ ] 2. Grep `VotingFrame.lua` for the literal `5` to ensure no leftover hard-coded uses exist outside the default.
- [ ] 3. Add a code comment above the threshold read explaining the profile key name and which Settings panel section exposes it, for future maintainers:

```lua
    -- conflictThreshold: set in Settings > Tuning > "Display" section (2.10).
    -- Default 5 points. Both candidates within threshold get the ~ prefix.
    local threshold = (addon.db and addon.db.profile and addon.db.profile.conflictThreshold) or 5
```

**Verification:** Change `conflictThreshold` to `10` in DB (via the slider added in Task 5), re-open the voting frame for the same candidates. More cells should acquire the prefix.

---

### Task 4 — `LootFrame.lua`: compact label + `suppressTransparencyLabel` opt-out

**Files:** `LootFrame.lua`

- [ ] 1. In `renderEntry`, locate the line:

```lua
    fs:SetText(string.format("%sYour score: %d|r", colorFor(score),
        math.floor(score + 0.5)))
```

  Replace it with:

```lua
    -- 2.11: compact label. Full breakdown remains in the hover tooltip.
    fs:SetText(string.format("%sBL: %d|r", colorFor(score),
        math.floor(score + 0.5)))
```

- [ ] 2. Add the opt-out guard immediately before the `fs:SetText` call (and before the `not-in-dataset` muted-label branch). The guard checks the local player's profile key; the leader's synced setting is already checked earlier in `renderEntry` via `addon:IsTransparencyEnabled()`. The opt-out is an additional local filter:

```lua
    -- 2.11: player-side opt-out. Checked after the transparency-enabled
    -- guard so we don't show a blank label when transparency is off —
    -- the outer guard already handles that. This guard only fires when
    -- transparency IS on but the local player has suppressed their label.
    if addon.db and addon.db.profile and addon.db.profile.suppressTransparencyLabel then
        fs:SetText("")
        entryFrame[SCORE_FRAME_KEY .. "_ctx"] = nil
        return
    end
```

  Placement: insert this block after the `if not addon:IsTransparencyEnabled() then ... return end` block but before the `lookupChar` / item-ID extraction. The early returns above this point already handle the "transparency disabled" case, so reaching this guard means transparency is on.

  The exact insertion point in the existing flow is:

```lua
    -- (existing) transparency-enabled check
    if not addon:IsTransparencyEnabled() then
        fs:SetText("")
        entryFrame[SCORE_FRAME_KEY .. "_ctx"] = nil
        return
    end

    -- NEW: player opt-out (2.11)
    if addon.db and addon.db.profile and addon.db.profile.suppressTransparencyLabel then
        fs:SetText("")
        entryFrame[SCORE_FRAME_KEY .. "_ctx"] = nil
        return
    end

    -- (existing) dataset/item lookup continues below
    local data = addon:GetData()
    ...
```

- [ ] 3. The "not in dataset" branch already renders `BL: —` (from Batch 1D). Verify it does not say `"Your score:"` anywhere. Grep `LootFrame.lua` for the string `"Your score"` — zero hits expected after this edit.

- [ ] 4. The hover tooltip title in `attachLabel`'s `OnEnter` hook reads `"Boble Loot — your score"`. This is tooltip text, not the label, and is deliberately more descriptive. Leave it unchanged per the roadmap spec ("tooltip continues to explain the rest").

- [ ] 5. Verify `LF:Refresh()` causes `renderEntry` to re-run for all visible entries, which re-evaluates `suppressTransparencyLabel` on each call to `renderEntry`. No additional refresh plumbing is needed since the hook already calls `refreshAll` → `renderEntry`.

**Verification (manual):**
- Transparency on, `suppressTransparencyLabel = false`: label reads `BL: 74` (not `Your score: 74`).
- Toggle `suppressTransparencyLabel = true`: label disappears immediately after next `LF:Refresh()` call (triggered by `SP:Refresh()` in the Settings panel OnShow, or on next RC loot frame update).
- Toggle back to `false`: label re-appears.
- Leader-side voting frame is unaffected — `renderEntry` is only called on the player's RC loot frame (RCLootFrame), not the council voting frame (RCVotingFrame).

---

### Task 5 — `UI/SettingsPanel.lua`: "Display" section in `BuildTuningTab`

**Files:** `UI/SettingsPanel.lua`

- [ ] 1. In `BuildTuningTab`, after the closing of the main `"Scoring tuning"` card (after `histCapSld` and the loot history window slider, which ends at `y = -220` inside the inner frame), add a second section card anchored below the first:

```lua
    -- ── Display section (2.10) ────────────────────────────────────────
    local dispCard, dispInner = MakeSection(body, "Display")
    dispCard:SetPoint("TOPLEFT",  card, "BOTTOMLEFT",  0, -8)
    dispCard:SetPoint("TOPRIGHT", card, "BOTTOMRIGHT", 0, -8)
    dispCard:SetHeight(70)
```

  The "Scoring tuning" card (`card`) already exists as a local; anchor `dispCard` to its bottom edge. Height 70px accommodates a single slider plus label.

- [ ] 2. Add the conflict threshold slider inside `dispInner`:

```lua
    local conflictSld = MakeSlider(dispInner, {
        label = "Conflict threshold (points)",
        min   = 0,
        max   = 20,
        step  = 1,
        isPercent = false,
        width = 280,
        x = 4, y = -4,
        get = function()
            return (addon and addon.db.profile.conflictThreshold) or 5
        end,
        set = function(v)
            if addon then
                addon.db.profile.conflictThreshold = math.floor(v)
            end
        end,
    })
```

  The `MakeSlider` helper already formats integer values with `"%.1f"` — since this is a whole-number slider (step = 1), values display as `"5.0"` etc. This is acceptable; if visual polish is desired the `valLbl` can be overridden:

```lua
    -- Override valLbl to show integer without decimal.
    conflictSld._valLbl:SetText(tostring(
        math.floor((addon and addon.db.profile.conflictThreshold) or 5)))
    conflictSld:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v + 0.5)
        if addon then addon.db.profile.conflictThreshold = v end
        conflictSld._valLbl:SetText(tostring(v))
    end)
```

  Note: `MakeSlider` sets its own `OnValueChanged` which calls `opts.set`. The script override above replaces it with one that also rounds and formats as integer. This is fine since `opts.set` is captured by the closure but we bypass it; the equivalent logic (`addon.db.profile.conflictThreshold = v`) is inlined.

- [ ] 3. Add a tooltip hint FontString below the slider explaining the `~` marker:

```lua
    local conflictHint = dispInner:CreateFontString(nil, "OVERLAY")
    conflictHint:SetFont(T.fontBody, T.sizeSmall)
    conflictHint:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
    conflictHint:SetPoint("TOPLEFT", conflictSld, "BOTTOMLEFT", 0, -4)
    conflictHint:SetWidth(480)
    conflictHint:SetText(
        "When two candidates' scores are within this many points, "
        .. "both cells show a ~ prefix. Set to 0 to disable.")
```

- [ ] 4. In the `BuildTuningTab` body's `OnShow` handler, add a line to refresh `conflictSld` when the panel is opened:

```lua
    body:SetScript("OnShow", function()
        if not addon then return end
        local oc = addon.db.profile.overrideCaps
        if simCapSld   then simCapSld:SetEnabled(oc)   end
        if mplusCapSld then mplusCapSld:SetEnabled(oc) end
        if histCapSld  then histCapSld:SetEnabled(oc)  end
        -- 2.10: refresh conflict threshold display
        if conflictSld then
            conflictSld:SetValue(addon.db.profile.conflictThreshold or 5)
            conflictSld._valLbl:SetText(
                tostring(addon.db.profile.conflictThreshold or 5))
        end
    end)
```

**Verification (manual):** Open Settings > Tuning. A "Display" card appears below the Scoring tuning card. Drag the "Conflict threshold" slider. Value updates live. Close panel, re-open — slider reflects the saved value. The voting frame picks up the new threshold on next session open (cache eviction in `doCellUpdate` clears `_sessionStats` when session/itemID changes).

---

### Task 6 — `UI/SettingsPanel.lua`: transparency opt-out toggle in `BuildDataTab`

**Files:** `UI/SettingsPanel.lua`

- [ ] 1. In `BuildDataTab`, inside the existing `"Transparency mode"` section card (`transCard`/`transInner`), add the opt-out toggle below the existing `transTog` toggle and `transHintLbl` FontString. The existing layout is:
  - `transTog` at `y = -4`
  - `transHintLbl` at `y = -28` (TOPLEFT of transInner)

  Add a new toggle at `y = -58` and a hint label below it:

```lua
    -- 2.11: player-side opt-out (always editable; per-character profile).
    local suppressTog = MakeToggle(transInner, {
        label = "Hide score label on my screen (overrides leader setting)",
        x = 4, y = -58,
        get = function()
            return (addon and addon.db.profile.suppressTransparencyLabel) or false
        end,
        set = function(v)
            if not addon then return end
            addon.db.profile.suppressTransparencyLabel = v and true or false
            -- Immediately re-render the loot frame if it is open.
            if ns.LootFrame and ns.LootFrame.Refresh then
                ns.LootFrame:Refresh()
            end
        end,
    })

    local suppressHint = transInner:CreateFontString(nil, "OVERLAY")
    suppressHint:SetFont(T.fontBody, T.sizeSmall)
    suppressHint:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
    suppressHint:SetPoint("TOPLEFT", transInner, "TOPLEFT", 26, -76)
    suppressHint:SetWidth(480)
    suppressHint:SetText(
        "Your choice. Does not affect what the leader or other raiders see. "
        .. "Saved per character.")
```

- [ ] 2. `suppressTog` is always enabled (unlike `transTog` which is disabled for non-leaders). Do not call `suppressTog:SetEnabled(isLeader)` inside the `OnShow` handler. It must be editable by any player regardless of leadership.

- [ ] 3. In the `body:SetScript("OnShow", ...)` handler, add a refresh line for `suppressTog` so it reads the current DB value when the panel is opened:

```lua
    -- (existing OnShow handler)
    body:SetScript("OnShow", function()
        updateInfoLabel()
        local d = _G.BobleLoot_Data
        if d and d.teamUrl then teamBtn:Show() else teamBtn:Hide() end

        local isLeader = UnitIsGroupLeader("player")
        transTog:SetEnabled(isLeader)
        transTog:SetChecked(addon and addon:IsTransparencyEnabled() or false)
        -- ...existing hint text logic...

        -- 2.11: always refresh suppress toggle from profile.
        if suppressTog then
            suppressTog:SetChecked(
                (addon and addon.db.profile.suppressTransparencyLabel) or false)
        end
    end)
```

- [ ] 4. Increase `transCard` height by ~45px to accommodate the new row. The card is currently anchored `BOTTOMRIGHT` to `body, "BOTTOMRIGHT", -6, 6` — check if this is a fixed-height card or a stretch card. From the source, `transCard` is stretch-anchored (TOPLEFT and BOTTOMRIGHT to body edges), so it automatically sizes to its content. No explicit height change is needed.

**Verification (manual):**
- Any player (leader or not): Settings > Data > Transparency card shows a second toggle "Hide score label on my screen". Toggle fires immediately, label disappears/reappears on the RC loot frame. Closing and reopening the panel shows the saved state.
- Leader: the existing "Enabled (raid leader only)" toggle is unaffected.
- Non-leader: existing toggle is greyed out; new toggle is always active.

---

### Task 7 — Slash command shortcut `/bl conflict <n>`

**Files:** `Core.lua`

This is a convenience shortcut so the raid leader can set the conflict threshold from chat without opening the panel. It mirrors the existing `/bl transparency on|off` pattern.

- [ ] 1. In `BobleLoot:OnSlashCommand`, in the `elseif` chain, add before the final `else` branch:

```lua
    elseif input:match("^conflict%s+%d+$") then
        local n = tonumber(input:match("^conflict%s+(%d+)$"))
        if n then
            n = math.max(0, math.min(n, 20))
            self.db.profile.conflictThreshold = n
            self:Print(string.format(
                "Conflict threshold set to %d. Takes effect on next voting frame render.", n))
        end
```

- [ ] 2. Add `/bl conflict <n>` to the help string in the final `else` branch:

```lua
    self:Print("Commands: /bl config | /bl minimap | /bl version | /bl broadcast | " ..
        "/bl transparency on|off | /bl conflict <0-20> | /bl checkdata | /bl lootdb | " ..
        "/bl debugchar <Name-Realm> | /bl test [N] | " ..
        "/bl score <itemID> <Name-Realm> | /bl syncwarnings")
```

**Verification (manual):** `/bl conflict 10` prints confirmation. Re-open voting frame; cells within 10 points get `~` prefix.

---

### Task 8 — Branch commit

- [ ] 1. Confirm the working branch is `plans/batch-2` (or the Batch 2 feature branch established by the batch-2 work coordination). Do not commit directly to `main` or `release/v1.1.0`.
- [ ] 2. Stage only the four modified files:
  - `Core.lua`
  - `VotingFrame.lua`
  - `LootFrame.lua`
  - `UI/SettingsPanel.lua`
- [ ] 3. Commit with message:

```
feat(2.10-2.11): conflict ~ prefix + compact transparency label + opt-out

- VotingFrame: extend _sessionStats with sortedScores/nameToScore map;
  isConflict() helper; doCellUpdate reads conflictThreshold from profile
  and passes conflict flag to formatScore; formatScore prefixes ~ in
  Theme.muted color when conflict=true.
- LootFrame: change label from "Your score: N" to "BL: N"; add
  suppressTransparencyLabel guard in renderEntry early-return chain.
- SettingsPanel: "Display" section in BuildTuningTab with conflict
  threshold slider (0-20, integer); suppressTransparencyLabel toggle
  in BuildDataTab Transparency card, always enabled, per-character.
- Core: DB_DEFAULTS gains conflictThreshold=5 and
  suppressTransparencyLabel=false; /bl conflict <n> slash shortcut.
```

---

## Manual Verification Checklist

### 2.10 — Conflict indicator

- [ ] Five candidates in a test session. Two have computed scores within 5 points (e.g. 74 and 71). Those two cells render `~74` and `~71`; the `~` is in grey/muted color distinct from the gradient-colored number. The other three cells render plain numbers.
- [ ] Open Settings > Tuning. Drag "Conflict threshold" to 10. Close panel. Re-open the voting frame (or wait for next session open to evict the cache). Now all candidates within 10 points of any other candidate show `~`.
- [ ] Set threshold to 0. No `~` prefixes appear anywhere.
- [ ] Tooltip on a conflict cell is unchanged — shows full breakdown without any `~` marker.
- [ ] Sort by score column still works correctly (`sortFn` does not touch `formatScore`).

### 2.11 — Compact label + opt-out

- [ ] Leader enables transparency. Player's RC loot frame shows `BL: 74` (not `Your score: 74`).
- [ ] Label color matches the score bracket (green/amber/red via `colorFor`). Unchanged from before.
- [ ] Hover over the entry frame: tooltip title still reads "Boble Loot — your score" with full component breakdown. The tooltip is unchanged.
- [ ] Open Settings > Data > Transparency card. Toggle "Hide score label on my screen". Label disappears immediately from the RC loot frame (next `LF:Refresh()` call). No error.
- [ ] Toggle off. Label re-appears on the next RC loot frame update.
- [ ] Close and re-open the game (or `/reload`). Opt-out state persists (AceDB profile save).
- [ ] A second player (non-leader) does NOT see a change in the leader's voting frame — confirming the opt-out only affects the local player's loot frame.
- [ ] Non-leader: the "Enabled (raid leader only)" toggle is greyed; the "Hide score label" toggle is active.

---

## Design Notes

### Why `~` and not another marker?

`~` (tilde) is the mathematical "approximately equal" symbol in many contexts and is already used in this sense in game UIs. It is a single ASCII character, always available in all WoW fonts, and narrow enough to not displace the number significantly in a 50px-wide column. Alternatives considered:

- `?` — already reserved for "in dataset but Scoring:Compute returned nil" (the unknown-score state from 1D). Reusing it here would conflate two distinct states.
- `*` — common asterisk has no universally understood "approximate" meaning in UI and reads as emphasis rather than uncertainty.
- `≈` — the true "approximately equal" Unicode character. Excluded because WoW's font rendering of non-ASCII characters in FontStrings is version-dependent and has historically caused blank glyphs on some client localizations.
- Color alone (no prefix) — considered but rejected: the gradient color is already semantically loaded (relative rank within the session). A color-only conflict indicator would require a second dimension of color variation on a cell that already uses color for ranking. The `~` adds an orthogonal visual channel.

The `~` is rendered in `Theme.muted` (grey) rather than the score's gradient color. This is intentional: the prefix signals ambiguity, not rank. Using the score's own gradient color would visually fuse the prefix with the number and lose the signal.

### Why compact label `BL: N` and not `Score: N` or another form?

The full form `"Your score: 74"` is 14 characters plus the number. On the RC loot frame, the entry row height is fixed (RC controls it) and the label is a FontString anchored under the time-left bar. At `GameFontNormalSmall` (~10pt), the full label wraps on some item entries with longer timeout bars, pushing it into the RC response buttons area. The compact form `"BL: 74"` (6 characters plus number) eliminates the wrapping risk.

`"BL:"` is the shortest unambiguous identifier for the addon. `"Score: N"` drops the branding and could be confused with RC's own Note field or a GM score system if a player runs multiple council addons. The tooltip — which the player sees on hover — immediately explains the breakdown in full.

### Why is `suppressTransparencyLabel` per-character profile (not account-wide)?

AceDB offers three scopes: `global`, `profile` (per-character by default in AceDB-3.0 when using `true` as the third argument to `AceDB:New`), and `realm`. The BobleLoot addon already calls `AceDB:New("BobleLootDB", DB_DEFAULTS, true)` — the `true` here means AceDB uses the per-character profile system.

The label suppression is inherently a per-session-seat preference. A player might run one character as a raider who wants to see their score, and another character on a casual alt where they prefer a cleaner UI. Account-wide storage (`global` scope) would force both characters to share the toggle state, which is wrong. Profile scope is the correct choice and is consistent with every other display preference in `DB_DEFAULTS` (e.g. `panelPos`, `lastTab`, `minimap.hide`).

Additionally, if the player is logged into the same account from two WoW clients simultaneously (cross-realm or multi-boxing scenarios), account-wide changes would overwrite each other. Profile scope avoids this.

---

## Coordination Notes

### Batch 1D cache key `(session, itemID)`

`_sessionStats` is keyed on `(session, itemID)` via the eviction guard in `doCellUpdate`:

```lua
if _sessionStats.session ~= session or _sessionStats.itemID ~= itemID then
    _sessionStats = {}
end
```

The new fields `sortedScores` and `nameToScore` are stored on the same `_sessionStats` table and are therefore evicted together whenever the session or item changes. No separate cache invalidation is needed.

`computeSessionStats` also has an early-return cache hit path:

```lua
if _sessionStats.session == session
   and _sessionStats.itemID  == itemID
   and _sessionStats.median ~= nil then
    return _sessionStats.median, _sessionStats.max
end
```

This early return fires *before* `nameToScore` is built. On a cache hit, `_sessionStats.nameToScore` already exists from the previous full computation, so `isConflict` in `doCellUpdate` reads it correctly. On a cache miss, the full computation path builds both the median/max and the `nameToScore` map together. The logic is consistent.

### Batch 2B (DB migration framework, item 2.7)

Batch 2B adds `BobleLootDB.profile.dbVersion` and a `Migrations` table. The two new profile keys introduced here (`conflictThreshold = 5` and `suppressTransparencyLabel = false`) are **additive defaults** in `DB_DEFAULTS`. AceDB handles additive keys by filling in the default for any profile that lacks the key — no migration is needed to introduce them.

However, if a future batch *renames* or *removes* one of these keys, that change requires a Batch 2B-style migration entry. Document this at the time of that future change by adding a migration that reads the old key, writes the new key, and nils the old one.

The Batch 2B coordination note to carry forward: when 2B's migration framework lands, the `conflictThreshold` and `suppressTransparencyLabel` keys should be explicitly listed in the migration baseline comment (the "version 0 schema" inventory) so 2B's `Migrations[1]` function can skip them as already-correct.

### Batch 2D (explain panel, item 2.9)

The pinnable explain panel (2.9) shows the same breakdown content as the voting frame tooltip. The conflict state is relevant context for the panel: if a candidate's score is a conflict with another candidate, the panel header could note "This score is within N points of [Name]'s score." This is **out of scope for 2E**; the coordination note is: 2D's plan should check `_sessionStats.nameToScore` and call `isConflict()` if it wants to surface this. Since `_sessionStats` is module-local to `VotingFrame.lua`, 2D will need either:

1. `VF.getSessionStats()` — a new accessor on the `VF` table (preferred; minimal surface), or
2. Pass the conflict flag through the right-click context (the event that opens the explain panel from 2.9's right-click hook).

Recommendation: when 2D is planned, expose `VF.getSessionStats = function() return _sessionStats end` as a single-line addition to `VotingFrame.lua`. This plan does not add that accessor now to avoid pre-emptive scope creep, but it is trivial to add.
