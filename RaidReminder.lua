--[[ RaidReminder.lua
     Boble Loot popups triggered by guild raid context.

     Two reminders live here:

       1. STALE-DATA reminder — leader-only. When the local player joins
          a guild raid AS the raid leader and the WoWAudit dataset hasn't
          been refreshed since the previous guild raid, prompt them to
          run `tools/wowaudit.py`.

       2. SIM reminder — every addon user. When entering a guild raid,
          remind the player to upload their sims to wowaudit (Raidbots ->
          wowaudit auto-import). Throttled per character so it doesn't
          spam if you re-enter raid soon after.

     State is persisted in BobleLootDB.global / .profile.
]]

local _, ns = ...
local Reminder = {}
ns.RaidReminder = Reminder

local MIN_GUILDMATES = 5     -- including the player themselves
local CHECK_DELAY    = 8     -- seconds after entering raid (let roster settle)
local POPUP_KEY     = "BOBLELOOT_STALE_DATA"
local POPUP_CMD_KEY = "BOBLELOOT_REFRESH_CMD"
local POPUP_SIM_KEY = "BOBLELOOT_SUBMIT_SIMS"
local POPUP_URL_KEY = "BOBLELOOT_SIM_URL"
local REFRESH_CMD   = [[py tools/wowaudit.py]]
local SIM_REMIND_HOURS = 12  -- per-character throttle

local function nowUTC()
    return date("!%Y-%m-%dT%H:%M:%SZ")
end

local function inRaid()
    return IsInRaid()
end

local function isLeader()
    return UnitIsGroupLeader("player")
end

local function isGuildRaid()
    if not IsInGuild() or not inRaid() then return false end
    local guildies = 0
    for i = 1, GetNumGroupMembers() do
        local unit = "raid" .. i
        if UnitExists(unit) and UnitIsInMyGuild(unit) then
            guildies = guildies + 1
        end
    end
    return guildies >= MIN_GUILDMATES
end

