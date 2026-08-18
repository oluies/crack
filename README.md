# crack

Weekly diesel crack spreads and retail fuel prices, as a static site on GitHub
Pages. Two questions: what does a refiner earn turning crude into diesel, and how
does Sweden's pump price compare with the rest of the EU and the USA.

No server, no database at runtime. A DuckDB pipeline writes JSON; a Scala.js app
draws it.

- **Site**: <https://oluies.github.io/crack/>
- **Spec**: [`specs/001-crack-and-retail-fuel-site/`](specs/001-crack-and-retail-fuel-site/)
  — built with [GitHub Spec Kit](https://github.com/github/spec-kit); the
  [constitution](.specify/memory/constitution.md) is the standing brief.

## Charts

| Chart | Shows |
|---|---|
| Diesel crack spreads | NYH ULSD against Brent and WTI, weekly since 2022, with a threshold ("mountain") view that fills green above and red below a breakeven you set. NW Europe needs ICE gasoil — see below. |
| Retail diesel and petrol | Pump prices per litre for all 27 EU members plus the USA, Sweden emphasised. Toggles for fuel, tax treatment, and EUR/USD/SEK. |
| US regional spread | Nine states for petrol and five PADD regions for diesel, against the bold national average. California against Texas is roughly a 50% difference on the same fuel, and most of it is tax. |
| Rockets and feathers | Crude benchmarks against the US pump on a dual axis — retail chases a crude spike up in weeks and drifts back down over months. |

## Data sources

| Source | Series | Licence |
|---|---|---|
| [EIA Open Data v2](https://www.eia.gov/opendata/) | NYH ULSD spot `EER_EPD2DXL0_PF4_Y35NY_DPG`, Brent `RBRTE`, WTI `RWTC`, US retail petrol `EMM_EPMR_PTE_NUS_DPG`, US retail diesel `EMD_EPD2D_PTE_NUS_DPG`, nine state petrol series `EMM_EPMR_PTE_S**_DPG`, five PADD diesel series `EMD_EPD2D_PTE_R**_DPG` | US Government work — public domain. A free API key is required. |
| [EU Weekly Oil Bulletin](https://energy.ec.europa.eu/data-and-analysis/weekly-oil-bulletin_en) | Euro-super 95 and gas oil automobile, with and without taxes, all member states | European Commission open data, CC BY 4.0. Attribution required. |
| [ECB SDMX](https://data.ecb.europa.eu/) | `EXR.D.USD.EUR.SP00.A`, `EXR.D.SEK.EUR.SP00.A` | ECB open data. Attribution required. |
| ICE Low Sulphur Gasoil | Futures settlement | **Not redistributable.** See below. |

## The ICE gasoil limitation

The North-West European crack is gasoil against Brent. ICE licenses gasoil futures
settlements and publishes no free API, and the data cannot be redistributed here.
So this repository ships that leg **empty**, and the chart says so rather than
quietly drawing nothing.

If you have licensed access, append rows to
[`data/manual/ice_gasoil.csv`](data/manual/ice_gasoil.csv):

```csv
obs_date,usd_per_tonne
2026-08-14,712.25
```

Daily or weekly rows both work; the pipeline reduces either to an ISO-week mean.
Rerun `pipeline/run.sh` and the NW European region populates.

This is deliberate. A stub that admits the gap is honest; a series interpolated
from a proxy would look identical on the chart and be wrong.

## How the numbers are made

```
crack spread = product price in USD/bbl − crude price in USD/bbl

  NYH ULSD – Brent    = ULSD USD/gal × 42     − Brent USD/bbl
  NYH ULSD – WTI      = ULSD USD/gal × 42     − WTI   USD/bbl
  ICE gasoil – Brent  = gasoil USD/t ÷ 7.45   − Brent USD/bbl
```

42 US gallons to the barrel is exact by definition. 7.45 barrels of gasoil per
tonne is a conventional density factor — an approximation, which is why the chart
states it.

Other conventions:

- **Everything is weekly**, bucketed to ISO weeks and keyed to that week's Monday.
  Sources publish on different days; joining on the week key rather than the
  publication date makes cross-source comparison exact. The current, incomplete
  week is excluded.
- **Oil Bulletin prices are already in EUR** per 1000 litres for every country,
  and are stored as EUR/L. The workbook's `{CC}_exchange_rate` columns are *not*
  applied — doing so would divide Swedish prices by eleven. An invariant check
  guards against that regression.
- **Currency conversion happens in the browser**, against the ECB reference rate
  for the same week. Series are published in their native currency so there is one
  source of truth rather than three separately rounded pipelines.
- **Missing is null.** Gaps are drawn as gaps, never zero and never carried
  forward. The one exception is exchange rates over bank holidays, where a rate
  genuinely persists until it is restated.

## Running it

```bash
# macOS: keep the key in the login keychain rather than a file on disk.
# NOT the Passwords app — it stores items in the data-protection keychain,
# which security(1) cannot read at all (iCloud on or off), so a shell script
# will not find it there however plainly Passwords shows it.
security add-generic-password -a "$USER" -s EIA_API_KEY -w
# or, anywhere: export EIA_API_KEY=... / put it in .env (gitignored)

pipeline/run.sh               # fetch, build, verify, export to site/public/data/
mill site.fullLinkJS          # or site.bundleFull to link straight into site/public/
cd site && python3 -m http.server 8000
```

A free key comes from <https://www.eia.gov/opendata/register.php>. `run.sh` looks
for it in the environment, then the macOS Keychain, then `.env` — the Keychain
first of the two stored forms, because a key in cleartext on disk is a key that
eventually lands in a commit, a backup or a synced folder.

Needs DuckDB 1.5+, Mill 1.1+, JDK 21 and curl. More detail, including the
`--offline` / `--fixtures` / `--verify-only` modes, in
[quickstart.md](specs/001-crack-and-retail-fuel-site/quickstart.md).

## Layout

```
pipeline/     DuckDB SQL, in execution order, plus run.sh and verify.sql
data/manual/  ICE gasoil CSV you maintain yourself
data/fixtures/ trimmed samples so CI runs without an API key
site/         index.html, the Scala.js app, and the published JSON
specs/        the spec-driven-development artefacts
```

`pipeline/verify.sql` and `pipeline/60_verify_export.sql` are the real test suite.
They assert the invariants that catch failures producing a *plausible but wrong*
chart — a dropped ×42 on the crack, an exchange rate applied twice — because those
do not announce themselves.

`pipeline/test/negative.sh` tests the tests: it corrupts each input in turn and
asserts the run dies naming the right check. A check that cannot fail is worse
than no check, because it reports green and is believed.

## Automation

- `.github/workflows/ci.yml` — on push and pull request: compile the frontend, run
  the pipeline against fixtures, run the negative tests, and run the headless
  frontend smoke test.
- `.github/workflows/refresh.yml` — weekly: run the pipeline for real, commit
  changed JSON, build, and deploy to Pages. A run that changes nothing commits
  nothing.

The Oil Bulletin download path is a UUID the Commission reissues when it
republishes. It lives in `pipeline/sources.env`; when the download starts failing,
lift the current one from the
[bulletin page](https://energy.ec.europa.eu/data-and-analysis/weekly-oil-bulletin_en).
The pipeline checks that what it downloaded is actually a spreadsheet, so a
reissued UUID fails with that message rather than as a parse error.

## Licence

Code © 2026 Örjan Lundberg, MIT. Data belongs to the sources above under their own
terms — EIA public domain, Oil Bulletin CC BY 4.0, ECB with attribution.

Sibling project: [elmix](https://github.com/oluies/elmix), same house style.
