-- .luacheckrc — BobleLoot luacheck configuration
-- Lua 5.1 (WoW addon environment)
std = "lua51"

-- Ignore library files — we don't own these and they use their own globals.
exclude_files = {
    "Libs/**",
}

-- Allow up to 120 characters per line (WoW addon convention).
max_line_length = 120

-- Globals defined by the WoW client API, plus this addon's own top-level
-- globals. These may be read or written.
globals = {
    -- Core WoW API
    "C_Container",
    "C_Item",
    "C_ItemInteraction",
    "C_Timer",
    "C_TooltipInfo",
    "C_WeeklyRewards",
    "CreateFrame",
    "EasyMenu",
    "GameTooltip",
    "GetAddOnMetadata",
    "GetBuildInfo",
    "GetContainerItemInfo",
    "GetContainerItemLink",
    "GetContainerNumSlots",
    "GetDetailedItemLevelInfo",
    "GetItemInfo",
    "GetItemInfoInstant",
    "GetItemQualityColor",
    "GetNormalizedRealmName",
    "GetNumGroupMembers",
    "GetRealmName",
    "GetServerTime",
    "GetTime",
    "GetTradePlayerItemInfo",
    "GetTradePlayerItemLink",
    "HideUIPanel",
    "InterfaceOptions_AddCategory",
    "IsInGroup",
    "IsInGuild",
    "IsInRaid",
    "IsShiftKeyDown",
    "SendChatMessage",
    "Settings",
    "SettingsPanel",
    "SlashCmdList",
    "StaticPopupDialogs",
    "StaticPopup_Show",
    "StaticPopup_Visible",
    "UIDropDownMenu_AddButton",
    "UIDropDownMenu_CreateInfo",
    "UIDropDownMenu_Initialize",
    "UIDropDownMenu_SetSelectedValue",
    "UIDropDownMenu_SetText",
    "UIDropDownMenu_SetWidth",
    "UIFrameFadeIn",
    "UIFrameFadeOut",
    "UnitExists",
    "UnitInParty",
    "UnitInRaid",
    "UnitIsGroupLeader",
    "UnitIsInMyGuild",
    "UnitName",
    "date",
    "geterrorhandler",
    "hooksecurefunc",
    "time",

    -- Localization / UI string constants from WoW
    "OKAY",

    -- WoW frame/widget API
    "BackdropTemplateMixin",
    "GameFontNormal",
    "UIParent",

    -- LibStub / Ace3
    "LibStub",

    -- RCLootCouncil globals this addon reads
    "RCLootCouncil",
    "RCLootCouncilLootDB",

    -- Lua throwaway convention (multi-assign discards)
    "_",

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

-- Ignore warning codes that produce noise in WoW addon code without
-- indicating real defects.
--  211 — unused local (Ace3 retains handle frames as locals for later ref)
--  212 — unused argument (common in callback signatures)
--  213 — unused loop variable (for _ in pairs/ipairs)
--  231 — local never mutated after assignment
--  311 — unused value (e.g. reassigning before use in control flow)
--  411 — redefining local (sequential blocks commonly reuse names)
--  421 — shadowing local
--  431 — shadowing upvalue (closure-heavy UI callbacks)
--  432 — shadowing upvalue argument
--  512 — loop executed at most once (legitimate early-return-first idiom)
ignore = {
    "211",
    "212",
    "213",
    "231",
    "311",
    "411",
    "421",
    "431",
    "432",
    "512",
}

-- Addon-private helpers declared without `local` — treat them as
-- internal globals so luacheck stops flagging cross-reference within
-- a single file. Cleaning these up to proper locals is tracked as
-- follow-up work; the leaks are functional but stylistically incorrect.
files["UI/SettingsPanel.lua"] = {
    globals = {
        "BuildWeightsTab",
        "BuildTuningTab",
        "BuildLootDBTab",
        "BuildDataTab",
        "BuildTestTab",
        "updateAllDisabledLbl",
        "infoCard",
    },
}