local function ensurePopup(addon)
    if not StaticPopupDialogs[POPUP_KEY] then
        StaticPopupDialogs[POPUP_KEY] = {
            text         = "Boble Loot: your WoWAudit data hasn't been refreshed since your last guild raid.\n\n"
                        .. "Last update: %s\nLast raid:   %s\n\n"
                        .. "Run the refresh command before pulls so scores reflect current sims.",
            button1      = "Show refresh command",
            button2      = "Remind later",
            button3      = OKAY,
            OnButton1    = function()
                StaticPopup_Show(POPUP_CMD_KEY)
            end,
            OnButton2    = function()
                Reminder:SnoozeUntilNextRaid(addon)
            end,
            OnButton3    = function() end,
            timeout      = 0,
            whileDead    = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end

    if not StaticPopupDialogs[POPUP_CMD_KEY] then
        StaticPopupDialogs[POPUP_CMD_KEY] = {
            text         = "Run this in a terminal from your BobleLoot addon folder.\nPress Ctrl+C to copy.",
            button1      = OKAY,
            hasEditBox   = true,
            editBoxWidth = 320,
            OnShow       = function(self)
                local eb = self.editBox or self.EditBox
                if not eb then return end
                eb:SetText(REFRESH_CMD)
                eb:SetFocus()
                eb:HighlightText()
            end,
            EditBoxOnEnterPressed = function(self)
                self:GetParent():Hide()
            end,
            EditBoxOnEscapePressed = function(self)
                self:GetParent():Hide()
            end,
            timeout      = 0,
            whileDead    = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
end

local function fmt(ts)
    return ts and ts or "(never)"
end

function Reminder:SnoozeUntilNextRaid(addon)
    -- Don't update lastGuildRaidAt; we'll warn again on the next raid.
    self._warnedThisSession = false
end

local function dataGeneratedAt(addon)
    local data = addon:GetData()
    return data and data.generatedAt or nil
end

function Reminder:CheckAndWarn(addon)
    if self._warnedThisSession then return end
    if not (inRaid() and isLeader() and isGuildRaid()) then return end

    local db        = addon.db.global
    local lastRaid  = db.lastGuildRaidAt
    local generated = dataGeneratedAt(addon)

    -- Always advance the "last guild raid" marker so we have something
    -- to compare against next time.
    db.lastGuildRaidAt = nowUTC()
    self._warnedThisSession = true

    if not lastRaid then
        -- First guild raid we've ever observed; nothing to compare to.
        return
    end

    -- Stale if the data was generated *before* the previous guild raid
    -- started. Lexicographic compare works on ISO-8601 UTC strings.
    if generated and generated >= lastRaid then return end

    ensurePopup(addon)
    StaticPopup_Show(POPUP_KEY, fmt(generated), fmt(lastRaid))

    -- Notify the toast system (plan 3.12) via AceEvent so Toast stays
    -- decoupled from RaidReminder. Compute hoursOld from the data timestamp.
    local generatedAt = _G.BobleLoot_Data and _G.BobleLoot_Data.generatedAt
    local hoursOld = 0
    if generatedAt then
        -- generatedAt is an ISO-8601 UTC string; time() is Unix seconds.
        -- Approximate by treating the string as a rough date — if it parses
        -- to a number (epoch) use it directly; otherwise estimate from lastRaid.
        local ts = tonumber(generatedAt)
        if not ts and generated then
            -- Try to extract from the ISO string if it were epoch-encoded.
            ts = tonumber(generated:match("^(%d+)$"))
        end
        if ts and ts > 0 then
            hoursOld = math.floor((time() - ts) / 3600)
        end
    end
    if addon.SendMessage then
        addon:SendMessage("BobleLoot_DataStale", hoursOld)
    end
end

function Reminder:Setup(addon)
    addon.db.global = addon.db.global or {}

    local function maybeCheck()
        if not inRaid() then
            -- Left the raid; reset session flags so we warn again next time.
            self._warnedThisSession = false
            self._simReminderShown  = false
            return
        end
        C_Timer.After(CHECK_DELAY, function()
            self:CheckAndWarn(addon)
            self:CheckAndRemindSims(addon)
        end)
    end

    addon:RegisterEvent("PLAYER_ENTERING_WORLD", maybeCheck)
    addon:RegisterEvent("GROUP_ROSTER_UPDATE",   maybeCheck)
    addon:RegisterEvent("PARTY_LEADER_CHANGED",  maybeCheck)
end

-- ---- Sim-submission reminder (every player) ------------------------------

local function ensureSimPopup(addon)
    if not StaticPopupDialogs[POPUP_SIM_KEY] then
        StaticPopupDialogs[POPUP_SIM_KEY] = {
            text         = "Boble Loot:\n\n"
                        .. "Don't forget to submit your sims to WoWAudit before pulls!\n\n"
                        .. "Run a sim on Raidbots with the wowaudit profile so the raid "
                        .. "leader's loot scores reflect your current gear.",
            button1      = "Show wowaudit link",
            button2      = "Don't remind me today",
            button3      = OKAY,
            OnButton1    = function() StaticPopup_Show(POPUP_URL_KEY) end,
            OnButton2    = function()
                local p = addon.db.profile
                p.simReminderSnoozeUntil = time() + 24 * 3600
            end,
            OnButton3    = function() end,
            timeout      = 0,
            whileDead    = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end

    if not StaticPopupDialogs[POPUP_URL_KEY] then
        StaticPopupDialogs[POPUP_URL_KEY] = {
            text         = "Open this in your browser to upload sims via Raidbots.\n"
                        .. "Press Ctrl+C to copy.",
            button1      = OKAY,
            hasEditBox   = true,
            editBoxWidth = 380,
            OnShow       = function(self)
                local data = addon:GetData()
                local url  = (data and data.teamUrl) or "https://wowaudit.com"
                local eb = self.editBox or self.EditBox
                if not eb then return end
                eb:SetText(url)
                eb:SetFocus()
                eb:HighlightText()
            end,
            EditBoxOnEnterPressed  = function(self) self:GetParent():Hide() end,
            EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
            timeout      = 0,
            whileDead    = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
end

function Reminder:CheckAndRemindSims(addon)
    if self._simReminderShown then return end
    if not (inRaid() and isGuildRaid()) then return end

    local p          = addon.db.profile
    local lastShown  = p.lastSimReminderAt or 0
    local snooze     = p.simReminderSnoozeUntil or 0
    local nowEpoch   = time()

    -- Per-character throttle: don't show more than once per N hours,
    -- and respect the explicit "snooze for a day" choice.
    if nowEpoch < snooze then return end
    if (nowEpoch - lastShown) < SIM_REMIND_HOURS * 3600 then return end

    p.lastSimReminderAt    = nowEpoch
    self._simReminderShown = true

    ensureSimPopup(addon)
    StaticPopup_Show(POPUP_SIM_KEY)
end

-- Manual trigger: bypasses the once-per-session throttle but keeps the
-- raid/leader/guild gates so it can't pop up randomly while soloing.
function Reminder:ForceCheck(addon)
    self._warnedThisSession = false
    if not (inRaid() and isLeader() and isGuildRaid()) then
        addon:Print("not in a guild raid as leader; nothing to check.")
        return
    end
    self:CheckAndWarn(addon)
    if not StaticPopup_Visible(POPUP_KEY) then
        addon:Print("WoWAudit data is up to date for this raid.")
    end
end
