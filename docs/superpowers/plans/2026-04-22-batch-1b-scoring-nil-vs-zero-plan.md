# Batch 1B — Scoring Nil-vs-Zero Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix `Scoring:Compute` so a candidate whose sim value for an item is genuinely `0.0` (a confirmed non-upgrade) scores low on the sim component instead of being silently dropped from scoring entirely.

**Architecture:** The root cause is that `simComponent` uses `nil` for two distinct situations — "no sim data exists for this item" and "sim data exists and the value is zero" — because `char.sims[itemID]` returns `nil` in both cases (missing key vs. stored `0`). The fix adds a `char.simsKnown` set to the data file: if `simsKnown[itemID]` is `true`, the character has been simmed for that item and the value in `char.sims[itemID]` (even if absent/zero) is authoritative. `simComponent` consults `simsKnown` first and returns `0.0` rather than `nil` when the item is known but the upgrade percentage is zero or absent. `Scoring:Compute` then only hard-returns `nil` for candidates where the item is genuinely unknown — which is the semantically correct "no data" gate.

**Tech Stack:** Lua (WoW addon), manual in-game verification via `TestRunner.lua`

**Roadmap items covered:** 1.2

> **Full text of roadmap item 1.2:**
>
> `simComponent` returns `nil` when `char.sims[itemID]` is nil and `0.0`
> when the value is literally zero. `Scoring:Compute` currently treats
> both identically, dropping a player who genuinely simmed zero out of
> the council score. Fix by distinguishing "no data" from "data is zero"
> using a separate `char.simsKnown` set or a sentinel.

---

## Design choice: `simsKnown` set over sentinel

Two options were available:

- **Sentinel value** — store `char.sims[itemID] = -1` (or `false`) when a sim result of zero is known. Pro: no new field. Con: the sentinel leaks into every consumer of `sims`, requires documentation everywhere, and breaks any code that treats the `sims` table as a plain number map.
- **`simsKnown` set** — store `char.simsKnown = { [itemID] = true }` alongside `char.sims`. Pro: the meaning is unambiguous — `simsKnown[itemID]` answers "was this item ever simmed?" independently of the numeric value. Con: one additional field in the data file.

This plan uses **`simsKnown`**. It is explicit, additive, and puts zero interpretive burden on future readers of `Scoring.lua`. The Python emitter (`wowaudit.py`) must emit this field; that work belongs to plan 1A.

---

## File structure

| File | Role in this fix |
|---|---|
| `Scoring.lua` | Primary change target. `simComponent` gains a `simsKnown` consult. `Scoring:Compute` gains an invariant comment. |
| `Data/BobleLoot_Data.example.lua` | Updated to show the new `simsKnown` field so future contributors know the expected shape. |
| `Data/BobleLoot_Data.lua` | Runtime data file (gitignored). Must be regenerated via `wowaudit.py` (plan 1A) or hand-edited for manual testing per Task 1. |

Files explicitly not touched: `VotingFrame.lua`, `LootFrame.lua`, `Sync.lua`, `Core.lua`, `tools/wowaudit.py`.

---

## Task 1 — Reproduce the bug in-game

**Purpose:** Establish a concrete failing case before touching any code. This is the baseline that Task 3 will verify is now fixed.

**Files:**
- `E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/Data/BobleLoot_Data.lua` (hand-edit for test, lines 1–end)

**Steps:**

- [ ] 1.1 — Open `BobleLoot_Data.lua` in a text editor. Add (or replace) a test character entry that has `simsKnown` absent (old shape) and a `sims` entry of `0` for item `212401`. The entry should look exactly like this (use a real character name already on your roster so the RC voting frame shows them as a candidate):

    ```lua
    ["Testchar-Realm"] = {
        attendance    = 100.0,
        mplusDungeons = 10,
        bis           = {},
        sims          = { [212401] = 0 },   -- confirmed 0% upgrade
    },
    ```

    This reproduces the ambiguity: `char.sims[212401]` is `0` (falsy in Lua — `if pct == nil` is `false`, but the value is zero, so `simComponent` returns `0.0, 0`). Actually re-read the current code path to confirm the exact failure point (see Step 1.2).

