# Phase 1 Contract: Published Chart JSON

Five files under `site/public/data/`. This is the boundary between the pipeline and
the frontend: `50_export.sql` writes it, `Data.scala` decodes it, and neither may
change unilaterally.

**Two axes, not one.** Four files share a `weeks` axis and are positionally
interchangeable. `cracks_daily.json` has its own `days` axis and is **not**. The
distinction is enforced: `verify 8` rejects a daily file that carries a `weeks`
key at all, precisely so nothing can start indexing one against the other.

## Shared conventions

- **Wide form.** One `weeks` array shared by every series in the file; each series
  carries a `values` array of identical length, positionally aligned.
- **`null` means no observation.** Never `0`, never carried forward.
- **Numbers are rounded at export** — 2 decimals for USD/bbl, 4 for per-litre
  prices, 4 for FX. Rounding at export rather than in the browser keeps the files
  small and the displayed value identical for everyone.
- **`meta` is per file** and satisfies FR-018 and constitution III.
- **`meta.synthetic`** is true only for a `--fixtures` build. Published data must
  always carry `false`; CI fails otherwise. It exists because a fixtures build was
  once committed and served real-looking sine waves to the site.

```json
"meta": {
  "generated": "2026-08-17",
  "synthetic": false,
  "sources": [
    { "name": "EIA Open Data v2",
      "url": "https://www.eia.gov/opendata/",
      "licence": "US Government work, public domain",
      "series": ["RBRTE", "RWTC", "EER_EPD2DXL0_PF4_Y35NY_DPG"] }
  ]
}
```

## `cracks.json`

```json
{
  "meta": { "...": "...", "formulae": {
      "us_ulsd_brent": "ULSD USD/gal x 42 - Brent USD/bbl",
      "us_ulsd_wti":   "ULSD USD/gal x 42 - WTI USD/bbl",
      "nwe_gasoil_brent": "ICE gasoil USD/t / 7.45 - Brent USD/bbl" } },
  "weeks": ["2022-01-03", "2022-01-10", "..."],
  "series": [
    { "key": "us_ulsd_brent", "label": "NYH ULSD – Brent", "kind": "spread",
      "region": "US", "unit": "USD/bbl",
      "values": [23.41, 24.02, null, "..."] },
    { "key": "us_ulsd_wti", "label": "NYH ULSD – WTI", "kind": "spread",
      "region": "US", "unit": "USD/bbl", "values": ["..."] },
    { "key": "nwe_gasoil_brent", "label": "ICE gasoil – Brent", "kind": "spread",
      "region": "NWE", "unit": "USD/bbl", "values": [] },

    { "key": "brent", "label": "Brent", "kind": "level",
      "region": "US", "unit": "USD/bbl", "values": ["..."] },
    { "key": "wti", "label": "WTI", "kind": "level",
      "region": "US", "unit": "USD/bbl", "values": ["..."] },
    { "key": "ulsd", "label": "NYH ULSD", "kind": "level",
      "region": "US", "unit": "USD/gal", "values": ["..."] }
  ]
}
```

`kind` separates the derived spreads from the underlying price levels. The crack
chart draws `kind == "spread"`; the dual-axis rockets-and-feathers chart draws
`kind == "level"` against US retail from `retail.json` (FR-027). Publishing the
levels here rather than in a fourth file keeps every series that shares the crude
provenance block in one place.

`nwe_gasoil_brent` is always present, with `values: []` when the manual CSV is
empty. The frontend distinguishes "series absent" (a bug) from "series present but
empty" (the documented ICE limitation) and renders the empty state for the latter —
this is why the series is emitted rather than omitted.

## `retail.json`

```json
{
  "meta": { "...": "..." },
  "weeks": ["2022-01-03", "..."],
  "series": [
    { "cc": "SE", "label": "Sweden", "region": "EU", "focus": true,
      "fuel": "diesel", "tax": "with", "currency": "EUR",
      "values": [1.8342, "..."] },
    { "cc": "US", "label": "United States", "region": "US", "focus": false,
      "fuel": "diesel", "tax": "with", "currency": "USD",
      "values": [1.0021, "..."] }
  ]
}
```

One entry per `(cc, fuel, tax)` — up to 28 regions × 2 fuels × 2 tax treatments.

- `currency` is the series' **native** currency; the frontend converts via `fx.json`.
  Values are always **per litre**.
- `region` is `EU` or `US`; the frontend styles US dashed and EU solid.
- `focus` is true for Sweden only, driving the emphasised line without hard-coding a
  country code in the frontend.
- A `(cc, fuel, tax)` combination the source does not publish is **omitted**, not
  emitted as an all-null series. The without-tax view counts the omissions and says
  so (FR-016, spec Story 2 scenario 4).

## `fx.json`

```json
{
  "meta": { "...": "..." },
  "weeks": ["2022-01-03", "..."],
  "rates": {
    "USD": [1.1305, "..."],
    "SEK": [10.2745, "..."]
  }
}
```

