# Batch 4E — Empty and Error States Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every UI surface has a designed, readable state for its empty and error conditions — no accidental blanks.

**Architecture:** Audit-first approach — inventory every surface x condition; fill gaps with tooltips, explanatory text, and disabled-state messages following the existing `Theme.muted` / `Theme.warning` / `Theme.danger` convention. Where a surface is pending a later merge (3D, 3E, 4D), the plan documents the required behaviour and the exact code to add at merge time. Where a surface already exists and ships a gap, the plan patches it directly.

**Tech Stack:** Lua (WoW 10.x), `ns.Theme` muted/warning colors, existing tooltip (`GameTooltip:AddLine` / `AddDoubleLine`) and disabled-state patterns, `C_Timer.After` for auto-hide, `CreateFontString` for in-frame help text.

**Roadmap items covered:**

> **4.12 `[UI]` Empty and error states audit**
>
> Single pass across every UI surface to ensure every empty/error
> condition has a designed state, not an accidental blank:
>
> - Score cell, no dataset entry — done in 1.6.
> - Score cell, no components with data — `"?"` in muted grey.
> - History viewer, zero entries — centred help text explaining how to
>   widen the date window or check RC loot history.
> - Sync timeout — toast reading `"Dataset sync timed out — using local
>   data."` rather than silence.
> - Settings panel Data tab, RC missing — see 4.10.
> - Settings panel Test tab, RC missing or solo — button disabled with
>   tooltip explaining why.

**Dependencies:**
- Batch 1D (`VotingFrame.lua`): `formatScore`, `doCellUpdate`, `fillScoreTooltip` — the score cell renderer this plan extends with the `?` third state.
- Batch 1E (`UI/MinimapButton.lua`, `UI/SettingsPanel.lua`): minimap tooltip builder, Test tab Run button, Weights tab normalizer, Data tab transparency toggle — all audited here.
- Batch 2C (`Sync.lua`): fires `BobleLoot_SyncTimedOut` AceEvent — consumed by the toast wire-up this plan adds.
- Batch 2D (`UI/ExplainPanel.lua`): no-breakdown state already handled in its `RenderContent`; this audit verifies the message text matches the standard and adds the item-has-no-data path when `itemID = 0`.
- Batch 2E (`UI/SettingsPanel.lua`): conflict-threshold slider in Display group; does not introduce empty states beyond Batch 1E.
- Batch 3B (`Scoring.lua`): `GetScoreTrend` contract specifies "0 or 1 entries → show 'Not enough data'"; this plan specifies the tooltip wording.
- Batch 3D (`UI/ComparePopout.lua`): single-candidate guard already specced in 3D plan Task 10.1; this audit verifies the exact tooltip message matches the standard.
- Batch 3E (`UI/HistoryViewer.lua`, `UI/Toast.lua`): zero-entries help text and sync-timeout wire-up are new changes this plan adds to those modules.
- Batch 4C (`UI/SettingsPanel.lua`): RC version info line in Data tab; 4E verifies it degrades gracefully when RC is absent.
- Batch 4D (`UI/SettingsPanel.lua`): RC-not-detected banner (4.10) and colorblind palette (4.11); 4E verifies banner text exactly matches spec and color-mode dropdown degrades cleanly when only one mode exists.

---

## Comprehensive Inventory Table

Each row is one (Surface) x (Condition) pair. "Touch" column values:
- **none** — already correct; audit only.
- **verify-text** — code path exists but exact message text must match spec; update if different.
- **tooltip** — add or improve a `SetScript("OnEnter")` / `GameTooltip` block.
- **new-text** — new `FontString` or `AddLine` inside existing frame.
- **new-handler** — new AceEvent registration or `C_Timer` wire-up.
- **pending-merge** — surface does not yet exist; action applies at merge time.