- [ ] 1.2 — Trace the actual failure path in `Scoring.lua` lines 21–35 against the test entry above:

    - `char.sims` exists, so line 22 does not return nil.
    - `pct = char.sims[212401]` = `0`.
    - `pct == nil` is `false`, so the nil guard on line 24 does not return nil.
    - `simReference` is provided (cross-bidder max), say `5.0`.
    - `return clamp01(0 / 5.0), 0` = `0.0, 0`. This is correct — `simVal` is `0.0`.
    - In `Scoring:Compute` line 102: `(weights.sim or 0) > 0 and simVal == nil` — `simVal` is `0.0`, not `nil`, so this guard does NOT fire.
    - `Scoring:Compute` proceeds normally; the candidate scores with sim contributing `0.0`.

    Conclusion: the `sims = { [212401] = 0 }` case is actually handled correctly by the existing code. **The real bug fires when `sims[itemID]` is `nil` but the item WAS simmed (the result happened to be zero and `wowaudit.py` omitted the key rather than writing `0`).** Confirm this by creating a second test entry with NO key at all for the item:

    ```lua
    ["Testchar2-Realm"] = {
        attendance    = 100.0,
        mplusDungeons = 10,
        bis           = {},
        sims          = {},   -- wowaudit.py omitted the key because the sim was 0%
    },
    ```

    For `Testchar2-Realm`: `pct = char.sims[212401]` = `nil`. Line 24 fires: `return nil`. Back in `Scoring:Compute`: `simVal == nil` and `(weights.sim or 0) > 0`, so line 102–104 fires: `return nil`. Candidate silently dropped.

- [ ] 1.3 — Log in to WoW, `/reload`, then run:

    ```
    /bl score 212401 Testchar-Realm
    /bl score 212401 Testchar2-Realm
    ```

    Expected pre-fix output:
    - `Testchar-Realm` prints a non-nil score (sim component = 0.0 contributes 0 points, other components contribute normally).
    - `Testchar2-Realm` prints nothing or `nil` — the candidate is dropped entirely.

    Record both outputs. This is the baseline for Task 3.

- [ ] 1.4 — Commit nothing. This task is observation only.

---

## Task 2 — Implement the fix

**Purpose:** Make `simComponent` distinguish "item not simmed" from "item simmed, result was zero" using the `simsKnown` set.

**Files:**
- `E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/Scoring.lua` — lines 21–35 (`simComponent`), lines 97–104 (`Scoring:Compute` guard)
- `E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/Data/BobleLoot_Data.example.lua` — lines 1–17

**Steps:**

- [ ] 2.1 — Replace the `simComponent` function in `Scoring.lua` (lines 21–35) with the following:

    ```lua
    local function simComponent(char, itemID, simReference)
        if not char.sims then return nil end
        -- simsKnown is a set of itemIDs for which a sim result exists in the
        -- dataset, even if that result is zero. Without it, an omitted key
        -- (wowaudit.py didn't write zero-value entries) is indistinguishable
        -- from "item was never simmed for this character."
        --
        -- Invariant: if simsKnown[itemID] is true, the sim result is known and
        -- authoritative; char.sims[itemID] may be nil (treat as 0.0) or a
        -- non-negative percentage. If simsKnown is absent or simsKnown[itemID]
        -- is falsy, the item has no sim data — return nil (no-data sentinel).
        local known = char.simsKnown and char.simsKnown[itemID]
        local pct   = char.sims[itemID]
        if pct == nil and not known then return nil end
        -- Item is known (simsKnown[itemID] = true) OR pct is an explicit value.
        -- Either way we have a result; coerce nil to 0.0.
        pct = pct or 0.0
        if simReference and simReference > 0 then
            return clamp01(pct / simReference), pct
        end
        return pct / 100, pct
    end
    ```

    Key behavioural changes:
    - `pct == nil AND not known` — returns `nil` (no sim data, old behaviour preserved for truly absent characters).
    - `pct == nil AND known` — returns `0.0` (sim ran, result was zero; old code returned `nil` here, which was the bug).
    - `pct ~= nil` — returns the existing calculation unchanged (no regression for normal cases).

- [ ] 2.2 — The `Scoring:Compute` guard at lines 97–104 does not need to change. Its semantics are already correct: "if sim weight is active and we have no sim data (`simVal == nil`), exclude this candidate." After the fix, `simVal` will only be `nil` when the item is genuinely untracked in the dataset — which is the correct exclusion case. Leave the guard as-is.

