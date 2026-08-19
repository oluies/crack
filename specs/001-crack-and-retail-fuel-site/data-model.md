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

Every ISO week Monday from 2022-01-03 to the later of:

- the last **complete** week, and
- the most recent week in which a weekly **point-in-time survey** has published
  (EU Oil Bulletin, EIA `pri/gnd`), capped at the build week.

Every published series is left-joined onto this so all charts share one axis and
gaps stay visible as gaps.

The current week is therefore *included* when a survey has published in it — see
feature 004, FR-301/FR-302. It was once excluded unconditionally, which discarded a
published retail price for up to seven days: for those sources one observation *is*
the week, not a partial mean of it. Daily-sampled sources cannot extend the axis,
because there an unfinished week genuinely is a partial mean; that case is governed
by `min_week_obs` instead.

"Today" is `stg.build_meta.built_on`, frozen at build time, so `--verify-only`
against an older database judges the axis by the day it was built rather than by
the day it is re-checked. Built in `pipeline/25_calendar.sql`, after the sources are
parsed — the bound depends on what they published, so it cannot live in
`00_schema.sql`.

## Invariants

Each assertion fails the run with a message naming what broke.

### Staging (`verify.sql`, before export)

1. `week_calendar` has no gaps — consecutive Mondays, 7 days apart throughout.
2. No duplicate rows in the pre-aggregation tables, **grouped by the key those
   tables are later aggregated on**: `(week, fuel)` over `retail_us_raw`,
   `(week, cc, fuel, tax)` over `ob_parsed`, and `(obs_date, series_id)` over
   `spot_daily` — the last is the exception, because that table is genuinely
   daily and its weekly mean is deliberate.
   Two mistakes are possible here and both were made in turn. Asserting on the
   weekly table is tautological: its own `GROUP BY` produces the key. Asserting
   on the raw table but by the *raw* key is no better — two publications in the
   same week carry different dates, pass a `(date, …)` check, and are silently
   averaged by the very `GROUP BY` downstream that the check exists to police.
3. All 27 EU members present in the latest published week for with-tax diesel.
4. Swedish with-tax diesel lies in 1.0–3.0 EUR/L across the whole range — catches a
   reintroduced exchange-rate multiplication.
5. US crack spreads lie in −20 to 120 USD/bbl — wide enough for the 2022 spike,
   tight enough to catch a unit error such as omitting the ×42.
6. `fx_weekly` covers every calendar week for both currencies.
7. No long trailing run of empty weeks — data has not gone stale upstream.
   Check 7 (crack) is **live runs only**: under `--fixtures` the EIA half is a
   frozen synthetic snapshot while `week_calendar` follows the build date
   (`stg.build_meta.built_on`), which advances with every run, so it
   would start failing every CI run weeks after the fixtures were generated,
   blocking pull requests for an unrelated reason.
   Check 7b (EU retail) is **not** gated — the Oil Bulletin is fetched live in
   every mode, so a workbook that still parses but has stopped being updated
   must fail CI rather than sail through it.
   Strictness is recorded in `stg.build_meta` at build time, not read from the
   current invocation: `--verify-only` re-checks a database an earlier run
   built, and deriving it from the current mode failed a fixtures build the
   moment it was re-verified.

### Published JSON (`60_verify_export.sql`, after export)

`verify.sql` cannot see these — it runs against staging, before the files exist.

8. All three files are well-formed — `weeks` and `series`/`rates.*` are arrays,
   `series` non-empty, `meta` an object, and `series[0]` carries the element keys
   the later checks dereference. Probed on the raw JSON, and deliberately first: every check
   below reads through `read_json`, whose inferred schema depends on content, so
   a missing key or an all-null array makes the *column* unbindable and yields a
   binder error naming a column instead of the problem.
9. Every series in `cracks.json` is aligned to `weeks[]`. The empty exemption
   applies **only** to `nwe_gasoil_brent`, the declared ICE stub — a blanket
   "or empty" would let Brent, WTI and ULSD all come back empty and still pass.
10. Every series in `retail.json` is aligned to `weeks[]`.
11. `fx.json` rates are aligned to `weeks[]` **and** contain no nulls.
12. All three files share one week axis.

These checks read through `out_dir` while `50_export.sql` writes to a string
literal — DuckDB's `COPY ... TO` accepts nothing else there, so the coupling
cannot be made structural. `run.sh` asserts the two agree before it builds.
An attempt to catch the divergence in SQL instead, by comparing `meta.generated`
against the run's stamp, was reverted: it broke `--verify-only` on any later UTC
day and on any file the idempotence restore had rolled back — live breakage in
exchange for a risk reachable only by editing `run.sh`.

## Testing the invariants

`pipeline/test/negative.sh` corrupts each input in turn and asserts the run exits
non-zero **and** names the expected check — plus one case asserting the strict
gate stays silent when it should.

It exists because three consecutive commits shipped invariants that could not
fire: uniqueness asserted on tables whose own `GROUP BY` produced the key; then
the same checks on the raw table but keyed on the raw date, so two publications
in one week still passed; then four export checks returning green on NULL. Review
caught all three; the build caught none, because it only ever ran the happy path.
A green happy path proves the checks did not fire, never that they could.

Comparisons use `IS DISTINCT FROM`, not `<>`. These checks reject malformed
input, and `NULL <> NULL` is `NULL` — the ordinary operator makes every one of
them fail open on precisely the input it exists to catch.

Checks 8–12 exist because the wide-form contract is entirely positional and the
frontend indexes without bounds checks: `Fx.convert` reads `usd(i)` for an `i`
originating in a retail series. A short array throws mid-render and blanks every
chart; a merely shifted one draws the wrong year and looks fine.
