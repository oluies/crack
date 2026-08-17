# Phase 1 Contract: Published Chart JSON

Three files under `site/public/data/`. This is the boundary between the pipeline and
the frontend: `50_export.sql` writes it, `Data.scala` decodes it, and neither may
change unilaterally.

## Shared conventions

- **Wide form.** One `weeks` array shared by every series in the file; each series
  carries a `values` array of identical length, positionally aligned.
- **`null` means no observation.** Never `0`, never carried forward.
- **Numbers are rounded at export** — 2 decimals for USD/bbl, 4 for per-litre
  prices, 4 for FX. Rounding at export rather than in the browser keeps the files
  small and the displayed value identical for everyone.
- **`meta` is per file** and satisfies FR-018 and constitution III.

```json
"meta": {
  "generated": "2026-08-17",
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

`weeks` is identical across all three files by construction — all are left-joined
onto `week_calendar` — which lets the frontend index by position instead of matching
dates.
