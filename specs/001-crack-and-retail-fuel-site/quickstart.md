# Quickstart

## Prerequisites

| Tool | Version | Why |
|---|---|---|
| DuckDB CLI | 1.5+ | The whole pipeline. `read_xlsx` needs the `excel` extension, auto-installed on first run. |
| Mill | 1.1+ | Builds the Scala.js frontend. |
| JDK | 21 | Mill's runtime. |
| curl | any | Fetches the Oil Bulletin workbook. |

An EIA API key, free from <https://www.eia.gov/opendata/register.php>.

```bash
security add-generic-password -a "$USER" -s EIA_API_KEY -w   # macOS Keychain
export EIA_API_KEY=...                                       # or the environment
echo 'EIA_API_KEY=...' > .env                                # or .env (gitignored)
```

`run.sh` checks those three in that order. The Keychain is preferred over `.env`:
a key in cleartext on disk is a key that eventually lands in a commit or a backup.
The first Keychain read may raise a macOS permission prompt — "Always Allow" makes
it silent thereafter.

## Run the pipeline

```bash
pipeline/run.sh
```

Fetches EIA, the Oil Bulletin workbook, and ECB rates; builds the staging tables;
asserts the invariants in `verify.sql`; writes `site/public/data/*.json`. Roughly a
minute, most of it the 4.4 MB workbook download. Rerunning against unchanged
upstream data produces identical output.

Useful variations:

```bash
pipeline/run.sh --offline     # reuse data/work/ downloads; no network
pipeline/run.sh --fixtures    # build from data/fixtures/; no API key needed
pipeline/run.sh --verify-only # re-run assertions against the existing database
```

## Build and serve the site

```bash
mill site.fullLinkJS          # production; writes site/public/app.js
mill site.fastLinkJS          # faster, for iterating
cd site && python3 -m http.server 8000
```

Then <http://localhost:8000>. The page needs to be served over HTTP rather than
opened as a `file://` URL, because it fetches its JSON.

## Add ICE gasoil (optional)

The NWE crack is empty until you supply settlements — ICE has no free API and the
data cannot be redistributed here. If you have licensed access, append to
`data/manual/ice_gasoil.csv`:

```csv
obs_date,usd_per_tonne
2026-08-14,712.25
```

Rerun the pipeline and the NWE region populates. Daily or weekly rows both work;
the pipeline averages to ISO weeks either way.

## What to check after a change

```bash
mill site.compile             # frontend still compiles
pipeline/run.sh --verify-only # invariants still hold
```

The invariants are the real test: they catch the unit errors that produce a
plausible-looking but wrong chart — a missing ×42 on the crack, or an exchange rate
applied to Oil Bulletin prices that are already in EUR. See
[data-model.md](./data-model.md) for the full list.
