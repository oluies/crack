# Implementation Plan: Diesel Crack Spreads & Retail Fuel Prices

**Branch**: `001-crack-and-retail-fuel-site` | **Date**: 2026-08-17 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-crack-and-retail-fuel-site/spec.md`

## Summary

A static site with two charts: weekly diesel crack spreads since 2022, and weekly
retail pump prices with Sweden set against the EU-27 and the USA. A DuckDB SQL
pipeline pulls EIA JSON, the EU Oil Bulletin workbook, and ECB reference rates,
reshapes them to tidy weekly observations, and emits one pre-aggregated JSON file
per chart. A Scala.js/Laminar app reads those files and drives ECharts through a
hand-written facade. GitHub Actions refreshes the data weekly and deploys to Pages.

Phase 0 research verified every automated source against the live endpoint; the
findings that shape the SQL — the Oil Bulletin's three-row header, its
already-in-EUR prices, EIA's split between the `spt` and `gnd` routes — are recorded
in [research.md](./research.md).

## Technical Context

**Language/Version**: Scala 3.3.4 on Scala.js 1.19.0 (frontend); DuckDB 1.5 SQL
(pipeline); POSIX shell for sequencing.

**Primary Dependencies**: Laminar 17.2.0; ECharts 5 from jsDelivr CDN via a
hand-written `js.native` facade. DuckDB `excel`, `httpfs`, and `json` extensions.
No npm, no bundler, no ScalablyTyped.

**Storage**: Static JSON files under `site/public/data/`. A DuckDB database file
exists only as pipeline scratch and is gitignored.

**Testing**: Mill compile as the frontend gate; `pipeline/verify.sql` asserts
invariants on the built tables (row counts, unit ranges, EU-27 completeness, no
duplicate week keys) and exits non-zero on violation. CI runs the pipeline against
checked-in fixtures so no API key is needed on pull requests.

**Target Platform**: Static hosting on GitHub Pages; any modern browser.

**Project Type**: Data pipeline + static single-page frontend. No backend.

**Performance Goals**: Charts interactive within 2 s on a cold load over broadband;
toggles re-render without refetching.

**Constraints**: Total published payload under 5 MB excluding the CDN library
(SC-006); weekly workflow under 10 minutes (SC-007); pipeline output byte-identical
across reruns on unchanged input (constitution V).

**Scale/Scope**: ~240 weeks × (28 retail regions × 2 fuels × 2 tax treatments) plus
3 crack series and 2 FX series. On the order of 30 000 published observations —
small enough that pre-aggregation to JSON is comfortably the right answer.

## Constitution Check

*GATE: passed before Phase 0, re-checked after Phase 1 design.*

| Principle | How this plan satisfies it |
|---|---|
| I. Static by Construction | Output is JSON files served beside the app. The only cross-origin request is the ECharts CDN script tag, which FR-019 permits explicitly. |
| II. SQL Is the Pipeline | All acquisition and reshaping is DuckDB SQL: `read_json_auto` over the EIA envelope, `read_xlsx` + `UNPIVOT ON COLUMNS(*)` for the workbook, `read_csv` for ECB and the manual CSV. Shell only sequences scripts and curls the workbook, which DuckDB cannot fetch through the redirecting UUID path. No Python. |
| III. Provenance Is Part of the Data | Every emitted JSON carries a `meta` block with source, licence, series IDs, formula, and refresh date. ICE gasoil ships as a documented empty stub with a visible UI state. |
| IV. Minimal Frontend Surface | One facade file, only the ECharts members the charts call. Laminar is the sole Scala dependency. |
| V. Reproducible Refresh | `pipeline/run.sh` is the single entry point, used identically by a developer and by CI. Refresh timestamps live in `meta`, isolated from observations, so unchanged data yields an unchanged diff in the series arrays. |

**Re-check after Phase 1**: no violations. The Complexity Tracking table is empty.

One tension worth naming: constitution V demands byte-identical reruns, while every
output carries a refresh date that changes each run. Resolved by writing
`meta.generated` only when the observation payload actually differs — the refresh
workflow compares the series content and skips the commit when only the timestamp
moved (FR-020).

## Project Structure

### Documentation (this feature)

```text
specs/001-crack-and-retail-fuel-site/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0: verified source findings
├── data-model.md        # Phase 1: entities and table contracts
├── quickstart.md        # Phase 1: run it locally
├── contracts/
│   └── chart-json.md    # Phase 1: published JSON shapes
└── tasks.md             # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
pipeline/
├── run.sh               # Single entry point; sequences the SQL below
├── sources.env          # Endpoint URLs and the Oil Bulletin UUID (configuration)
├── 00_schema.sql        # Extensions, staging schema, EU-27 country reference
├── 10_eia.sql           # Spot + retail series via read_json_auto
├── 20_oilbulletin.sql   # Workbook -> tidy country/fuel/tax observations
├── 30_ecb.sql           # EUR/USD, EUR/SEK daily -> weekly
├── 40_cracks.sql        # Weekly crack spreads incl. the manual NWE leg
├── 50_export.sql        # COPY ... TO '.json' per chart
└── verify.sql           # Invariant assertions; non-zero exit on failure