- [ ] 2.3 — Update `Data/BobleLoot_Data.example.lua` to document the new field. Replace the file content with:

    ```lua
    -- EXAMPLE data file. Copy to BobleLoot_Data.lua or generate via tools/wowaudit.py.
    -- The real BobleLoot_Data.lua is gitignored because it contains your guild's roster data.
    BobleLoot_Data = {
        generatedAt = "1970-01-01T00:00:00Z",
        teamUrl     = "https://wowaudit.com/eu/<region>/<realm>/<team>",
        simCap      = 5.0,
        mplusCap    = 60,
        historyCap  = 5,
        characters  = {
            ["Examplechar-Examplerealm"] = {
                attendance    = 100.0,
                mplusDungeons = 0,
                bis      = { [12345] = true },
                sims     = { [12345] = 1.23 },
                -- simsKnown lists every itemID for which a sim result was
                -- fetched, including items whose result was 0%. This allows
                -- Scoring.lua to distinguish "sim was zero" from "item was
                -- never simmed" — see Batch 1B plan for rationale.
                simsKnown = { [12345] = true },
            },
        },
    }
    ```

- [ ] 2.4 — Update the hand-crafted test entry in `BobleLoot_Data.lua` for `Testchar2-Realm` to include the `simsKnown` field (simulating what `wowaudit.py` will emit after plan 1A):

    ```lua
    ["Testchar2-Realm"] = {
        attendance    = 100.0,
        mplusDungeons = 10,
        bis           = {},
        sims          = {},              -- 0% upgrade; key omitted by wowaudit.py
        simsKnown     = { [212401] = true },  -- but we know this item was simmed
    },
    ```

- [ ] 2.5 — Commit the Lua changes:

    ```
    git add Scoring.lua Data/BobleLoot_Data.example.lua
    git commit -m "$(cat <<'EOF'
    Fix Scoring nil-vs-zero: use simsKnown set to distinguish no-data from zero-sim

    simComponent now checks char.simsKnown[itemID] before treating a nil sims
    entry as absent. A known-zero sim returns 0.0 instead of nil, so candidates
    with a confirmed 0% upgrade score low on the sim component rather than being
    dropped from scoring entirely. Example data file updated to document the new
    field shape. Roadmap item 1.2.
    EOF
    )"
    ```

---

## Task 3 — Verify the fix in-game

**Purpose:** Confirm the reproducer from Task 1 now behaves correctly.

**Files:**
- `E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/Data/BobleLoot_Data.lua` — test entries from Task 1 still present

**Steps:**

- [ ] 3.1 — Log in to WoW (or type `/reload` if already logged in). Confirm the addon loads without Lua errors in the chat frame or via `/console scriptErrors 1`.

- [ ] 3.2 — Run both score commands from Task 1:

    ```
    /bl score 212401 Testchar-Realm
    /bl score 212401 Testchar2-Realm
    ```

    Expected post-fix output:
    - `Testchar-Realm` — same non-nil score as before (no regression).
    - `Testchar2-Realm` — now also returns a non-nil score. The sim component should appear in the breakdown with `value = 0.0`, contributing `0` points but not suppressing the candidate. The overall score is driven by attendance, M+, etc. alone (sim contributes 0, BiS contributes whatever `partialBiSValue` yields).

- [ ] 3.3 — Verify the score tooltip for `Testchar2-Realm` shows the sim component at 0% (or 0 pts) rather than the component being absent from the breakdown entirely. Use the voting frame's score column tooltip or the `/bl score` chat output, whichever surfaces the breakdown.

- [ ] 3.4 — Confirm the nil-data path still works correctly: add a third test entry with no `simsKnown` at all and a missing sim key, then run `/bl score 212401 Testchar3-Realm`. The candidate should still return `nil` (dropped) when `weights.sim > 0` and there is genuinely no sim data.

    ```lua
    ["Testchar3-Realm"] = {
        attendance    = 100.0,
        mplusDungeons = 10,
        bis           = {},
        sims          = {},   -- no simsKnown, no entry — truly unsimmed
    },
    ```

    ```
    /bl score 212401 Testchar3-Realm
    ```

    Expected: no score returned (nil), confirming the exclusion gate is still correctly enforced for genuinely absent data.

- [ ] 3.5 — Remove the temporary test entries from `BobleLoot_Data.lua` (it is gitignored, so nothing to commit). The file can be left empty or restored to a prior state.

---

## Task 4 — Add maintainer invariant documentation to `Scoring.lua`

