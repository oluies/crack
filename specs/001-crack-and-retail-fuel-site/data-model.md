# Phase 1 Data Model

Staging tables inside the pipeline's DuckDB database, and the contracts between the
SQL scripts. Column names carry their unit, per the constitution.

## Reference

### `eu27` — country reference

Explicit membership list, not derived from whatever columns the workbook happens to
carry (spec edge case: the UK is present in the history, and `EU_`/`EUR_` are
aggregates masquerading as prefixes).

| Column | Type | Notes |
|---|---|---|
| `cc` | `VARCHAR` | ISO 3166-1 alpha-2 as used by the Oil Bulletin |
| `name_en` | `VARCHAR` | Display label |
| `is_focus` | `BOOLEAN` | True for `SE` only; drives the emphasised line |

27 rows. `UK` is absent by construction.

## Staging

### `spot_daily` — from `10_eia.sql`

| Column | Type | Notes |
|---|---|---|
| `obs_date` | `DATE` | EIA `period` |
| `series_id` | `VARCHAR` | `EER_EPD2DXL0_PF4_Y35NY_DPG`, `RBRTE`, `RWTC` |
| `value` | `DOUBLE` | Native unit: USD/gal for ULSD, USD/bbl for the crudes |

### `retail_us_weekly` — from `10_eia.sql`

| Column | Type | Notes |
|---|---|---|
| `week_start` | `DATE` | ISO week Monday |
| `fuel` | `VARCHAR` | `diesel` \| `gasoline` |
| `usd_per_gal` | `DOUBLE` | As published |

EIA already publishes these weekly on Mondays; the week key is a `date_trunc`, not
an aggregation, and a duplicate would signal an upstream change — asserted.

### `retail_eu_weekly` — from `20_oilbulletin.sql`

| Column | Type | Notes |
|---|---|---|
| `week_start` | `DATE` | From the Excel serial, truncated to ISO week |
| `cc` | `VARCHAR` | EU-27 only |
| `fuel` | `VARCHAR` | `diesel` (gas oil automobile) \| `gasoline` (Euro-super 95) |
| `tax` | `VARCHAR` | `with` \| `without` |
| `eur_per_l` | `DOUBLE` | Source EUR/1000 L ÷ 1000 |

The workbook's `{CC}_exchange_rate` columns are **not** read. Prices are already
EUR-denominated (research.md §2.1); `verify.sql` asserts Swedish diesel stays inside
1.0–3.0 EUR/L, which fails loudly if anyone reintroduces a conversion.

### `fx_weekly` — from `30_ecb.sql`

| Column | Type | Notes |
|---|---|---|
| `week_start` | `DATE` | ISO week Monday |
| `ccy` | `VARCHAR` | `USD` \| `SEK` |
| `per_eur` | `DOUBLE` | Units of `ccy` per 1 EUR |

ECB publishes business days only. The weekly rate is the last observation on or
before that Monday — an `ASOF JOIN` against the week calendar, so a TARGET holiday
carries the prior rate forward rather than producing a hole. This is the one place
forward-fill is correct: an exchange rate is a level that persists, unlike a price
observation that was simply never taken.

### `gasoil_manual` — from `40_cracks.sql`

Read from `data/manual/ice_gasoil.csv`.

| Column | Type | Notes |
|---|---|---|
| `obs_date` | `DATE` | Settlement date |
| `usd_per_tonne` | `DOUBLE` | ICE Low Sulphur Gasoil futures settlement |

Ships header-only. An empty table is a valid state, not an error (FR-005).

## Derived

### `crack_weekly` — from `40_cracks.sql`

| Column | Type | Notes |
|---|---|---|
| `week_start` | `DATE` | |
| `series_key` | `VARCHAR` | `us_ulsd_brent`, `us_ulsd_wti`, `nwe_gasoil_brent` |
| `region` | `VARCHAR` | `US` \| `NWE` |
| `usd_per_bbl` | `DOUBLE` | Null when either leg is missing that week |

**Formulae**

- `us_ulsd_brent` = `ulsd_usd_per_gal × 42 − brent_usd_per_bbl`
- `us_ulsd_wti` = `ulsd_usd_per_gal × 42 − wti_usd_per_bbl`
- `nwe_gasoil_brent` = `gasoil_usd_per_tonne ÷ 7.45 − brent_usd_per_bbl`

42 US gallons per barrel is exact. 7.45 barrels per tonne is the conventional gasoil
density factor and is stated on the chart, since unlike the gallon figure it is a
convention rather than a definition.

A week enters the table only when both legs have at least one observation; the
spread is otherwise null, never interpolated (constitution: missing is null).

### `week_calendar`

Every ISO week Monday from 2022-01-03 to the last **complete** week. Every published
series is left-joined onto this so all charts share one axis and gaps stay visible
as gaps. The current partial week is excluded here, once, rather than in five places.

## Invariants

Each assertion fails the run with a message naming what broke.

### Staging (`verify.sql`, before export)

1. `week_calendar` has no gaps — consecutive Mondays, 7 days apart throughout.
2. No duplicate rows **in the pre-aggregation tables**: `(obs_date, series_id)` in
   `spot_daily` and `retail_us_raw`, `(obs_date, cc, fuel, tax)` in `ob_parsed`.
   These must target the raw rows. Asserting uniqueness on a weekly table whose
   own `GROUP BY` produces that key is tautological — it reports green on exactly
   the upstream double-publication it claims to catch.
3. All 27 EU members present in the latest published week for with-tax diesel.
4. Swedish with-tax diesel lies in 1.0–3.0 EUR/L across the whole range — catches a
   reintroduced exchange-rate multiplication.
5. US crack spreads lie in −20 to 120 USD/bbl — wide enough for the 2022 spike,
   tight enough to catch a unit error such as omitting the ×42.
6. `fx_weekly` covers every calendar week for both currencies.
7. No long trailing run of empty weeks — data has not gone stale upstream.
   **Live runs only.** Fixtures are a frozen snapshot while `week_calendar`
   tracks `current_date`, so this would start failing every CI run weeks after
   the fixtures were generated, blocking pull requests for an unrelated reason.
   `run.sh` sets `strict=false` in fixtures mode.

### Published JSON (`60_verify_export.sql`, after export)

`verify.sql` cannot see these — it runs against staging, before the files exist.

8. Every series in `cracks.json` is aligned to `weeks[]`, or empty (the ICE stub).
9. Every series in `retail.json` is aligned to `weeks[]`.
10. `fx.json` rates are aligned to `weeks[]` **and** contain no nulls.
11. All three files share one week axis.

Checks 8–11 exist because the wide-form contract is entirely positional and the
frontend indexes without bounds checks: `Fx.convert` reads `usd(i)` for an `i`
originating in a retail series. A short array throws mid-render and blanks every
chart; a merely shifted one draws the wrong year and looks fine.
