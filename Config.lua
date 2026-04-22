--[[ Config.lua
     AceConfig-based options panel. Weight sliders auto-renormalize so
     the five weights always sum to 1.0.
]]

local _, ns = ...
local Config = {}
ns.Config = Config

local AceConfig         = LibStub("AceConfig-3.0")
local AceConfigDialog   = LibStub("AceConfigDialog-3.0")
local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")

local OPTIONS_NAME = "Boble Loot"

local WEIGHT_KEYS = { "sim", "bis", "history", "attendance", "mplus" }

local function countEnabled(enabled)
    local n = 0
    for _, k in ipairs(WEIGHT_KEYS) do
        if enabled[k] then n = n + 1 end
    end
    return n
end

-- Renormalize so enabled weights sum to 1.0; disabled weights are
-- forced to 0 (Scoring.lua then drops them entirely).
local function normalizeWeights(weights, enabled)
    for _, k in ipairs(WEIGHT_KEYS) do
        if not enabled[k] then weights[k] = 0 end
    end
    local sum = 0
    for _, k in ipairs(WEIGHT_KEYS) do sum = sum + (weights[k] or 0) end
    local n = countEnabled(enabled)
    if sum <= 0 then
        if n == 0 then return end
        for _, k in ipairs(WEIGHT_KEYS) do
            weights[k] = enabled[k] and (1 / n) or 0
        end
        return
    end
    for _, k in ipairs(WEIGHT_KEYS) do
        weights[k] = enabled[k] and (weights[k] / sum) or 0
    end
end

local function weightToggle(key, name, order)
    return {
        type = "toggle", name = name, order = order, width = "full",
        get = function() return ns.addon.db.profile.weightsEnabled[key] end,
        set = function(_, v)
            local p = ns.addon.db.profile
            p.weightsEnabled[key] = v
            if v then
                -- Newly enabled: give it an equal share before renormalizing,
                -- so it doesn't vanish at 0%.
                local n = countEnabled(p.weightsEnabled)
                p.weights[key] = (n > 0) and (1 / n) or 1
            end
            normalizeWeights(p.weights, p.weightsEnabled)
            AceConfigRegistry:NotifyChange(OPTIONS_NAME)
        end,
    }
end

local function weightSlider(key, name, order)
    return {
        type = "range", name = name, order = order, width = "full",
        min = 0, max = 1, step = 0.01, isPercent = true,
        disabled = function()
            return not ns.addon.db.profile.weightsEnabled[key]
        end,
        get = function()
            return ns.addon.db.profile.weights[key]
        end,
        set = function(info, val)
            ns.addon.db.profile.weights[key] = val
            normalizeWeights(ns.addon.db.profile.weights, ns.addon.db.profile.weightsEnabled)
            AceConfigRegistry:NotifyChange(OPTIONS_NAME)
        end,
    }
end

-- One inline sub-group per weight so the toggle, slider, and a separator
-- always stack vertically and each weight gets its own row block.
local function weightGroup(key, label, order)
    return {
        type = "group", inline = true, order = order, name = label,
        args = {
            enabled = weightToggle(key, "Enabled", 1),
            weight  = weightSlider(key, "Weight",  2),
        },
    }
end