| # | Surface | File | Condition | Current Behaviour | Desired Behaviour | Touch |
|---|---------|------|-----------|-------------------|-------------------|-------|
| 1 | Score cell | `VotingFrame.lua` | Candidate not in dataset | `—` in muted grey (Batch 1D) | Same — already designed | none |
| 2 | Score cell | `VotingFrame.lua` | Candidate in dataset, `Scoring:Compute` returns `nil` (all components missing or weight=0) | `?` in `#666666` grey (Batch 1D `formatScore` adds this) | `?` in `Theme.muted` grey with tooltip "In dataset but no scoreable components — check weights" | tooltip |
| 3 | Score cell tooltip | `VotingFrame.lua` | Candidate in dataset, score is `nil` | "No scoreable components for this candidate/item." (Batch 1D `fillScoreTooltip`) | Same — already designed | none |
| 4 | Score cell | `VotingFrame.lua` | `itemID` is nil (RC hasn't assigned session item yet) | `cellFrame.text:SetText("")` — blank | Blank is correct (session not started); document as intentional | none |
| 5 | History viewer | `UI/HistoryViewer.lua` | Zero rows after applying current filters | Blank scrollable area (Batch 3E does not spec an empty state) | Centred `FontString`: "No loot entries match the current filters. Try widening the date window or check that RC loot history has been recorded." | new-text |
| 6 | History viewer | `UI/HistoryViewer.lua` | Zero rows, no filters applied (RC loot DB genuinely empty) | Blank scrollable area | Centred `FontString`: "No loot history found. RC loot history is recorded while you are in a raid using RCLootCouncil." | new-text |
| 7 | Toast system | `UI/Toast.lua` | `BobleLoot_SyncTimedOut` AceEvent fires | Silence (Batch 3E wires other events but not this one) | Toast: `"Dataset sync timed out — using local data."` at `warning` level | new-handler |
| 8 | Toast system | `UI/Toast.lua` | No events queued | Frame hidden at alpha 0 | Frame remains hidden — intentional; document | none |
| 9 | Settings — Data tab | `UI/SettingsPanel.lua` | RC not detected after 10s grace period | Banner: `"|cffff5555RCLootCouncil not detected. Score column will appear once RC loads.|r"` (Batch 4D) | Same — audit verifies exact string is present | verify-text |
| 10 | Settings — Data tab | `UI/SettingsPanel.lua` | RC version compatibility: detected version is unsupported | Red "Tested on RC %s, detected %s — unsupported" line (Batch 4C) | Same — audit verifies the three color states exist | verify-text |
| 11 | Settings — Data tab | `UI/SettingsPanel.lua` | Transparency toggle, player is not group leader | Toggle disabled; muted hint below (Batch 1E) | Verify tooltip on the disabled toggle says "Only the raid/group leader can toggle transparency" | tooltip |
| 12 | Settings — Test tab | `UI/SettingsPanel.lua` | RC not loaded | Button disabled; amber `reasonLbl` below (Batch 1E) | Add `SetScript("OnEnter")` tooltip on disabled button: "RCLootCouncil must be loaded to run a test session." | tooltip |
| 13 | Settings — Test tab | `UI/SettingsPanel.lua` | RC loaded, player is not group leader, not solo | Button disabled; amber `reasonLbl` below (Batch 1E) | Add `SetScript("OnEnter")` tooltip on disabled button: "You must be the group leader (or solo) to start a test session." | tooltip |
| 14 | Settings — Test tab | `UI/SettingsPanel.lua` | RC loaded, player is leader or solo | Button enabled | No tooltip needed on enabled button — already has label "Run test session" | none |
| 15 | Settings — Weights tab | `UI/SettingsPanel.lua` | All five components toggled off (`countEnabled` returns 0) | `normalizeWeights` returns early; sliders show 0; example row shows 0.0 / 100 | Same — the `n == 0` early-return is correct; add a visible muted note below the example row: "All components disabled — enable at least one." | new-text |
| 16 | Minimap button | `UI/MinimapButton.lua` | `BobleLoot_Data` is nil (no dataset loaded) | `"Dataset: not loaded"` in muted text (Batch 1E `BuildTooltip`) | Change to "No dataset loaded — run tools/wowaudit.py" for clarity | verify-text |
| 17 | Comparison popout | `UI/ComparePopout.lua` | Only one scored candidate in session (shift-click) | Tooltip hint "Need at least two scored candidates to compare." for 2s (Batch 3D Task 10.1) | Verify the tooltip wording matches this spec exactly | verify-text |
| 18 | Comparison popout | `UI/ComparePopout.lua` | `nameB` resolves to the same name as `nameA` (top candidate shift-clicked) | Same tooltip guard as row 17 | Same | verify-text |
| 19 | Explain panel | `UI/ExplainPanel.lua` | Candidate not in dataset | Muted "(not in BobleLoot dataset — run tools/wowaudit.py and /reload)" (Batch 2D) | Same — already designed | none |
| 20 | Explain panel | `UI/ExplainPanel.lua` | Candidate in dataset, score is `nil` | "No scoreable components for this candidate/item." in red (Batch 2D) | Same — already designed. Add label: "No scoring data for this item." when `itemID = 0` is passed | new-text |
| 21 | Explain panel | `UI/ExplainPanel.lua` | Called with `itemID = 0` (slash command with no active session) | Score is nil; falls through to "No scoreable components" | Show "No scoring data for this item — open a voting session first." at the top, before the name header | new-text |
| 22 | Transparency label | `LootFrame.lua` | Transparency off | Label hidden, no text | Correct — by design | none |
| 23 | Transparency label | `LootFrame.lua` | Player not in dataset | Label hidden (`key = nil` early return at line 157) | Show `"BL: —"` in muted grey with tooltip "You are not in the BobleLoot dataset. Run tools/wowaudit.py and /reload." | new-text + tooltip |
| 24 | Transparency label | `LootFrame.lua` | Player in dataset, score is nil (all components missing) | Label hidden (`not score` early return at line 181) | Show `"BL: ?"` in muted grey with tooltip "No scoring data for this item." | new-text + tooltip |
| 25 | Score trend tooltip | `VotingFrame.lua` / `UI/ExplainPanel.lua` | `GetScoreTrend` returns 0 or 1 entries | Not yet rendered (Batch 3B defines the API; Batch 3D/3E consume it) | When the trend section is rendered: show "No score history for this item yet." | pending-merge |
| 26 | Score trend tooltip | `UI/ExplainPanel.lua` | `GetTrendSummary` returns nil | Trend line omitted silently | Correct — per Batch 3B contract; document | none |
| 27 | Settings — Weights tab | `UI/SettingsPanel.lua` | No dataset loaded (example row computes against nil data) | Example score row shows 0.0 / 100 in the live preview | Correct — score of zero with no data is valid; muted label "(example — no dataset)" already explains | verify-text |
| 28 | Settings — LootDB tab | `UI/SettingsPanel.lua` | RC loot DB empty (no entries scanned) | Shows 0 / 0 scanned | Shows 0 / 0 and a muted hint: "No RC loot history found." | verify-text |
| 29 | Bench-mode slash output | `Core.lua` | `/bl benchscore` with no active session | Error or empty output | Print to chat: "No active voting session. Open a voting session in RC first." | verify-text |

---

## Design Decisions

**Row 23 — transparency label when player not in dataset:**
The two options were (a) hide the label entirely or (b) show `"BL: —"`. Hiding was rejected because the player has no feedback that BobleLoot is active and simply lacks their data — they would think the feature is broken. `"BL: —"` with an explanatory tooltip matches the score-cell convention (row 1) and is consistent with the principle "missing data is a state, not a failure" (cross-cutting principle #2).

**Row 24 — transparency label when score is nil:**
Same reasoning. `"BL: ?"` mirrors the score-cell `?` state (row 2) and signals "data exists but scoring failed" rather than "not in dataset."

**Row 15 — all-components-disabled note:**
The `normalizeWeights` early-return already prevents a divide-by-zero. The example score row showing `0.0 / 100` is technically correct but confusing without explanation. A single muted `FontString` below the example row resolves the ambiguity without disrupting the tab layout.

**Row 5 vs 6 — two zero-entries messages in HistoryViewer:**
The distinction matters: a filtered zero means "widen filters"; an unfiltered zero means "RC hasn't recorded anything." Both states must be distinguishable because the user action differs.

---

## File Structure

Files modified by this plan:

```
VotingFrame.lua                    -- score cell ? tooltip; transparency label ? state
LootFrame.lua                      -- transparency label not-in-dataset and nil-score states
UI/MinimapButton.lua               -- dataset-missing tooltip wording
UI/SettingsPanel.lua               -- Test tab Run button tooltips; Weights all-disabled note;
                                   --   RC-banner text audit; transparency toggle tooltip audit
UI/HistoryViewer.lua               -- zero-entries help text (both filter and unfiltered)
UI/Toast.lua                       -- BobleLoot_SyncTimedOut wire-up
UI/ExplainPanel.lua                -- itemID=0 help text; score-nil message audit
```

No new files. No TOC changes (all files already registered in prior batches).

---

## Task 1 — `VotingFrame.lua`: score cell `?` state tooltip

**Files:** `VotingFrame.lua`

**Gap addressed:** Row 2 in inventory. Batch 1D already produces `?` in `#666666` for the nil-score / in-dataset condition, but there is no `OnEnter` tooltip to explain what `?` means. A player or council member who sees `?` in the score column has no guidance.

**Context:** `doCellUpdate` sets `cellFrame.text:SetText(formatScore(score))` and then sets a `SetScript("OnEnter", ...)` that calls `fillScoreTooltip`. The `fillScoreTooltip` function already handles the nil-score case with the line `"No scoreable components for this candidate/item."` However, the `?` state is the `score == nil AND inDataset == true` case — `fillScoreTooltip` is already called, so the tooltip already explains the situation. What is missing is a dedicated tooltip for the `?` cell that is slightly more specific.

**Decision:** `fillScoreTooltip` already fires correctly and shows the right message. The gap is that the existing `OnEnter` handler calls `fillScoreTooltip` regardless of the score state, which means the tooltip does appear. Audit confirms: this state is covered. The only improvement needed is ensuring the `?` tooltip includes the exact phrase specified in the audit row.

- [ ] 1.1 Open `VotingFrame.lua`. Locate `fillScoreTooltip`. Find the block that handles `not s`:

  ```lua
  if not s then
      tt:AddLine("|cffff7070No scoreable components for this candidate/item.|r")
      return
  end
  ```

  Verify this block is present. If the text differs (e.g., shortened during implementation), update to match exactly: `"No scoreable components for this candidate/item."`

- [ ] 1.2 Also confirm that `doCellUpdate` still calls `fillScoreTooltip` inside its `OnEnter` handler when the score is nil (i.e., the handler is not skipped for nil scores). The `OnEnter` is set unconditionally after `computeScoreForRow`; confirm there is no early `return` that would skip the tooltip for a nil score.

- [ ] 1.3 Locate `formatScore`. Confirm the nil-score / in-dataset branch produces `"|cff666666?|r"`. If the implementation uses a different colour constant (the plan spec calls for `Theme.muted` grey), update to use `ns.Theme and ns.Theme.muted` dynamically:

  ```lua
  -- In formatScore, nil-score / in-dataset branch:
  local m = ns.Theme and ns.Theme.muted or { 0.53, 0.53, 0.53, 1 }
  return string.format("|cff%02x%02x%02x?|r",
      math.floor(m[1]*255), math.floor(m[2]*255), math.floor(m[3]*255))
  ```

  This ensures the `?` character matches the muted palette if the colorblind mode from Batch 4D swaps `Theme.muted`.

**Verification:** `/reload`. Open a voting session where a candidate exists in the dataset but all weights are set to 0 (toggle all off in the Weights tab temporarily). Confirm the cell shows `?` in grey. Hover the cell: tooltip should show "No scoreable components for this candidate/item." Restore weights.

**Commit:** `fix(VotingFrame): use Theme.muted for ? cell; verify no-score tooltip path`

---

## Task 2 — `LootFrame.lua`: transparency label not-in-dataset and nil-score states

**Files:** `LootFrame.lua`

**Gaps addressed:** Rows 23 and 24. Currently `renderEntry` returns with an empty label when the player's character key is not found (`not key`) or when the score is nil (`not score`). Both produce an invisible label — no feedback to the player.

- [ ] 2.1 Open `LootFrame.lua`. Locate `renderEntry`. Find the block at approximately line 157:

  ```lua
  local key  = lookupChar(data)
  local iid  = entryItemID(entry)
  if not key or not iid then
      fs:SetText("")
      entryFrame[SCORE_FRAME_KEY .. "_ctx"] = nil
      return
  end
  ```

  Split into two cases. Replace with:

  ```lua
  local key  = lookupChar(data)
  local iid  = entryItemID(entry)

  if not iid then
      -- No item ID resolved — session not ready yet. Blank is correct.
      fs:SetText("")
      entryFrame[SCORE_FRAME_KEY .. "_ctx"] = nil
      return
  end

  if not key then
      -- Player is in transparency mode but not in the dataset.
      local m = ns.Theme and ns.Theme.muted or { 0.53, 0.53, 0.53, 1 }
      fs:SetTextColor(m[1], m[2], m[3])
      fs:SetText("BL: \xe2\x80\x94")   -- em-dash
      entryFrame[SCORE_FRAME_KEY .. "_ctx"] = { notInDataset = true }
      return
  end
  ```

- [ ] 2.2 Locate the block at approximately line 181:

  ```lua
  if not score then
      fs:SetText("")
      entryFrame[SCORE_FRAME_KEY .. "_ctx"] = nil
      return
  end
  ```

  Replace with:

  ```lua
  if not score then
      -- Player is in dataset but all components returned nil.
      local m = ns.Theme and ns.Theme.muted or { 0.53, 0.53, 0.53, 1 }
      fs:SetTextColor(m[1], m[2], m[3])
      fs:SetText("BL: ?")
      entryFrame[SCORE_FRAME_KEY .. "_ctx"] = { noComponents = true }
      return
  end
  ```

- [ ] 2.3 Locate the `OnEnter` hook inside `attachLabel`. Currently it returns early when `not ctx or not ctx.score`. Replace with a three-branch handler:

  ```lua
  entryFrame:HookScript("OnEnter", function(self)
      local ctx = self[SCORE_FRAME_KEY .. "_ctx"]
      if not ctx then return end

      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine("|cffddddddBoble Loot|r")

      if ctx.notInDataset then
          local playerName = UnitName("player") or "?"
          GameTooltip:AddLine(" ")
          GameTooltip:AddLine(string.format(
              "|cffaaaaaa%s is not in the BobleLoot dataset.|r", playerName))
          GameTooltip:AddLine(
              "|cff888888Run tools/wowaudit.py and /reload.|r")
          GameTooltip:Show()
          return
      end

      if ctx.noComponents then
          GameTooltip:AddLine(" ")
          GameTooltip:AddLine(
              "|cffaaaaaa No scoring data for this item.|r")
          GameTooltip:AddLine(
              "|cff888888All score components returned no data.|r")
          GameTooltip:Show()
          return
      end

      -- Normal path — score present.
      if not ctx.score then return end
      GameTooltip:AddDoubleLine("Score",
          string.format("%.1f / 100", ctx.score), 1, 1, 1, 1, 1, 1)
      if ctx.fromLeader then
          GameTooltip:AddLine(
              "|cff80c0ffSent by raid leader (authoritative).|r")
      end
      if ctx.breakdown then
          GameTooltip:AddLine(" ")
          for k, v in pairs(ctx.breakdown) do
              GameTooltip:AddDoubleLine(k,
                  string.format("%.2f x %.0f%%", v.value,
                      (v.effectiveWeight or v.weight) * 100),
                  0.9, 0.9, 0.9, 1, 1, 1)
          end
      end
      GameTooltip:Show()
  end)
  ```

**Verification:** Two separate tests:

Test A (not-in-dataset): Set `BobleLoot_Data` to a dataset that does not include your character. Enable transparency mode. Open the RC loot frame for a dummy item. Confirm the label shows `BL: —` in muted grey. Hover: tooltip shows your character name and the dataset instruction.

Test B (nil-score): Set all weights to 0 in the Weights tab. Enable transparency mode. Open the RC loot frame. Confirm the label shows `BL: ?` in muted grey. Hover: tooltip shows "No scoring data for this item."

Restore weights after testing.

**Commit:** `feat(LootFrame): show BL:— and BL:? transparency states for missing/no-score conditions`

---

## Task 3 — `UI/MinimapButton.lua`: dataset-missing tooltip wording

**Files:** `UI/MinimapButton.lua`

**Gap addressed:** Row 16. The current Batch 1E `BuildTooltip` shows `"Dataset: not loaded"` when `BobleLoot_Data` is nil. This is ambiguous — a user who sees "not loaded" may not know what action to take.

- [ ] 3.1 Open `UI/MinimapButton.lua`. Locate the `if not data then` block inside `MB:BuildTooltip`:

  ```lua
  if not data then
      tt:AddLine("|cff...|r"
          .. "Dataset: not loaded|r")
  ```

  The exact implementation may vary slightly. Update the muted-grey line to read:

  ```lua
  if not data then
      local m = ns.Theme and ns.Theme.muted or { 0.53, 0.53, 0.53, 1 }
      local hex = string.format("%02x%02x%02x",
          math.floor(m[1]*255), math.floor(m[2]*255), math.floor(m[3]*255))
      tt:AddLine("|cff" .. hex
          .. "No dataset loaded — run tools/wowaudit.py|r")
  ```

- [ ] 3.2 Verify that the second line of the `if not data then` block (if there was a second line like "run wowaudit.py") is removed to avoid duplication with the new combined message.

**Verification:** `/reload` with `BobleLoot_Data.lua` absent or renamed temporarily. Hover minimap icon. Confirm tooltip shows: title line in cyan, then `"No dataset loaded — run tools/wowaudit.py"` in muted grey, then the loot-history line, then the transparency line, then the hint.

**Commit:** `fix(MinimapButton): clarify dataset-missing tooltip text`

---

## Task 4 — `UI/SettingsPanel.lua`: Test tab Run button tooltips

**Files:** `UI/SettingsPanel.lua`

**Gaps addressed:** Rows 12 and 13. Batch 1E's `checkRunnable` sets the button disabled and populates `reasonLbl` below with text, but the button itself has no `OnEnter` tooltip. A user who sees a greyed-out button may not immediately look below for the reason text — especially on smaller screens where the label may be below the fold.

- [ ] 4.1 Open `UI/SettingsPanel.lua`. Locate `BuildTestTab`. Find the `runBtn` creation block and the `checkRunnable` local function.

- [ ] 4.2 After `runBtn` is created (after the `MakeButton(inner, "Run test session", ...)` call), add tooltip scripts on the button:

  ```lua
  -- Tooltip for the disabled state. Shown by OnEnter on the button frame itself.
  runBtn:SetScript("OnEnter", function(self)
      if self:IsEnabled() then return end   -- no tooltip needed when enabled
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine("|cffddddddBoble Loot — Test Session|r")
      -- Re-derive the reason so the tooltip text matches whatever checkRunnable set.
      local RCAceAddon = LibStub and LibStub("AceAddon-3.0", true)
      local RC
      if RCAceAddon then
          local ok, r = pcall(function()
              return RCAceAddon:GetAddon("RCLootCouncil", true)
          end)
          RC = ok and r or nil
      end
      if not RC then
          GameTooltip:AddLine(
              "RCLootCouncil must be loaded to run a test session.",
              1, 0.8, 0.2)
      elseif IsInGroup() and not UnitIsGroupLeader("player") then
          GameTooltip:AddLine(
              "You must be the group leader (or solo) to start a test session.",
              1, 0.8, 0.2)
      end
      GameTooltip:Show()
  end)
  runBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  ```

- [ ] 4.3 Confirm that the existing `checkRunnable` function, which populates `reasonLbl`, remains unchanged. The tooltip and the reason label are complementary: the tooltip surfaces on hover, the label is always visible below the button.

**Verification:** Disable RCLootCouncil, `/reload`. Open Settings > Test tab. Hover the greyed-out "Run test session" button. Confirm tooltip appears reading "RCLootCouncil must be loaded to run a test session." in amber/orange. Re-enable RC, `/reload`. In a group where player is not leader: hover button, confirm tooltip reads "You must be the group leader (or solo)..."

**Commit:** `feat(SettingsPanel): add explanatory tooltip on disabled Test-tab Run button`

---

## Task 5 — `UI/SettingsPanel.lua`: Weights tab all-components-disabled note

**Files:** `UI/SettingsPanel.lua`

**Gap addressed:** Row 15. When all five weight components are toggled off, `normalizeWeights` returns early, sliders all read 0, and the example score row shows `0.0 / 100`. This is technically correct but confusing without explanation.

- [ ] 5.1 Open `UI/SettingsPanel.lua`. Locate `BuildWeightsTab`. Find the live-preview example score row — a `FontString` or `Button` that calls `Scoring:Compute` with the current weights and renders the result.

- [ ] 5.2 Below the example score row, add a `FontString` for the all-disabled notice. The label is hidden by default and shown only when `countEnabled` returns 0:

  ```lua
  local allDisabledLbl = inner:CreateFontString(nil, "OVERLAY")
  allDisabledLbl:SetFont(T.fontBody, T.sizeSmall)
  allDisabledLbl:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
  allDisabledLbl:SetText("All components disabled — enable at least one.")
  allDisabledLbl:SetPoint("TOPLEFT", exampleRow, "BOTTOMLEFT", 0, -4)
  allDisabledLbl:Hide()
  ```

  (Substitute `exampleRow` with the actual reference to the example score `FontString` or frame as named in the Batch 1E implementation.)

- [ ] 5.3 Inside `normalizeWeights` (or just after the call to it in the slider `OnValueChanged` handler), add show/hide logic:

  ```lua
  if countEnabled(p.weightsEnabled) == 0 then
      allDisabledLbl:Show()
  else
      allDisabledLbl:Hide()
  end
  ```

  This must also run in the tab's `OnShow` callback so the label reflects the persisted state on panel open.

- [ ] 5.4 Add the same show/hide call in the toggle checkbox's `set` callback, immediately after `normalizeWeights(p.weights, p.weightsEnabled)`:

  ```lua
  if countEnabled(p.weightsEnabled) == 0 then
      allDisabledLbl:Show()
  else
      allDisabledLbl:Hide()
  end
  ```

**Verification:** Open Settings > Weights tab. Toggle all five components off one at a time. After the last toggle, confirm the muted label "All components disabled — enable at least one." appears below the example row. Toggle one component back on; label disappears.

**Commit:** `feat(SettingsPanel): show warning when all Weights-tab components are disabled`

---

## Task 6 — `UI/SettingsPanel.lua`: Data tab — audit RC-banner text and transparency-toggle tooltip

**Files:** `UI/SettingsPanel.lua`

**Gaps addressed:** Rows 9 and 11.

**Row 9 — RC-not-detected banner (Batch 4D):**

- [ ] 6.1 After Batch 4D is merged, open `UI/SettingsPanel.lua`. Locate the RC-not-detected banner text. Confirm it reads exactly:

  ```
  "|cffff5555RCLootCouncil not detected. Score column will appear once RC loads.|r"
  ```

  If the text differs (e.g., slightly shortened during 4D implementation), update to match the spec exactly. This string is the canonical wording specified in roadmap item 4.10.

**Row 11 — transparency toggle tooltip when not leader:**

- [ ] 6.2 Locate `BuildDataTab`. Find the `transTog` checkbox (label: "Enabled (raid leader only)"). The checkbox is disabled when `not isLeader`. Currently it has no `OnEnter` tooltip.

- [ ] 6.3 After the `transTog` checkbox is created, add tooltip scripts:

  ```lua
  -- Wire a tooltip on the toggle itself so hovering a greyed control explains why.
  local toggleWidget = transTog  -- the actual WoW Frame returned by MakeToggle
  if toggleWidget and toggleWidget.SetScript then
      toggleWidget:HookScript("OnEnter", function(self)
          if UnitIsGroupLeader("player") then return end
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          GameTooltip:AddLine("|cffddddddBoble Loot — Transparency|r")
          GameTooltip:AddLine(
              "Only the raid leader can toggle transparency mode.",
              0.53, 0.53, 0.53)
          GameTooltip:Show()
      end)
      toggleWidget:HookScript("OnLeave", function() GameTooltip:Hide() end)
  end
  ```

  Note: `MakeToggle` in Batch 1E may return the checkbox `Button` frame or a wrapper table. Use `HookScript` rather than `SetScript` to avoid overwriting the checkbox's existing mouse scripts. If `MakeToggle` returns a table with a `.frame` field, replace `transTog` with `transTog.frame`.

**Verification (Row 9):** After Batch 4D merge, suppress RC, `/reload`. Open Settings > Data tab. Confirm the banner reads exactly the specified string.

**Verification (Row 11):** Log in as a non-leader in a group. Open Settings > Data tab. Hover the "Enabled (raid leader only)" checkbox. Confirm tooltip appears: "Only the raid leader can toggle transparency mode."

**Commit:** `feat(SettingsPanel): tooltip on disabled transparency toggle; verify RC-banner text`

---

## Task 7 — `UI/HistoryViewer.lua`: zero-entries help text

**Files:** `UI/HistoryViewer.lua`

**Gaps addressed:** Rows 5 and 6. This task applies when Batch 3E is merged. If the module does not yet exist, document this as a pending-merge action and add the code at merge time.

**Architecture note:** `HistoryViewer:Refresh()` builds the row data from the filtered RC loot DB. The empty-state `FontString` is a child of the scrollable content frame, centred, hidden by default, shown when `#rows == 0`.

- [ ] 7.1 After Batch 3E is merged, open `UI/HistoryViewer.lua`. Locate `BuildFrame()`. Find the scrollable content area (the `content` frame inside the `ScrollFrame`). After creating the content frame, create two `FontString` children for the empty states:

  ```lua
  -- Empty-state labels (shown mutually exclusively when row count == 0).
  local emptyFiltered = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  emptyFiltered:SetFont(T.fontBody, T.sizeBody)
  emptyFiltered:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
  emptyFiltered:SetText(
      "No loot entries match the current filters.\n"
      .. "Try widening the date window or check that\n"
      .. "RC loot history has been recorded.")
  emptyFiltered:SetJustifyH("CENTER")
  emptyFiltered:SetPoint("CENTER", content, "CENTER", 0, 0)
  emptyFiltered:Hide()
  frame._emptyFiltered = emptyFiltered

  local emptyNoRC = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  emptyNoRC:SetFont(T.fontBody, T.sizeBody)
  emptyNoRC:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
  emptyNoRC:SetText(
      "No loot history found.\n"
      .. "RC loot history is recorded while you are\n"
      .. "in a raid using RCLootCouncil.")
  emptyNoRC:SetJustifyH("CENTER")
  emptyNoRC:SetPoint("CENTER", content, "CENTER", 0, 0)
  emptyNoRC:Hide()
  frame._emptyNoRC = emptyNoRC
  ```

- [ ] 7.2 Locate the `Refresh()` function (or the equivalent `buildRows` / `applyFilter` local). After the row list is computed and before the table is populated, add:

  ```lua
  -- Show the appropriate empty-state label when there are no rows.
  local hasFilters = (HV.currentFilter ~= nil and HV.currentFilter ~= "")
                     or (HV.currentDays ~= nil and HV.currentDays < 28)
  if #rows == 0 then
      if hasFilters then
          if frame._emptyFiltered then frame._emptyFiltered:Show() end
          if frame._emptyNoRC    then frame._emptyNoRC:Hide()       end
      else
          if frame._emptyFiltered then frame._emptyFiltered:Hide() end
          if frame._emptyNoRC    then frame._emptyNoRC:Show()      end
      end
  else
      if frame._emptyFiltered then frame._emptyFiltered:Hide() end
      if frame._emptyNoRC    then frame._emptyNoRC:Hide()      end
  end
  ```

  Adjust `HV.currentFilter` and `HV.currentDays` to match the actual field names used in the Batch 3E implementation.

**Verification:** Open `/bl history`. With an empty RC loot DB (fresh install or cleared SavedVars), confirm the unfiltered empty message appears centred. Apply a player filter or narrow the date window with rows present, then set dates to a window where no loot was awarded — confirm the filtered empty message appears.

**Commit:** `feat(HistoryViewer): add centred help text for zero-entries states (4.12)`

---

## Task 8 — `UI/Toast.lua`: wire `BobleLoot_SyncTimedOut`

**Files:** `UI/Toast.lua`

**Gap addressed:** Row 7. Batch 3E's `Toast:Setup` registers several AceEvents but the Batch 2C plan's `_onChunkTimeout` fires `BobleLoot_SyncTimedOut` specifically. Batch 3E does wire this event (per the plan's listener list at line 276), but the implementation must be verified, and if absent the wire-up must be added.

- [ ] 8.1 After Batch 3E is merged, open `UI/Toast.lua`. Locate `Toast:Setup`. Find the block where AceEvents are registered. Confirm the following listener is present:

  ```lua
  addon:RegisterMessage("BobleLoot_SyncTimedOut", function(_, sender)
      Toast:Show("Dataset sync timed out \xe2\x80\x94 using local data.", "warning")
  end)
  ```

  The em-dash in `"timed out \xe2\x80\x94 using local data."` is the UTF-8 encoding of U+2014 (—). This must match the roadmap spec exactly: `"Dataset sync timed out — using local data."`.

- [ ] 8.2 If the event is already wired but the message text differs, update it to the exact roadmap wording.

- [ ] 8.3 If the event is not present, add the `RegisterMessage` call immediately after the existing `BobleLoot_SyncWarning` listener:

  ```lua
  addon:RegisterMessage("BobleLoot_SyncTimedOut", function(_, sender)
      Toast:Show("Dataset sync timed out \xe2\x80\x94 using local data.", "warning")
  end)
  ```

- [ ] 8.4 Confirm that `Toast:Show` at `"warning"` level renders in `Theme.warning` yellow, consistent with the level-color mapping in Batch 3E.

**Verification:** Simulate a chunk timeout by connecting two clients and interrupting the transfer mid-way (or by running `/run BobleLoot:SendMessage("BobleLoot_SyncTimedOut", "TestSender")` directly). Confirm the toast appears with yellow tint and the exact text: `"Dataset sync timed out — using local data."`

**Commit:** `feat(Toast): wire BobleLoot_SyncTimedOut to warning toast (4.12)`

---

## Task 9 — `UI/ExplainPanel.lua`: `itemID = 0` help text

**Files:** `UI/ExplainPanel.lua`

**Gap addressed:** Row 21. When `/bl explain <Name-Realm>` is called outside an active voting session, `Core.lua` passes `itemID = 0`. `RenderContent` calls `addon:GetScore(0, name, ...)` which returns nil. The current Batch 2D code falls through to "No scoreable components" — correct in intent but wrong in specificity for this case.

- [ ] 9.1 After Batch 2D is merged, open `UI/ExplainPanel.lua`. Locate `RenderContent`. Find the opening block that checks `itemID and itemID > 0`:

  ```lua
  if addon and itemID and itemID > 0 then
      -- ...score computation...
  end
  ```

- [ ] 9.2 Before the `if not inDs then` block, add a zero-itemID guard:

  ```lua
  -- itemID = 0 means no active voting session.
  if not itemID or itemID == 0 then
      AddLine("No scoring data for this item.", T.muted[1], T.muted[2], T.muted[3])
      AddLine("|cff666666Open a voting session in RC first,|r",
              T.muted[1], T.muted[2], T.muted[3])
      AddLine("|cff666666then use /bl explain <Name-Realm>.|r",
              T.muted[1], T.muted[2], T.muted[3])
      return
  end
  ```

  This returns early before trying to look up the character or compute a score.

- [ ] 9.3 Confirm that `EP:Open` (which calls `RenderContent`) still shows the title bar and the frame chrome before calling `RenderContent` — the frame must still display with its title "BobleLoot — Explain: <name>" even when the content is the help text.

**Verification:** Close any active voting session. Run `/bl explain Testchar-Realm`. Confirm the panel opens, the title bar shows "BobleLoot — Explain: Testchar-Realm", and the content area shows the three help lines in muted grey.

**Commit:** `feat(ExplainPanel): show help text when itemID=0 (no active session)`

---

## Task 10 — `UI/ComparePopout.lua`: verify single-candidate tooltip (pending Batch 3D)

**Files:** `UI/ComparePopout.lua` (Batch 3D file, pending merge)

**Gaps addressed:** Rows 17 and 18. Batch 3D Task 10.1 already specifies the single-candidate guard. This task is an audit verification at merge time.

- [ ] 10.1 After Batch 3D is merged, open `UI/ComparePopout.lua`. Locate the shift-click handler in `VotingFrame.lua` (the handler that calls `cp:Open`). Confirm the single-candidate guard exists and reads:

  ```lua
  if not nameB or nameB == name then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine("BobleLoot — Compare")
      GameTooltip:AddLine(
          "Need at least two scored candidates to compare.", 1, 0.5, 0.5)
      GameTooltip:Show()
      C_Timer.After(2, function() GameTooltip:Hide() end)
      return
  end
  ```

- [ ] 10.2 Verify the same guard fires when `nameB == name` (the user shift-clicks the top-ranked candidate). The `nameB` derivation logic must exclude `name` from the "top candidate" lookup.

- [ ] 10.3 If the guard message text differs from "Need at least two scored candidates to compare.", update to match. This is the canonical wording specified in the audit inventory (Row 17).

**Verification:** Open a voting session with only one candidate. Shift-click the score cell. Confirm a `GameTooltip` appears for 2 seconds with the specified text, then auto-hides.

**Commit:** (No code change if 3D is correct; otherwise a fixup commit on the 3D branch or a follow-up on the feature branch.)

---

## Task 11 — `Scoring.lua` / `UI/ExplainPanel.lua`: score trend tooltip empty state (pending Batch 3B + 3D/3E)

**Files:** `UI/ExplainPanel.lua` (Batch 2D); `Scoring.lua` (Batch 3B)

**Gap addressed:** Row 25. Batch 3B defines `GetScoreTrend` and documents "0 or 1 entries → UI shows 'Not enough data'". The Explain Panel (or the voting-frame tooltip, depending on where the trend sparkline is surfaced) must implement this guard.

- [ ] 11.1 After Batch 3B and Batch 2D are merged, open `UI/ExplainPanel.lua`. Locate the trend-summary section (where `ns.Scoring:GetTrendSummary(name, profile)` is called). Before rendering any trend text, add:

  ```lua
  local trend = ns.Scoring:GetScoreTrend(name, itemID,
                    addon.db.profile.trendHistoryDays or 28,
                    addon.db.profile)
  if not trend or #trend <= 1 then
      -- Not enough data for a trend line.
      AddLine("|cff666666No score history for this item yet.|r",
              T.muted[1], T.muted[2], T.muted[3])
  else
      -- Render sparkline / trend delta here (full implementation in 3D/3E).
      local summary = ns.Scoring:GetTrendSummary(name, addon.db.profile)
      if summary then
          local sign = summary.delta >= 0 and "+" or ""
          AddLine(string.format(
              "|cffaaaaaaScore trend: %s%.1f over %d days|r",
              sign, summary.delta, summary.count),
              T.muted[1], T.muted[2], T.muted[3])
      end
  end
  ```

- [ ] 11.2 When the trend section is rendered inside the voting-frame tooltip (`fillScoreTooltip`), apply the same guard: check `#trend <= 1` before rendering; show "No score history for this item yet." otherwise.

**Verification:** Open a voting session for an item with no prior score history. Confirm the Explain Panel shows "No score history for this item yet." in muted grey (not a blank line, not a zero-delta trend).

**Commit:** `feat(ExplainPanel): show no-history message when score trend has < 2 data points`

---

## Task 12 — Coordination audit: verify Batch 4D RC-banner text and 4C version-info degradation

**Files:** `UI/SettingsPanel.lua`

**Gaps addressed:** Rows 9 and 10 (verify-text).

- [ ] 12.1 After Batch 4D is merged, open `UI/SettingsPanel.lua`. Search for the RC-not-detected banner `FontString`. Confirm its text is set to exactly:

  ```
  |cffff5555RCLootCouncil not detected. Score column will appear once RC loads.|r
  ```

  This string is the roadmap 4.10 canonical wording. No abbreviation is acceptable.

- [ ] 12.2 After Batch 4C is merged, confirm the three RC-version-compat states exist in `BuildDataTab`:
  - Green text when detected version matches tested matrix entry.
  - Yellow text when detected version is newer than the highest tested entry.
  - Red text when detected version is unsupported (below lowest tested entry or parse failure).
  - When RC is not detected at all (4.10 banner is showing), confirm the version-compat line is hidden or suppressed rather than showing a stale cached value.

- [ ] 12.3 Confirm that the vertical layout in `BuildDataTab` after all merged batches is:
  1. Dataset info label (generatedAt, character count)
  2. Broadcast + Team URL buttons
  3. RC version-compat line (Batch 4C)
  4. RC-not-detected banner (Batch 4D, hidden when RC is present)
  5. Transparency card

  If the merge order produces a different layout, re-anchor the frames using `SetPoint` offsets so the order matches this spec.

**Verification:** Test with RC absent (confirm banner shows, version-compat line hidden). Test with RC present at tested version (confirm green version line, no banner). Test with RC present at a newer untested version (confirm yellow version line).

**Commit:** `fix(SettingsPanel): anchor Data-tab layout after 4C/4D merges; verify banner text`

---

## Task 13 — Coordination audit: Bench-mode and LootDB-tab empty states

**Files:** `Core.lua`, `UI/SettingsPanel.lua`

**Gaps addressed:** Rows 28 and 29.

- [ ] 13.1 Open `Core.lua`. Locate the `/bl benchscore` slash handler. Find the guard that checks for an active RC voting session. Confirm it prints to chat when no session is active. The message should read: `"No active voting session. Open a voting session in RC first."`. If absent, add:

  ```lua
  if not (ns.VotingFrame and ns.VotingFrame.rcVoting
          and ns.VotingFrame.rcVoting.GetCurrentSession
          and ns.VotingFrame.rcVoting:GetCurrentSession()) then
      addon:Print("No active voting session. Open a voting session in RC first.")
      return
  end
  ```

- [ ] 13.2 Open `UI/SettingsPanel.lua`. Locate `BuildLootDBTab` (or the equivalent tab body function). Find the `lastScanned` / `lastMatched` display. Confirm that when both values are 0, the tab shows a muted hint. If `LootHistory.lastScanned == 0` and no hint is shown, add:

  ```lua
  if (ns.LootHistory and ns.LootHistory.lastScanned or 0) == 0 then
      scanHintLbl:SetText("|cff888888No RC loot history found.|r")
      scanHintLbl:Show()
  else
      scanHintLbl:Hide()
  end
  ```

  (Substitute `scanHintLbl` with the actual label widget reference in the implementation.)

**Verification (Row 29):** Run `/bl benchscore` with no RC voting session open. Confirm the chat message "No active voting session. Open a voting session in RC first." appears.

**Verification (Row 28):** Clear `RCLootCouncilLootDB` (rename SavedVars file, `/reload`). Open Settings > LootDB tab. Confirm "No RC loot history found." appears in muted grey.

**Commit:** `feat(Core+SettingsPanel): bench-mode no-session message; LootDB empty-state hint`

---

## Manual Verification Guided Tour

This section is the deliverable for QA. It lists every empty/error state, the exact trigger to induce it, and the expected rendering. Perform these tests in order on a freshly reloaded addon after all tasks are applied.

---

### State 1 — Score cell: candidate not in dataset

**Trigger:** Open a voting session for any item. Ensure one candidate is named `"Fake-Realm"` (fabricated by test mode), who does not exist in `BobleLoot_Data.characters`.

**Expected rendering:** Score cell shows `—` (em-dash) in muted grey (`#888888` approximately). Hover the cell: tooltip reads `"[Name] is not in the BobleLoot dataset. Run tools/wowaudit.py and /reload."`

---

### State 2 — Score cell: candidate in dataset, all components nil

**Trigger:** Open Settings > Weights tab. Toggle all five components off. Open a voting session. All cells for candidates who ARE in the dataset now show `?`.

**Expected rendering:** Score cell shows `?` in muted grey. Hover: tooltip reads "No scoreable components for this candidate/item." (The header and name line still render; only the breakdown rows are absent.)

Restore weights after this test.

---

### State 3 — History viewer: filtered zero entries

**Trigger:** Run `/bl history`. Apply a player filter for a name that has received no loot, or narrow the date slider to 1 day on a night with no recorded loot.

**Expected rendering:** Scrollable area is blank except for a centred muted-grey paragraph reading: "No loot entries match the current filters. Try widening the date window or check that RC loot history has been recorded."

---

### State 4 — History viewer: unfiltered zero entries (RC loot DB empty)

**Trigger:** Rename `RCLootCouncilSavedVars.lua` to a different name, `/reload`. Run `/bl history` with no filters.

**Expected rendering:** Scrollable area shows centred muted-grey paragraph: "No loot history found. RC loot history is recorded while you are in a raid using RCLootCouncil."

Restore SavedVars file after this test.

---

### State 5 — Toast: sync timeout

**Trigger:** Run `/run BobleLoot:SendMessage("BobleLoot_SyncTimedOut", "TestSender")`.

**Expected rendering:** Toast appears at top-centre of screen with yellow tint (warning level). Text reads exactly: `"Dataset sync timed out — using local data."` Toast fades in over 0.2s, holds 3s, fades out over 0.5s.

---

### State 6 — Toast: no events queued (invisible by design)

**Trigger:** No events fired since last toast completed fade-out.

**Expected rendering:** Toast frame is hidden at alpha 0. No visual artifact. This is the design intent — document only, no test action required.

---

### State 7 — Settings Data tab: RC not detected

**Trigger:** Disable or unload RCLootCouncil (rename its folder, `/reload`). Wait 10 seconds after addon load.

**Expected rendering:** Settings > Data tab shows a prominent red banner reading `"|cffff5555RCLootCouncil not detected. Score column will appear once RC loads.|r"` (exact string). Dataset info label, broadcast button, and version-compat line are still visible below the banner. Transparency card is present but toggle is disabled with muted hint.

Restore RCLootCouncil after this test.

---

### State 8 — Settings Data tab: RC version newer than tested

**Trigger:** Temporarily edit `RCCompat.lua` to shift the tested version range below the actual installed RC version (e.g., set the highest tested major to an old number).

**Expected rendering:** Settings > Data tab version-compat line shows yellow text: "Tested on RC %s, detected %s — newer than tested." RC-not-detected banner is hidden.

---

### State 9 — Settings Data tab: transparency toggle when not group leader

**Trigger:** Log in as a non-leader in a group. Open Settings > Data tab.

**Expected rendering:** "Enabled (raid leader only)" checkbox is greyed out (disabled). The hint label below reads "Only the raid/group leader can change this. Current state is synced from the leader automatically." in muted grey. Hover the disabled checkbox: tooltip appears reading "Only the raid leader can toggle transparency mode."

---

### State 10 — Settings Test tab: RC not loaded

**Trigger:** Disable RCLootCouncil, `/reload`. Open Settings > Test tab.

**Expected rendering:** "Run test session" button is grey (disabled). Amber text below reads "RCLootCouncil is not loaded. The test session requires RC." Hover the disabled button: tooltip appears reading "RCLootCouncil must be loaded to run a test session."

---

### State 11 — Settings Test tab: RC loaded, player not leader

**Trigger:** Log in as non-leader in a group with RC active. Open Settings > Test tab.

**Expected rendering:** "Run test session" button is grey (disabled). Amber text below reads "You must be the group leader (or solo) to start a test session." Hover the disabled button: tooltip appears with the same message.

---

### State 12 — Settings Weights tab: all components disabled

**Trigger:** Open Settings > Weights tab. Toggle all five component checkboxes off.

**Expected rendering:** All five sliders show 0. Example score row shows "0.0 / 100". A muted grey label appears below the example row: "All components disabled — enable at least one."

---

### State 13 — Minimap button: no dataset loaded

**Trigger:** Rename or remove `BobleLoot_Data.lua`, `/reload`. Hover the minimap icon.

**Expected rendering:** Tooltip line reads "No dataset loaded — run tools/wowaudit.py" in muted grey (below the "Boble Loot" title line). Loot history and transparency lines still render below.

---

### State 14 — Comparison popout: only one candidate in session

**Trigger:** Open a test voting session with `testItemCount = 1` (one item, one candidate). Shift-click the score cell.

**Expected rendering:** A `GameTooltip` appears reading:
- Title: "BobleLoot — Compare"
- Body: "Need at least two scored candidates to compare." in pinkish-red
The tooltip auto-hides after 2 seconds. The ComparePopout frame does NOT open.

---

### State 15 — Explain panel: no active session (itemID = 0)

**Trigger:** Ensure no voting session is open. Run `/bl explain YourName-Realm`.

**Expected rendering:** Explain panel frame opens. Title bar reads "BobleLoot — Explain: YourName-Realm". Content area shows three muted-grey lines:
1. "No scoring data for this item."
2. "Open a voting session in RC first,"
3. "then use /bl explain <Name-Realm>."

---

### State 16 — Explain panel: candidate not in dataset

**Trigger:** Open a voting session. Right-click a candidate who is not in the dataset.

**Expected rendering:** Panel shows candidate name in muted grey, then "(not in BobleLoot dataset — run tools/wowaudit.py and /reload)" in muted grey. No breakdown rows.

---

### State 17 — Explain panel: in dataset, score is nil

**Trigger:** Temporarily set all weights to 0. Open a voting session. Right-click a candidate who IS in the dataset.

**Expected rendering:** Panel shows candidate name in gold and `"no data"` in red for the score. Below: "No scoreable components for this candidate/item." in red. No breakdown rows.

---

### State 18 — Transparency label: player not in dataset

**Trigger:** Load a dataset that does not include your character. Enable transparency mode (as leader). Open the RC loot frame.

**Expected rendering:** Transparency label shows "BL: —" (em-dash) in muted grey. Hover the loot-frame entry: tooltip reads "[YourName] is not in the BobleLoot dataset. Run tools/wowaudit.py and /reload."

---

### State 19 — Transparency label: in dataset, score is nil

**Trigger:** Set all weights to 0. Enable transparency mode. Open RC loot frame.

**Expected rendering:** Transparency label shows "BL: ?" in muted grey. Hover the entry: tooltip reads "No scoring data for this item. All score components returned no data."

---

### State 20 — Score trend: no history yet

**Trigger:** Open a voting session for an item that has never been scored in a previous session (fresh install, or an item ID that has never appeared in the voting frame while trend tracking was enabled). Open the Explain Panel for a candidate.

**Expected rendering:** The trend section in the Explain Panel shows "No score history for this item yet." in muted grey (not a blank line, not a zero-delta trend line).

---

### State 21 — Bench-mode: no active session

**Trigger:** Ensure no voting session is open. Run `/bl benchscore`.

**Expected rendering:** Chat message: "[BobleLoot] No active voting session. Open a voting session in RC first."

---

### State 22 — LootDB tab: no RC loot history

**Trigger:** Clear `RCLootCouncilSavedVars.lua`, `/reload`. Open Settings > LootDB tab.

**Expected rendering:** Scan counts show 0/0. A muted hint reads "No RC loot history found." below the counts.

---

## Design Principles for Future Empty States

When adding a new UI surface after Batch 4E, follow these conventions:

1. **Every frame body has an empty state.** Before shipping a new scrollable table, list, or dynamic content area, explicitly decide what it shows at zero rows. A `FontString` centred in the content frame is the standard solution. Do not rely on "the frame is blank" as an acceptable state.

2. **Distinguish causes.** If a zero-entry state can have multiple causes (filters vs. genuinely empty source), show different messages for each. The user's action differs: "widen filters" vs. "check your pipeline."

3. **Every disabled control has a tooltip.** If a button, checkbox, or slider is disabled, add an `OnEnter` tooltip that explains why. The reason label below the control is complementary, not a substitute — tooltips are the documentation (cross-cutting principle #3).

4. **Missing data uses `—`, no data uses `?`.** `—` (em-dash) means "this entity is not present in the dataset at all." `?` means "the entity is present but computing a value was not possible." Never leave either state as a blank.

5. **`Theme.muted` for informational empty states, `Theme.warning` for actionable problems, `Theme.danger` for errors.** An empty list is informational (muted). A missing dataset is actionable (warning, with instruction). An unsupported RC version is an error (danger).

6. **Toasts are fire-and-forget; they do not accumulate.** The toast system holds one message at a time; a subsequent event overwrites the current one in-place. New event types wired to Toast must be `warning` or `error` level — never `success` for a failure event.

7. **Exact text strings are part of the spec.** The wording in this plan's inventory table is canonical. If implementation shortens or rephrases a message, update the text to match before shipping. Users who search forums for error text will find the canonical wording.

8. **Document invisible states.** States that are correctly invisible (toast queue empty, item-ID-nil cell blank) should be documented in the plan as "invisible by design" so future developers do not add spurious content to them.

---

## Coordination Notes

This plan audits surfaces introduced by the following upstream plans. For each, the relationship is noted.

**Batch 1D (`2026-04-22-batch-1d-score-cell-tooltip-plan.md`)**
Introduced the three score-cell states: `—` (not in dataset), `0` (confirmed zero), numeric (scored). This plan adds the fourth state: `?` (in dataset, nil score). Task 1 patches the `formatScore` function and verifies the tooltip coverage.

**Batch 1E (`2026-04-22-batch-1e-ui-overhaul-plan.md`)**
Introduced `UI/MinimapButton.lua`, `UI/SettingsPanel.lua` (all five tabs), `UI/Theme.lua`. This plan audits: minimap dataset-missing tooltip (Task 3), Test tab Run button tooltip (Task 4), Weights tab all-disabled note (Task 5), Data tab transparency-toggle tooltip (Task 6).

**Batch 2C (`2026-04-23-batch-2c-chunked-sync-plan.md`)**
Fires `BobleLoot_SyncTimedOut` from `Sync:_onChunkTimeout`. This plan wires that event to Toast in Task 8.

**Batch 2D (`2026-04-23-batch-2d-score-explanation-panel-plan.md`)**
Introduced `UI/ExplainPanel.lua` with `RenderContent`. Already handles not-in-dataset and nil-score states. This plan adds the `itemID = 0` early-exit state (Task 9) and audits existing message text.

**Batch 3B (`2026-04-23-batch-3b-history-features-plan.md`)**
Defines `GetScoreTrend` with the "0 or 1 entries → show no-history message" contract. This plan specifies the exact wording ("No score history for this item yet.") and the implementation location (Task 11).

**Batch 3D (`2026-04-23-batch-3d-council-decision-ui-plan.md`)**
Introduced `UI/ComparePopout.lua` and the single-candidate guard in Task 10.1. This plan audits that guard's exact text (Task 10) after 3D is merged.

**Batch 3E (`2026-04-23-batch-3e-viewer-surfaces-plan.md`)**
Introduced `UI/HistoryViewer.lua` and `UI/Toast.lua`. This plan adds the zero-entries help text to HistoryViewer (Task 7) and verifies/adds the `BobleLoot_SyncTimedOut` wire-up in Toast (Task 8).

**Batch 4C (`2026-04-23-batch-4c-rc-version-compat-plan.md`)**
Adds the RC version-compat info line to the Data tab. This plan audits that the three color states exist and that the line degrades when RC is absent (Task 12).

**Batch 4D (`2026-04-23-batch-4d-ui-polish-plan.md`)**
Adds the RC-not-detected banner and the colorblind-mode dropdown. This plan audits the banner text (Task 6, Task 12) and verifies the dropdown's first entry degrades cleanly when only one mode is defined.

---

*Plan authored 2026-04-23. Roadmap reference: item 4.12 in `docs/superpowers/specs/2026-04-22-bobleloot-year-one-roadmap-design.md`.*
