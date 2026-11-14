# The result file: `lhv-addons/2`

`lhv-addons.json` is what **Save as file** writes and what **Send to My sim** sends.
It is plain JSON in UTF-8.

## Top level

| Field | Type | Meaning |
|---|---|---|
| `format` | string | always `lhv-addons/2` |
| `tool` | string | name and version of the tool, for example `LHV Scan 1.0.0` |
| `created` | string | when the file was made, UTC, `2026-11-14T12:00:00Z` |
| `sims` | string[] | names of the simulators that were scanned |
| `count` | number | how many entries `addons` has |
| `notListed` | object | how many add-ons are **not** listed, per kind (see below) |
| `addons` | object[] | the airports and aircraft that are clear |

## One entry of `addons`

| Field | Type | Meaning |
|---|---|---|
| `sim` | string | simulator name, for example `MSFS 2024` |
| `folder` | string | the folder **name** of the add-on, never a path |
| `title` | string | from `manifest.json` (MSFS), may be empty |
| `maker` | string | from `manifest.json` (MSFS), may be empty |
| `kind` | string | `airport` or `aircraft` |
| `icaos` | string[] | airport codes found inside the scenery (for `airport`) |
| `aircraftTypes` | string[] | ICAO type codes (for `aircraft`), for example `A320` |
| `fixed` | boolean | `true` if the pilot set this with Quick fix |

Only add-ons that are clear are listed: the codes were read from the add-on's own files,
or the pilot fixed them. Everything else is counted in `notListed`.

## `notListed`

Keys are kinds, values are counts:

| Key | What it counts |
|---|---|
| `livery` | liveries |
| `mod` | tree fixes, seasons, lighting, mesh, airport fixes |
| `library` | object libraries |
| `traffic` | AI traffic and model matching |
| `navdata` | navigation data |
| `tool` | tools and panels |
| `other` | anything else, including parts of aircraft |
| `unclear` | add-ons that need a look and were not fixed |

A key is missing when its count is zero.

## What the receiver does with it

LH Virtual keeps, per pilot, only the result of a comparison: which listed aircraft
types the airline flies, and which listed airports are in its network. Folder names
and titles are used for one thing: the label shown next to an aircraft type on My sim.

## `lhv-addons/1`

The first version of the script wrote folder names, types and titles of all aircraft,
liveries and sceneries, and the server guessed from the names. Files in that format are
still accepted.
