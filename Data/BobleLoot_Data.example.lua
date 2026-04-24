-- EXAMPLE data file. Copy to BobleLoot_Data.lua or generate via tools/wowaudit.py.
-- The real BobleLoot_Data.lua is gitignored because it contains your guild's roster data.
--
-- To generate with TWW Season 3 defaults:
--   py tools/wowaudit.py --tier TWW-S3
BobleLoot_Data = {
    generatedAt          = "1970-01-01T00:00:00Z",
    generatedAtTimestamp = 0,
    teamUrl     = "https://wowaudit.com/eu/<region>/<realm>/<team>",
    simCap      = 5.0,
    mplusCap    = 160,
    historyCap  = 6,
    -- Optional fields emitted by --tier:
    tierPreset  = "TWW-S3",
    lootMinIlvl = 636,
    historyDays = 84,
    characters  = {
        ["Examplechar-Examplerealm"] = {
            attendance    = 100.0,
            mplusDungeons = 0,
            -- mainspec: character's primary spec (from WoWAudit roster).
            -- Used by Scoring.lua to select the correct sim column.
            -- Absent in convert-mode (CSV) runs.
            mainspec      = "Holy",
            -- role: "raider" | "trial" | "bench" (from WoWAudit member status).
            -- Drives the per-role history weight multiplier in Scoring.lua.
            role          = "raider",
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
