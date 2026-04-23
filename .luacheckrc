-- .luacheckrc — BobleLoot luacheck configuration
-- Lua 5.1 (WoW addon environment)
std = "lua51"

-- Ignore library files — we don't own these and they use their own globals.
exclude_files = {
    "Libs/**",
}

-- Allow up to 120 characters per line (WoW addon convention).
max_line_length = 120

-- Globals defined by the WoW client API (subset used by this addon).
globals = {
    -- Core WoW API
    "C_Item",
    "C_Timer",
    "C_TooltipInfo",
    "C_WeeklyRewards",
    "CreateFrame",
    "GameTooltip",
    "GetAddOnMetadata",
    "GetBuildInfo",
    "GetContainerItemInfo",
    "GetContainerNumSlots",
    "GetItemInfo",
    "GetItemInfoInstant",
    "GetItemQualityColor",
    "GetServerTime",
    "GetTime",
    "GetTradePlayerItemInfo",
    "IsInGroup",
    "IsInRaid",
    "SlashCmdList",
    "UnitIsGroupLeader",
    "UnitName",

    -- WoW frame/widget API
    "BackdropTemplateMixin",
    "GameFontNormal",
    "UIParent",

    -- LibStub / Ace3
    "LibStub",

    -- RCLootCouncil globals this addon reads
    "RCLootCouncil",
    "RCLootCouncilLootDB",

    -- This addon's own top-level globals
    "BobleLoot",
    "BobleLoot_Data",
    "BobleLootDB",
    "BobleLootSyncDB",

    -- WoW event system (commonly used patterns)
    "BINDING_HEADER_BOBLELOOT",
}

-- Read-only globals (should not be written to by addon code).
read_globals = {
    -- Standard Lua (already in std, listed for clarity)
    "pairs",
    "ipairs",
    "next",
    "select",
    "unpack",
    "tostring",
    "tonumber",
    "type",
    "math",
    "string",
    "table",
    "pcall",
    "xpcall",
    "error",
    "assert",

    -- WoW read-only globals
    "GRAY_FONT_COLOR",
    "GREEN_FONT_COLOR",
    "RED_FONT_COLOR",
    "YELLOW_FONT_COLOR",
    "DEFAULT_CHAT_FRAME",
}

-- Ignore unused self parameter in methods (common in Ace3 addon style).
self = false

-- Ignore specific warning codes that produce too many false positives
-- in WoW addon code (unused vararg, unused loop variable).
ignore = {
    "212",  -- unused argument (common in callback signatures)
    "213",  -- unused loop variable (common for _ in pairs/ipairs)
}