function Config:BuildOptions()
    local p = function() return ns.addon.db.profile end
    return {
        type = "group",
        name = "Boble Loot",
        args = {
            general = {
                type = "group", inline = true, order = 1, name = "General",
                args = {
                    enabled = {
                        type = "toggle", order = 1, name = "Enabled",
                        get = function() return p().enabled end,
                        set = function(_, v) p().enabled = v end,
                    },
                    showColumn = {
                        type = "toggle", order = 2, name = "Show Boble Loot score column in RCLootCouncil",
                        get = function() return p().showColumn end,
                        set = function(_, v) p().showColumn = v end,
                    },
                    transparency = {
                        type = "toggle", order = 3, width = "full",
                        name = "Transparency mode (raid leader only)",
                        desc = "When enabled, every raid member with Boble Loot installed sees their own score on each item RCLootCouncil offers them. Only the actual group leader can toggle this; the change is broadcast to the raid.",
                        disabled = function() return not UnitIsGroupLeader("player") end,
                        get = function() return ns.addon:IsTransparencyEnabled() end,
                        set = function(_, v) ns.addon:SetTransparencyEnabled(v, true) end,
                    },
                    transparencyHint = {
                        type = "description", order = 4, fontSize = "small",
                        name = function()
                            if UnitIsGroupLeader("player") then
                                return "|cff80c0ffYou are the group leader; toggling above will affect everyone in the raid.|r"
                            else
                                return "|cffaaaaaaOnly the raid/group leader can change this. Current state is shown above (synced from leader).|r"
                            end
                        end,
                    },
                },
            },
            weights = {
                type = "group", inline = true, order = 2,
                name = "Weights (toggle on/off; sliders auto-normalize to 100%)",
                args = {
                    sim        = weightGroup("sim",        "WoWAudit sim upgrade",                10),
                    bis        = weightGroup("bis",        "BiS list",                            20),
                    history    = weightGroup("history",    "Recent items received",               30),
                    attendance = weightGroup("attendance", "Raid attendance",                     40),
                    mplus      = weightGroup("mplus",      "Mythic+ dungeons done (this season)", 50),
                },
            },
            tuning = {
                type = "group", inline = true, order = 3, name = "Tuning",
                args = {
                    partialBiSValue = {
                        type = "range", order = 1, name = "BiS partial credit (non-BiS items)",
                        min = 0, max = 1, step = 0.05, isPercent = true,
                        get = function() return p().partialBiSValue end,
                        set = function(_, v) p().partialBiSValue = v end,
                    },
                    overrideCaps = {
                        type = "toggle", order = 2, width = "full",
                        name = "Override caps from data file",
                        get = function() return p().overrideCaps end,
                        set = function(_, v) p().overrideCaps = v end,
                    },
                    mplusCap = {
                        type = "range", order = 4, name = "M+ dungeons cap (count -> 100)",
                        min = 5, max = 200, step = 1,
                        disabled = function() return not p().overrideCaps end,
                        get = function() return p().mplusCap end,
                        set = function(_, v) p().mplusCap = v end,
                    },
                    historyCap = {
                        type = "range", order = 5, name = "Loot equity soft floor",
                        desc = "Loot history is scored relative to the highest "
                            .. "'items received' among the bidders for the item. "
                            .. "This soft floor is used as a minimum denominator "
                            .. "early in the season (before anyone has crossed it) "
                            .. "so a single 1-loot person doesn't crush the "
                            .. "differentiation. Set higher = harder to lose "
                            .. "history credit early.",
                        min = 1, max = 20, step = 1,
                        disabled = function() return not p().overrideCaps end,
                        get = function() return p().historyCap end,
                        set = function(_, v) p().historyCap = v end,
                    },
                    lootHistoryDays = {
                        type = "range", order = 6, width = "full",
                        name = "Loot history window (days)",
                        desc = "Only items awarded by RCLootCouncil within the "
                            .. "last N days count toward 'items received'. "
                            .. "Set to 0 to count everything in RC's loot DB.",
                        min = 0, max = 180, step = 1,
                        get = function() return p().lootHistoryDays or 28 end,
                        set = function(_, v)
                            p().lootHistoryDays = v
                            if ns.LootHistory and ns.LootHistory.Apply then
                                ns.LootHistory:Apply(ns.addon)
                            end
                        end,
                    },
                },
            },
            lootCategories = {
                type = "group", inline = true, order = 3.5,
                name = "Loot category weights (for 'items received')",
                args = {
                    desc = {
                        type = "description", order = 1, fontSize = "small",
                        name = "RCLootCouncil-awarded items are classified by their response. "
                            .. "Transmog, off-spec/greed, disenchant, pass and PvP are always excluded. "
                            .. "Each category below contributes its weight per item to 'items received', "
                            .. "which is then capped against the 'Recent items cap' above.",
                    },
                    bis = {
                        type = "range", order = 2, width = "full", name = "BiS",
                        min = 0, max = 5, step = 0.1,
                        get = function() return p().lootWeights.bis end,
                        set = function(_, v)
                            p().lootWeights.bis = v
                            if ns.LootHistory then ns.LootHistory:Apply(ns.addon) end
                        end,
                    },
                    major = {
                        type = "range", order = 3, width = "full", name = "Major upgrade",
                        min = 0, max = 5, step = 0.1,
                        get = function() return p().lootWeights.major end,
                        set = function(_, v)
                            p().lootWeights.major = v
                            if ns.LootHistory then ns.LootHistory:Apply(ns.addon) end
                        end,
                    },
                    mainspec = {
                        type = "range", order = 4, width = "full",
                        name = "Mainspec / Need (uncategorised upgrade)",
                        min = 0, max = 5, step = 0.1,
                        get = function() return p().lootWeights.mainspec end,
                        set = function(_, v)
                            p().lootWeights.mainspec = v
                            if ns.LootHistory then ns.LootHistory:Apply(ns.addon) end
                        end,
                    },
                    minor = {
                        type = "range", order = 5, width = "full", name = "Minor upgrade",
                        min = 0, max = 5, step = 0.1,
                        get = function() return p().lootWeights.minor end,
                        set = function(_, v)
                            p().lootWeights.minor = v
                            if ns.LootHistory then ns.LootHistory:Apply(ns.addon) end
                        end,
                    },
                    minIlvl = {
                        type = "range", order = 6, width = "full",
                        name = "Minimum item level (filter by upgrade track)",
                        desc = "Loot history entries below this item level are "
                            .. "ignored when computing 'items received'. Use this "
                            .. "later in the season to exclude lower upgrade tracks "
                            .. "(Veteran/Champion) once Hero/Myth gear is the norm. "
                            .. "Set to 0 to count all tracks. Items with unknown "
                            .. "item level are always kept.",
                        min = 0, max = 800, step = 1, bigStep = 5,
                        get = function() return p().lootMinIlvl or 0 end,
                        set = function(_, v)
                            p().lootMinIlvl = v
                            if ns.LootHistory then ns.LootHistory:Apply(ns.addon) end
                        end,
                    },
                },
            },
            data = {
                type = "group", inline = true, order = 4, name = "Data",
                args = {
                    info = {
                        type = "description", order = 1, fontSize = "medium",
                        name = function()
                            local d = _G.BobleLoot_Data
                            if not d then return "|cffff5555No data file loaded.|r" end
                            local count = 0
                            for _ in pairs(d.characters or {}) do count = count + 1 end
                            return string.format(
                                "Generated: %s\nCharacters loaded: %d\nCaps (data): M+ dungeons=%d  history=%d   |cff888888(sim is uncapped)|r",
                                d.generatedAt or "?", count,
                                d.mplusCap or 0, d.historyCap or 0)
                        end,
                    },
                },
            },
            simulation = {
                type = "group", inline = true, order = 5, name = "Simulation / Testing",
                args = {
                    desc = {
                        type = "description", order = 1, fontSize = "small",
                        name = "Opens an RCLootCouncil test session so you can see the Boble Loot score column live. "
                            .. "Requires RCLootCouncil to be installed and you to be the group leader (or solo).",
                    },
                    count = {
                        type = "range", order = 2, name = "Number of items",
                        min = 1, max = 20, step = 1,
                        get = function() return p().testItemCount or 5 end,
                        set = function(_, v) p().testItemCount = v end,
                    },
                    useDataset = {
                        type = "toggle", order = 3, width = "full",
                        name = "Use items from BobleLoot dataset",
                        desc = "When on, the test session is seeded with random items that exist "
                            .. "in your loaded WoWAudit data so scores actually populate. "
                            .. "When off, a small built-in fallback list is used.",
                        get = function() return p().testUseDatasetItems ~= false end,
                        set = function(_, v) p().testUseDatasetItems = v and true or false end,
                    },
                    run = {
                        type = "execute", order = 4, name = "Run test session",
                        func = function()
                            if ns.TestRunner and ns.TestRunner.Run then
                                ns.TestRunner:Run(ns.addon, p().testItemCount or 5,
                                                  p().testUseDatasetItems ~= false)
                            end
                        end,
                    },
                },
            },
        },
    }
end

function Config:Setup(addon)
    AceConfig:RegisterOptionsTable(OPTIONS_NAME, function() return self:BuildOptions() end)
    self.optionsFrame = AceConfigDialog:AddToBlizOptions(OPTIONS_NAME, OPTIONS_NAME)
end

function Config:Open()
    -- Settings panel API differs across patches; try the modern one first.
    if Settings and Settings.OpenToCategory and self.optionsFrame and self.optionsFrame.name then
        Settings.OpenToCategory(self.optionsFrame.name)
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(self.optionsFrame)
        InterfaceOptionsFrame_OpenToCategory(self.optionsFrame)
    else
        AceConfigDialog:Open(OPTIONS_NAME)
    end
end
