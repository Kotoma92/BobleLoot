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
            bis  = { [12345] = true },
            sims = { [12345] = 1.23 },
        },
    },
}