data/
├── manual/
│   └── ice_gasoil.csv   # Header-only stub; user-supplied ICE settlements
└── fixtures/            # Trimmed upstream samples for keyless CI

site/
├── index.html           # Shell: elmix visual language, CDN ECharts, app.js
├── public/data/*.json   # Pipeline output (committed)
└── app/src/
    ├── Main.scala       # Laminar app, state, layout
    ├── ECharts.scala    # Hand-written js.native facade
    ├── Data.scala       # Fetch + decode the published JSON
    └── Charts.scala     # ECharts option builders

build.mill               # Mill ScalaJSModule -> site/public/app.js
.github/workflows/
├── ci.yml               # Push/PR: compile + pipeline against fixtures
└── refresh.yml          # Weekly cron: pipeline, commit, build, deploy Pages
README.md                # Sources, licences, the ICE gasoil limitation
```

**Structure Decision**: Two top-level concerns — `pipeline/` and `site/` — matching
the two halves of the constitution (SQL pipeline, minimal frontend), with `data/`
holding the inputs the pipeline cannot fetch. Mill's build file sits at the root and
emits directly into `site/public/`, so the deployable artefact is exactly the `site/`
directory with no copy step to get wrong.

## Phase Sequencing

Ordered so each phase is independently demonstrable, matching the spec's story
priorities.

1. **Skeleton** — repo layout, Mill build, `index.html`, facade, a chart drawing
   hard-coded points. Proves the toolchain end to end before any data exists.
2. **US crack (Story 1)** — `10_eia.sql`, `40_cracks.sql`, crack chart with the
   region toggle and the NWE empty state. Shippable alone.
3. **Retail comparison (Story 2)** — `20_oilbulletin.sql`, `30_ecb.sql`, retail
   chart with all four toggles. Shippable alone.
4. **Provenance (Story 3)** — `meta` blocks, on-page source notes, README.
5. **Automation (Story 4)** — both workflows, fixtures, `verify.sql`.

## Key Design Decisions

**Currency conversion happens in the browser.** Series are published in their native
currency next to the weekly ECB rates. Three separately rounded pipelines would drift
against each other; one source of truth plus client-side arithmetic cannot
(constitution "Currency conversion is a presentation concern").

**Weeks are ISO weeks keyed to Monday.** EIA spot is daily, EIA retail is Monday, the
Oil Bulletin is weekly-on-Monday-for-the-prior-week. Bucketing everything to
`date_trunc('week', …)` makes cross-source joins exact instead of approximate, and
dropping the incomplete current week stops a two-day average from rendering as a dip.

**One JSON file per chart, wide-form.** A shared week axis plus parallel value
arrays, rather than a row per observation. This is what ECharts consumes and it is
several times smaller than tidy JSON — the whole retail dataset lands well inside the
5 MB budget without compression tricks.

**The Oil Bulletin's exchange-rate columns are ignored.** Research established that
country prices are already EUR-denominated. Reading those columns as a conversion
factor would divide Swedish prices by eleven — the kind of error that looks
plausible on a chart, so it is called out here and asserted in `verify.sql`.

## Complexity Tracking

No constitution violations; nothing to justify.
