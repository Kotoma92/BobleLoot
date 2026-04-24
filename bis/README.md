# BobleLoot BiS Files

This directory holds per-spec Best-in-Slot item lists used by `tools/wowaudit.py`
to populate the `bis` table in `Data/BobleLoot_Data.lua`.

## Directory layout

```
bis/
  <tier>/           e.g. tww-s3/
    <class>-<spec>.json
```

Each JSON file maps `"Name-Realm"` strings to arrays of item IDs:

```json
{
  "Boble-Stormrage": [212401, 212403, 212450],
  "Kotoma-TwistingNether": [212401]
}
```

## Usage

Pass the directory to `--bis` and every `.json` file will be merged:

```
python tools/wowaudit.py --bis bis/tww-s3/
```

You can also pass a single file for backward compatibility:

```
python tools/wowaudit.py --bis bis/tww-s3/paladin-holy.json
```

## Maintenance

- One file per class/spec keeps per-patch updates reviewable as single-file diffs.
- If the same character appears in multiple files, their item lists are merged
  without duplicates.
- Non-`.json` files (like this README) are silently ignored.

## Automatic derivation

Use `--bis-from-wishlist` to derive BiS lists automatically from WoWAudit
wishlist sim scores above a threshold (default 2.0%). This removes the need
to maintain these files manually in most seasons.

## Tier retention policy (Batch 4.1)

**Never delete a tier directory.** When a new tier launches:

1. Create `bis/<new-tier>/` and populate it.
2. Add the new tier to `tools/tier-config.yaml` with the correct `bisPath`.
3. Leave all old tier directories in place.

This means `py tools/wowaudit.py --tier tww-s2` will always regenerate a
historically-accurate Lua file for Season 2 scores, because `bis/tww-s2/`
is still on disk. Old BiS lists are the source of truth for historical
comparisons — the `tierPreset` field in `BobleLoot_Data.lua` identifies
which tier a given data file was generated for.