Units of the named currency per **1 EUR**, matching ECB's own orientation. Both
arrays are complete over `weeks` — a hole here would silently drop series from the
chart, so `verify.sql` asserts completeness rather than letting the frontend cope.

Conversion the frontend performs, for a value `v` in currency `c` at week `i`:

| From → To | Expression |
|---|---|
| EUR → USD | `v * USD[i]` |
| EUR → SEK | `v * SEK[i]` |
| USD → EUR | `v / USD[i]` |
| USD → SEK | `v / USD[i] * SEK[i]` |

`weeks` is identical across all four weekly files by construction — all are left-joined
onto `week_calendar` — which lets the frontend index by position instead of matching
dates.

## `usregions.json` (feature 002)

```json
{
  "meta": { "...": "..." },
  "weeks": ["2022-01-03", "..."],
  "regions": [
    { "code": "CA", "label": "California", "geo": "state",
      "fuel": "gasoline", "currency": "USD", "values": [1.0231, "..."] },
    { "code": "GC", "label": "Gulf Coast (PADD 3)", "geo": "padd",
      "fuel": "diesel", "currency": "USD", "values": ["..."] }
  ]
}
```

Its own file rather than extra entries in `retail.json`: that chart filters on
`(fuel, tax)` and would draw the states into the EU comparison.

`geo` is `state` or `padd`, and differs **between fuels** — EIA publishes weekly
petrol for nine states (its entire free state-level coverage) but diesel by PADD
refining region, with California the one state broken out. The frontend reads
this rather than assuming, and states which geography is on screen.

Values are USD per litre, converted in the browser like every other retail
series. There is no national-average entry here; the chart takes it from
`retail.json` so the two charts cannot disagree about what the US average is.


## `cracks_daily.json` (feature 003)

```json
{
  "meta": { "...": "...", "formulae": {
      "us_ulsd_brent": "ULSD USD/gal x 42 - Brent USD/bbl",
      "ma7": "Unweighted mean of the daily values over the trailing 7 calendar days,
              inclusive. Emitted only where the window holds at least 3 observations." } },
  "days": ["2022-01-03", "2022-01-04", "2022-01-05", "..."],
  "series": [
    { "key": "us_ulsd_brent", "label": "NYH ULSD – Brent", "kind": "spread",
      "region": "US", "unit": "USD/bbl", "of": null,
      "values": [23.41, 24.02, null, "..."] },
    { "key": "us_ulsd_brent_ma7", "label": "NYH ULSD – Brent, 7d", "kind": "ma",
      "region": "US", "unit": "USD/bbl", "of": "us_ulsd_brent",
      "values": [null, null, 23.72, "..."] }
  ]
}
```

**`days` is an observation axis, not a calendar.** It carries only dates on which
a source published, so weekends are absent rather than null — a weekend is not a
missing observation. This is the opposite of `weeks`, which is a dense calendar
where a hole genuinely is a hole. The two are therefore **not positionally
comparable**, and nothing may index one against the other. `verify 8` fails the
file if it carries a `weeks` key, `verify 15` rejects a duplicated date, and
`verify 18` rejects a non-ascending axis — a swapped pair changes no array length
and would otherwise draw the wrong dates in silence.

`kind` is `spread`, `ma` or `level`. `of` names the series an `ma` smooths, and
is `null` otherwise; the frontend pairs them by this field rather than by parsing
the key.

The empty-series exemption of `verify 17` covers `nwe_gasoil_brent` **and**
`nwe_gasoil_brent_ma7` — an absent daily series cannot have a ruler — but no
other key.

### The 7-day ruler

Trailing **7 calendar days**, inclusive of the current day, unweighted, emitted
only where the window holds at least 3 observations.

Calendar days rather than 7 observations is a deliberate choice. In steady state
the window holds the five trading days of one week; over a public holiday it
shortens honestly, where a 7-observation window would silently reach nine
calendar days back and label the result "7-day". The minimum of 3 is the same
constant as the weekly-coverage floor (`min_week_obs`, set in `run.sh`), so the
two can never drift apart.

`verify 14` recomputes every point with a correlated subquery rather than with the
window function that produced it, and checks the threshold in both directions: a
point that should be absent but is present fails just as a wrong value does.

## Weekly coverage (feature 003)

A weekly leg is published only if at least 3 daily observations back it;
otherwise it is `null` and the spreads derived from it follow by null
propagation. Three, not five, so a holiday-shortened trading week survives.

This is why the weekly crack series routinely ends one to two weeks before the
weekly retail series: EIA publishes spot with roughly a week's lag, so the last
calendar week is usually still incomplete. `verify 7` allows 21 days of slack for
the crack for exactly this reason, while retail keeps 14. Recency lives in
`cracks_daily.json`, and `verify 16` is what actually guards it.

`verify 13` recomputes coverage from `stg.spot_daily` rather than reading the
aggregate that produced the row — a check that reads its own `GROUP BY` cannot
fail, which this pipeline has already shipped three times.
