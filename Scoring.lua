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

local _, ns = ...
local Scoring = {}
ns.Scoring = Scoring

local function clamp01(x)
    if x < 0 then return 0 end
    if x > 1 then return 1 end
    return x
end

-- Normalize component values to 0..1 ----------------------------------------

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

local function bisComponent(char, itemID, partial)
    if not char.bis then return partial, nil end
    if char.bis[itemID] then return 1.0, true end
    return partial, false
end

-- Hybrid loot-equity model: denominator is the larger of (a) the
-- highest itemsReceived among current bidders and (b) the configured
-- soft floor. Pure relative would be cruel early-season when one
-- person has any loot; the floor keeps the score sane until someone
-- actually crosses it.
local function historyComponent(char, softFloor, historyReference)
    if char.itemsReceived == nil then return nil end
    local denom = softFloor or 0
    if historyReference and historyReference > denom then
        denom = historyReference
    end
    if denom <= 0 then return 1, char.itemsReceived end
    return clamp01(1 - (char.itemsReceived / denom)), char.itemsReceived
end

local function attendanceComponent(char)
    if char.attendance == nil then return nil end
    return clamp01(char.attendance / 100), char.attendance
end

local function mplusComponent(char, mplusCap)
    -- Backwards-compat: older data files used `mplusScore` (raider.io
    -- score). New ones use `mplusDungeons` (count of M+ dungeons done
    -- this season). Prefer the new field, fall back to the old.
    local v = char.mplusDungeons or char.mplusScore
    if v == nil then return nil end
    if mplusCap <= 0 then return 0, v end
    return clamp01(v / mplusCap), v
end

-- Public --------------------------------------------------------------------

-- Compute a 0..100 score for (itemID, candidateName).
-- Returns (score, breakdown) where breakdown is a table of
-- componentName -> { value=0..1, weight=effectiveWeight }.
-- Returns (nil, nil) if no character data exists at all.
function Scoring:Compute(itemID, candidateName, profile, data, opts)
    if not data or not data.characters then return nil end
    local char = data.characters[candidateName]
    if not char then return nil end

    local mplusCap   = (profile.overrideCaps and profile.mplusCap)   or data.mplusCap   or 40
    local historyCap = (profile.overrideCaps and profile.historyCap) or data.historyCap or 5
    local simReference     = opts and opts.simReference      -- max sim pct across bidders
    local historyReference = opts and opts.historyReference  -- max itemsReceived across bidders

    local simVal,  simRaw  = simComponent(char, itemID, simReference)
    local bisVal,  bisRaw  = bisComponent(char, itemID, profile.partialBiSValue or 0.25)
    local histVal, histRaw = historyComponent(char, historyCap, historyReference)
    local attVal,  attRaw  = attendanceComponent(char)
    local mpVal,   mpRaw   = mplusComponent(char, mplusCap)

    local weights = profile.weights or {}

    -- If sim weighting is enabled but this candidate has no sim data
    -- for this item, exclude them from scoring entirely. Otherwise
    -- weight redistribution would push everyone toward 100 from the
    -- remaining components, which is misleading when the item simply
    -- isn't an upgrade for them.
    if (weights.sim or 0) > 0 and simVal == nil then
        return nil
    end

    local components = {
        sim        = { value = simVal,  raw = simRaw,  reference = simReference },
        bis        = { value = bisVal,  raw = bisRaw                            },
        history    = { value = histVal, raw = histRaw, cap = historyCap,
                       reference = historyReference,
                       breakdown = char.itemsReceivedBreakdown                  },
        attendance = { value = attVal,  raw = attRaw                            },
        mplus      = { value = mpVal,   raw = mpRaw,   cap = mplusCap           },
    }

    local totalWeight, weighted = 0, 0
    local breakdown = {}

    for name, c in pairs(components) do
        local w = weights[name] or 0
        if c.value ~= nil and w > 0 then
            totalWeight = totalWeight + w
            weighted    = weighted + w * c.value
            breakdown[name] = {
                value = c.value, raw = c.raw, cap = c.cap,
                breakdown = c.breakdown, reference = c.reference, weight = w,
            }
        end
    end

    if totalWeight <= 0 then return nil end

    -- Renormalize so missing-data candidates are not unfairly penalized.
    local score = (weighted / totalWeight) * 100
    -- Fold the effective (renormalized) weight + per-component contribution
    -- (in score points out of 100) into the breakdown for UI.
    for _, entry in pairs(breakdown) do
        entry.effectiveWeight = entry.weight / totalWeight
        entry.contribution    = entry.effectiveWeight * entry.value * 100
    end
    return score, breakdown
end
