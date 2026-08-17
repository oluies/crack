# Tasks: Diesel Crack Spreads & Retail Fuel Prices

**Branch**: `001-crack-and-retail-fuel-site` | **Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

`[P]` marks tasks that touch disjoint files and may run in parallel.

## Phase 1: Skeleton

Proves the toolchain before any real data exists.

- **T001** Create the directory layout from plan.md: `pipeline/`, `data/manual/`,
  `data/fixtures/`, `site/public/data/`, `site/app/src/`.
- **T002** `build.mill` — Mill `ScalaJSModule`, Scala 3.3.4, Scala.js 1.19.0,
  Laminar 17.2.0, output linked into `site/public/app.js`.
- **T003** [P] `site/index.html` — page shell in the elmix visual language (system
  font stack, 1100 px column, `#222` text, `#36c` links, `#e3e8ef` rules, `#f7f9fc`
  panels), ECharts from CDN, `© 2026 Örjan Lundberg` footer.
- **T004** [P] `site/app/src/ECharts.scala` — hand-written `js.native` facade:
  `init`, `setOption`, `resize`, `on`, `dispose`. Nothing speculative.
- **T005** Verify `mill site.fastLinkJS` links and the page renders a placeholder
  chart. **Gate: the toolchain works before data is added.**

## Phase 2: US crack spreads — User Story 1 (P1)

Independently shippable: the crack chart works with EIA alone.

- **T006** `pipeline/sources.env` — endpoint URLs, the Oil Bulletin UUID, the
  2022-01-03 start date. Configuration, not constants (research.md).
- **T007** `pipeline/00_schema.sql` — load `json`/`excel`/`httpfs`, create the
  staging schema, the `eu27` reference table, and `week_calendar` from 2022-01-03 to
  the last complete week.
- **T008** `pipeline/10_eia.sql` — `read_json_auto` over the EIA envelope,
  unnesting `response.data`; `spot_daily` from the `pri/spt` route and
  `retail_us_weekly` from `pri/gnd`. Two routes, not one (research.md).
- **T009** `pipeline/40_cracks.sql` — weekly means of the spot legs, `crack_weekly`
  per the data-model formulae, null where a leg is missing; read
  `data/manual/ice_gasoil.csv` tolerating a header-only file.
- **T010** [P] `data/manual/ice_gasoil.csv` — header-only stub with a comment
  pointing at the README.
- **T011** `pipeline/50_export.sql` — emit `cracks.json` per the contract, including
  the `meta.formulae` block and the always-present empty NWE series.
- **T012** `pipeline/run.sh` — sequence the scripts; `--offline`, `--fixtures`,
  `--verify-only`; fail with the failing source named (FR-006).
- **T013** [P] `site/app/src/Data.scala` — fetch and decode `cracks.json`.
- **T014** `site/app/src/Charts.scala` — crack line chart: shared week axis, tooltip
  naming week/series/USD-per-bbl to 2 dp.
- **T015** `site/app/src/Main.scala` — Laminar app, region toggle, and the NWE empty
  state naming `data/manual/ice_gasoil.csv`.
- **T016** Verify against SC-001: ≥190 weekly points per US series, no fabricated
  values. **Checkpoint: Story 1 is deliverable on its own.**

## Phase 3: Retail comparison — User Story 2 (P1)

Independent of Phase 2; different sources, different chart.

- **T017** `pipeline/20_oilbulletin.sql` — download the workbook, then the two-step
  `UNPIVOT ON COLUMNS(*)` from research.md: header row to `(col_letter, name)`, data
  rows to `(serial, col_letter, value)`, joined on the letter. Parse
  `{CC}_price_{with|wo}_tax_{euro95|diesel}`, restrict to `eu27`, EUR/1000 L ÷ 1000.
  **Do not read the `_exchange_rate` columns.**
- **T018** `pipeline/30_ecb.sql` — EUR/USD and EUR/SEK CSV; `ASOF JOIN` onto
  `week_calendar` so TARGET holidays carry forward.
- **T019** Extend `50_export.sql` with `retail.json` and `fx.json`; omit rather than
  null-fill `(cc, fuel, tax)` combinations the source does not publish.
- **T020** `pipeline/verify.sql` — the seven invariants from data-model.md, each
  failing with a message naming what broke.
- **T021** Extend `Data.scala` with `retail.json` and `fx.json`, plus the four
  conversion expressions from the contract.
- **T022** Extend `Charts.scala` with the retail chart: Sweden emphasised from the
  `focus` flag, EU thin grey, US dashed, hover emphasis naming the country.
- **T023** Extend `Main.scala` with the fuel / tax / currency toggles and the
  omitted-country note for the without-tax view.
- **T024** Verify SC-002 (all 27 members plus USA), SC-003 (Sweden legible without
  the legend), SC-004 (all 12 toggle combinations render with correct units).
  **Checkpoint: Story 2 is deliverable on its own.**

## Phase 4: Provenance — User Story 3 (P2)

- **T025** [P] `meta` blocks on all three JSON files: source, URL, licence, series
  IDs, formulae, refresh date.
- **T026** [P] On-page source notes and refresh date under each chart.
- **T027** [P] `README.md` — every source with its licence (EIA public domain, Oil
  Bulletin EU open data / CC BY 4.0), the crack formulae, the ICE gasoil
  manual-CSV limitation, and how to reproduce the JSON (FR-022).

## Phase 5: Automation — User Story 4 (P3)

- **T028** `data/fixtures/` — trimmed EIA JSON, a cut-down workbook, and ECB CSV, so
  CI runs the real SQL without a key.
- **T029** [P] `.github/workflows/ci.yml` — on push and PR: `mill site.compile` and
  `pipeline/run.sh --fixtures`.
- **T030** `.github/workflows/refresh.yml` — weekly cron plus `workflow_dispatch`:
  run the pipeline with `secrets.EIA_API_KEY`, commit changed JSON (nothing when
  unchanged), `mill site.fullLinkJS`, deploy `site/` via `actions/deploy-pages`.
- **T031** Verify SC-005 (clean clone reproduces the JSON), SC-006 (<5 MB),
  SC-007 (<10 min).

## Phase 6: Review

- **T032** `roborev review` over the branch; resolve findings or record an explicit
  waiver with its reason (constitution, Development Workflow).

## Dependencies

- T001 → everything.
- T005 gates Phases 2 and 3.
- Within Phase 2: T006 → T007 → T008 → T009 → T011 → T012; T013 → T014 → T015.
- Within Phase 3: T017 and T018 are independent of each other, both feed T019 → T021
  → T022 → T023.
- Phase 4 needs the exports to exist; Phase 5 needs the pipeline to be runnable.
- Phase 2 and Phase 3 do not depend on each other and may be built in either order.
