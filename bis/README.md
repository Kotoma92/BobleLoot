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
