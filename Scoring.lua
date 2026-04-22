--[[ Scoring.lua
     Pure-ish scoring logic. Takes (itemID, candidateName, profile, data)
     and returns (score 0..100, breakdown table).

     A component is dropped (and its weight redistributed) when the
     underlying data is missing for that candidate.
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
    local pct = char.sims[itemID]
    if pct == nil then return nil end
    -- Per-item comparative normalization: if a reference max (= the
    -- highest sim percentage for this item among the current bidders)
    -- is provided, scale value to [0..1] against that. The bidder with
    -- the biggest upgrade gets 1.0, others scaled proportionally.
    if simReference and simReference > 0 then
        return clamp01(pct / simReference), pct
    end
    -- No reference (e.g. /bl score from chat): fall back to raw fraction
    -- so the score is at least monotonic in the upgrade size.
    return pct / 100, pct
end

local function bisComponent(char, itemID, partial)
    if not char.bis then return partial, nil end
    if char.bis[itemID] then return 1.0, true end
    return partial, false
end

local function historyComponent(char, historyCap)
    if char.itemsReceived == nil then return nil end
    if historyCap <= 0 then return 1, char.itemsReceived end
    return clamp01(1 - (char.itemsReceived / historyCap)), char.itemsReceived
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
    local simReference = opts and opts.simReference  -- max sim pct across bidders

    local simVal,  simRaw  = simComponent(char, itemID, simReference)
    local bisVal,  bisRaw  = bisComponent(char, itemID, profile.partialBiSValue or 0.25)
    local histVal, histRaw = historyComponent(char, historyCap)
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
