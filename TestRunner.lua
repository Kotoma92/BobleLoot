--[[ TestRunner.lua
     Drives RCLootCouncil's own test-mode loot session so users can
     verify the Boble Loot score column (and transparency mode) without
     waiting for real boss kills.

     Approach:
       * Pick a handful of itemIDs — preferring items that appear in the
         loaded BobleLoot dataset (so scores actually populate), falling
         back to a small built-in retail raid loot list.
       * Hand the list to RCLootCouncil:Test(itemIDs). RC opens its own
         voting frame, our VotingFrame.lua hook adds the Score column
         to it just like in a real raid, and any raider in the group
         with Boble Loot installed will see transparency-mode scores on
         their candidate frame.

     Notes:
       * RC requires the local player to be group leader (or solo) to
         open a test session, which matches our usual constraint.
       * No real loot is awarded; this is RC's test mode, not a Master
         Looter run.
]]

local _, ns = ...
local Test = {}
ns.TestRunner = Test

local DEFAULT_COUNT = 5

-- A small fallback set of retail raid itemIDs in case the BobleLoot data
-- file is empty / not yet loaded. These just need to be valid items
-- so RC can resolve their links; the score will be "-" if they're not
-- in your dataset.
local FALLBACK_ITEMS = {
    212401, 212402, 212403, 212404, 212405,
    212406, 212407, 212408, 212409, 212410,
}

-- To exercise the confirmed-zero score case:
--   1. In _G.BobleLoot_Data.characters, find any character entry.
--   2. Set char.sims = {} (empty, so simComponent returns nil).
--   3. Set char.bis = {} (not on BiS list -> partialBiSValue, e.g. 0.25).
--   4. Set char.itemsReceived = 999 (so historyComponent returns ~0).
--   5. Set char.attendance = 0, char.mplusDungeons = 0.
--   6. Run a test session; that character should show "0" not "-".
-- If weights.sim > 0 Scoring returns nil (excluded), so set weights.sim = 0
-- in db.profile.weights when testing this path.

local function shuffle(t)
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

-- Collect every itemID referenced by any character's sims/bis in the
-- currently loaded dataset.
local function itemsFromDataset()
    local data = ns.addon and ns.addon:GetData()
    if not data or not data.characters then return {} end
    local set = {}
    for _, char in pairs(data.characters) do
        if type(char.sims) == "table" then
            for itemID in pairs(char.sims) do
                if type(itemID) == "number" then set[itemID] = true end
            end
        end
        if type(char.bis) == "table" then
            for itemID in pairs(char.bis) do
                if type(itemID) == "number" then set[itemID] = true end
            end
        end
    end
    local out = {}
    for id in pairs(set) do out[#out + 1] = id end
    return out
end

local function pickItems(count, useDataset)
    count = math.max(1, math.min(20, tonumber(count) or DEFAULT_COUNT))
    local pool
    if useDataset then
        pool = itemsFromDataset()
        if #pool == 0 then pool = { unpack(FALLBACK_ITEMS) } end
    else
        pool = { unpack(FALLBACK_ITEMS) }
    end
    shuffle(pool)
    local picks = {}
    for i = 1, math.min(count, #pool) do picks[i] = pool[i] end
    return picks
end

local function getRC()
    local AceAddon = LibStub("AceAddon-3.0", true)
    if not AceAddon then return nil end
    local ok, RC = pcall(function() return AceAddon:GetAddon("RCLootCouncil", true) end)
    if not ok then return nil end
    return RC
end

-- ── Batch 3D: ComparePopout + Ghost Weights tests ────────────────────

BobleLoot.Test3D = {}

-- Opens the comparison popout with two hardcoded names for layout testing.
-- Call from chat: /run BobleLoot.Test3D.OpenCompare()
function BobleLoot.Test3D.OpenCompare()
    local cp = ns.ComparePopout
    if not cp then
        print("|cffff5555BobleLoot Test3D:|r ComparePopout module not loaded.")
        return
    end
    -- Use the first two characters from the dataset as test subjects.
    local data = BobleLoot:GetData()
    local nameA, nameB
    if data and data.characters then
        for n in pairs(data.characters) do
            if not nameA then nameA = n
            elseif not nameB then nameB = n
            end
            if nameA and nameB then break end
        end
    end
    nameA = nameA or "TestA-Realm"
    nameB = nameB or "TestB-Realm"
    local itemID = (function()
        -- Grab any itemID from the dataset.
        local d = BobleLoot:GetData()
        if d and d.characters then
            for _, c in pairs(d.characters) do
                if c.sims then
                    for id in pairs(c.sims) do return id end
                end
            end
        end
        return 0
    end)()
    print(string.format(
        "|cff33D9F2BobleLoot Test3D:|r Opening popout: %s vs %s on item %d",
        nameA, nameB, itemID or 0))
    cp:Open(nameA, nameB, itemID, nil, {})
end

-- Toggles ghost mode and prints the active state.
-- Call from chat: /run BobleLoot.Test3D.ToggleGhost()
function BobleLoot.Test3D.ToggleGhost()
    local VF = ns.VotingFrame
    if not VF then
        print("|cffff5555BobleLoot Test3D:|r VotingFrame module not loaded.")
        return
    end
    VF.SetGhostMode(not VF.ghostMode)
    print(string.format(
        "|cff33D9F2BobleLoot Test3D:|r Ghost mode is now: %s (preset: %s)",
        VF.ghostMode and "ACTIVE" or "OFF",
        (BobleLoot.db.profile.ghostPresets.activeGhostPreset or "farm")))
end

function Test:Run(addon, count, useDataset)
    local RC = getRC()
    if not RC then
        addon:Print("RCLootCouncil isn't loaded; cannot start a test session.")
        return
    end
    if type(RC.Test) ~= "function" then
        addon:Print("This RCLootCouncil version doesn't expose :Test(); cannot simulate.")
        return
    end

    if IsInGroup() and not UnitIsGroupLeader("player") then
        addon:Print("you must be the group leader (or solo) to start a test session.")
        return
    end

    local items = pickItems(count, useDataset ~= false)
    if #items == 0 then
        addon:Print("no items available to simulate.")
        return
    end

    addon:Print(string.format(
        "starting RCLootCouncil test session with %d item(s)%s.",
        #items, useDataset ~= false and " from the BobleLoot dataset" or ""))

    -- Newer RC builds accept a table of itemIDs/links; older builds
    -- accept a number. Prefer the table path; fall back to the count.
    local ok, err = pcall(RC.Test, RC, items)
    if not ok then
        local ok2, err2 = pcall(RC.Test, RC, #items)
        if not ok2 then
            addon:Print("RCLootCouncil:Test() failed: " .. tostring(err2 or err))
        end
    end
end
