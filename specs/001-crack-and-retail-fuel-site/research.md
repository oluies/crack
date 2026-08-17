# Phase 0 Research: Source Verification

**Date**: 2026-08-17. Every finding below was established by fetching the live
endpoint, not from documentation or memory.

## EIA Open Data API v2

**Base**: `https://api.eia.gov/v2/petroleum/pri/spt/data/`
**Auth**: `api_key` query parameter, from `EIA_API_KEY`.

Verified: the route exists and rejects a bad key with HTTP 403 and
`{"error":{"code":"API_KEY_INVALID"}}` — a 404 would have meant a wrong path, so
the route shape is confirmed independently of holding a valid key.

**Gotcha**: `curl` treats the bracketed EIA parameters (`data[0]=value`,
`facets[series][]=RBRTE`) as a globbing range and fails with "bad range in URL".
Pass `--globoff` / `-g`. This bites in shell scripts, not in DuckDB's HTTP client.

**Series**:

| Series ID | Route | Meaning | Unit |
|---|---|---|---|
| `EER_EPD2DXL0_PF4_Y35NY_DPG` | `petroleum/pri/spt` | NY Harbor ULSD spot | USD/gal |
| `RBRTE` | `petroleum/pri/spt` | Brent Europe spot FOB | USD/bbl |
| `RWTC` | `petroleum/pri/spt` | WTI Cushing spot FOB | USD/bbl |
| `EMM_EPMR_PTE_NUS_DPG` | `petroleum/pri/gnd` | US regular gasoline retail | USD/gal |
| `EMD_EPD2D_PTE_NUS_DPG` | `petroleum/pri/gnd` | US on-highway diesel retail | USD/gal |

Spot series live under `pri/spt` and are daily; the retail series live under
`pri/gnd` and are weekly (Monday). These are two different routes — a single call
cannot serve both.

Response envelope is `{"response":{"data":[{"period","series","value",...}]}}`, so
`read_json_auto` needs the `response.data` path unnested rather than the document
root. Default page length is 5000; `length=5000` plus `offset` paging covers 2022→
present comfortably for daily series (≈1200 rows each).

## EU Weekly Oil Bulletin

**Page**: `https://energy.ec.europa.eu/data-and-analysis/weekly-oil-bulletin_en`
**File**: `Weekly_Oil_Bulletin_Prices_History_maticni_4web.xlsx`, reached through a
UUID download path — verified live, 4.4 MB, HTTP 200.

The UUID is reissued when the Commission republishes, so it is configuration
(`pipeline/sources.env`), not a constant. The landing page is the durable locator.

**Workbook structure** — seven sheets; two matter:

- `Prices with taxes`
- `Prices wo taxes`

Both are 226 columns wide with a three-row header:

- **Row 1** — machine-readable names: `SE_price_with_tax_diesel`,
  `SE_price_wo_tax_euro95`, `SE_exchange_rate`, plus `CTR` separator cells.
- **Row 2** — human labels (`Euro-super 95 (I)`, `Gas oil automobile …`).
- **Row 3** — units (`1000 l` for liquids, `t` for heavy fuel oil).
- **Row 4+** — data. Column A is an Excel date serial; rows run **descending** by
  date, weekly, most recent first.

**Verified facts that shape the SQL**:

1. Prices are **already in EUR** per 1000 litres for every country. Checked against
   Sweden: `SE_price_with_tax_euro95` = 1307.6 for 2026-08-10, i.e. 1.31 EUR/L,
   which matches ~14.4 SEK/L at 11.0 SEK/EUR. The `{CC}_exchange_rate` columns
   (15 of them) are EUR-per-national-unit and are informational only — Sweden's
   reads 0.0912, the reciprocal of 10.96 SEK/EUR. **Do not multiply by them.**
2. Column A is an Excel serial on the 1900 system: `DATE '1899-12-30' + INTERVAL
   (A::INT) DAY`. Verified — 46244 → 2026-08-10.
3. 30 country-like prefixes: EU-27, `UK`, plus `EU_` (EU average) and `EUR_`
   (euro-area average). The UK and both aggregates must be excluded from the
   country set; keeping them would silently add three "countries".
4. Six products per country: `euro95`, `diesel`, `heating_oil`, `fuel_oil_1`,
   `fuel_oil_2`, `LPG`. Only the first two are in scope.

**DuckDB reading strategy** — the `excel` extension's `read_xlsx` names columns by
spreadsheet letter (`A`, `B`, …) when `header=false`, which makes the wide sheet
tractable without a 226-column DDL:

```sql
-- header row -> (col_letter, machine_name)
UNPIVOT (SELECT * FROM read_xlsx(f, sheet:='Prices with taxes',
                                 header:=false, all_varchar:=true, range:='A1:AMJ1'))
  ON COLUMNS(*) INTO NAME col VALUE label;

-- data rows -> (date_serial, col_letter, value), keyed on column A
UNPIVOT (SELECT * FROM read_xlsx(f, sheet:='Prices with taxes',
                                 header:=false, all_varchar:=true, range:='A4:AMJ2000'))
  ON COLUMNS(* EXCLUDE (A)) INTO NAME col VALUE val;
```

Joining the two on `col` turns 226 columns into tidy rows in pure SQL. `all_varchar`
is required — the sheet mixes text separators into numeric columns, and letting
DuckDB sniff types produces nulls where `CTR` markers appear.

`range` must be given an explicit upper bound; `AMJ` is column 1024, comfortably
past the 226 in use.

## ECB SDMX

**Endpoint**: `https://data-api.ecb.europa.eu/service/data/EXR/D.{CCY}.EUR.SP00.A`
with `?format=csvdata&startPeriod=YYYY-MM-DD`. Verified live for both `USD` and
`SEK`; returns CSV with `TIME_PERIOD` and `OBS_VALUE` among 32 columns.

Values are **units of the foreign currency per 1 EUR** (USD 1.1593, SEK 11.001 on
2026-08-17). Business days only — no weekend or TARGET-holiday rows — so a weekly
rate is the last observation on or before that week's Monday, not a naive lookup.

## ICE gasoil — no free source

ICE licenses gasoil futures settlements; there is no free API and redistribution is
restricted. The NWE crack therefore reads `data/manual/ice_gasoil.csv`, shipped with
only a header. Documented in the README and surfaced as an explicit empty state in
the chart, per constitution principle III.

## Reference implementation

`../elmix` supplies the house pattern this project follows: DuckDB for all
transformation, a hand-written ECharts facade (`viz/app/src/ECharts.scala`, ~25
lines) rather than ScalablyTyped, Mill `ScalaJSModule` with Scala 3 + Laminar, and
GitHub Actions splitting CI from a scheduled data refresh that commits rebuilt
output. Its visual language — system font stack, 1100 px column, `#222` text, `#36c`
links, `#e3e8ef` rules, `#f7f9fc` panels, and the `© 2026 Örjan Lundberg` footer —
is adopted here so the two sites read as one body of work.