**Purpose:** Prevent future regressions by making the nil-vs-zero contract explicit at the top of the file where any future maintainer will see it.

**Files:**
- `E:/Games/World of Warcraft/_retail_/Interface/AddOns/BobleLoot/Scoring.lua` — lines 1–7 (module header comment)

**Steps:**

- [ ] 4.1 — Replace the existing module header comment in `Scoring.lua` (lines 1–7) with the expanded version below:

    ```lua
    --[[ Scoring.lua
         Pure-ish scoring logic. Takes (itemID, candidateName, profile, data)
         and returns (score 0..100, breakdown table).

         A component is dropped (and its weight redistributed) when the
         underlying data is missing for that candidate.

         NIL-VS-ZERO INVARIANT (Batch 1B, 2026-04-22)
         -----------------------------------------------
         simComponent returns nil ONLY when the item was never simmed for
         this character (i.e. char.simsKnown[itemID] is falsy AND
         char.sims[itemID] is nil).  A genuinely-zero sim result returns
         0.0, not nil.

         The data file encodes this via two parallel structures:
           char.sims[itemID]      -- numeric upgrade %, may be absent if 0
           char.simsKnown[itemID] -- true iff wowaudit.py fetched a result
                                  --   for this item (even a 0% result)

         Scoring:Compute hard-returns nil for a candidate when sim weight
         is active and simComponent returns nil. This means: "we have no
         idea whether this item is an upgrade, so it would be misleading
         to rank this candidate against others who have been simmed."
         It does NOT mean "sim is zero" — that case must score, just low.

         Do not collapse simsKnown into sims using a sentinel (e.g. -1).
         The sims table is a plain number map; sentinels require every
         consumer to know about them. Keep the tables separate.
    ]]
    ```

- [ ] 4.2 — Commit:

    ```
    git add Scoring.lua
    git commit -m "$(cat <<'EOF'
    Add nil-vs-zero invariant docs to Scoring.lua module header

    Documents the simsKnown contract so a future maintainer cannot
    accidentally collapse the two cases back to a single nil return.
    Roadmap item 1.2.
    EOF
    )"
    ```

---

## Manual verification checklist

Run this checklist against the patched build before tagging v1.1.

- [ ] Fresh `/reload` with a clean addon cache — no Lua errors on startup.
- [ ] `BobleLoot_Data.lua` contains at least one character with `simsKnown = { [itemID] = true }` and no corresponding key in `sims` (the zero-sim case).
- [ ] `/bl score <itemID> <ZeroSimChar-Realm>` returns a non-nil score.
- [ ] The returned breakdown includes a `sim` component with `value = 0` and `contribution = 0`.
- [ ] The score tooltip (hover over the score column in the RC voting frame) shows the sim component at 0 pts, not absent from the breakdown.
- [ ] `/bl score <itemID> <TrulyUnsimmedChar-Realm>` (character with no `simsKnown` entry for the item) still returns nil when `weights.sim > 0`.
- [ ] A character with a normal positive sim value (e.g. `sims = { [itemID] = 3.5 }`, `simsKnown = { [itemID] = true }`) scores identically before and after the patch (no regression on the happy path).
- [ ] RC voting frame: start a test session via `/tr 1` or `/bl test`, confirm the zero-sim candidate appears in the score column with a low but non-nil score.

---

## Data-side coordination note

`wowaudit.py` (owned by plan 1A) must emit the `simsKnown` set for every character in `build_lua`. For each character whose wishlists were fetched, after constructing `char["sims"]`, emit a parallel `char["simsKnown"] = { [itemID] = true, ... }` containing every itemID that was present in the API response, regardless of whether the percentage was zero. Items absent from the API response (item not on the wishlist at all, or wishlist fetch failed for this character) must not appear in `simsKnown` — that absence is what tells Lua the item is genuinely unsimmed. See plan 1A for the Python implementation details.

---

## Rollback

If this fix causes unexpected regressions (e.g. a candidate with a zero sim is now scored when council policy says they should be excluded), revert is a single `git revert` of the two commits from Tasks 2 and 4. The invariant comment in the module header names the exact commits and the design rationale, so any future bisect will immediately surface the relevant context. No other files are affected: `VotingFrame.lua`, `LootFrame.lua`, and `Sync.lua` never read `simsKnown` directly — they consume the `breakdown` table that `Scoring:Compute` returns, which is unchanged in shape.
